-- sql/01_diagnose_case_versions.sql
-- Purpose: measure case-version duplication in raw_demo BEFORE deduping.
-- Read-only (creates nothing). Run: python src/run_sql.py sql/01_diagnose_case_versions.sql

-- 1. Headline: rows vs distinct primaryid vs distinct caseid.
--    extra_versions = report rows that are older versions of a case we already have.
--    If demo_rows <> distinct_primaryid, the same report was loaded twice
--    (e.g. ingest re-run or overlapping quarter files) -- investigate before deduping.
SELECT
    count(*)                                                          AS demo_rows,
    count(DISTINCT primaryid)                                         AS distinct_primaryid,
    count(DISTINCT caseid)                                            AS distinct_caseid,
    count(*) - count(DISTINCT caseid)                                 AS extra_versions,
    round(100.0 * (count(*) - count(DISTINCT caseid)) / count(*), 2)  AS pct_extra
FROM raw_demo;

-- 2. Key quality: anything that would break the ordering rule or the joins.
--    primaryid should equal caseid || caseversion per the FDA layout; expect 0 mismatches.
SELECT
    count(*) FILTER (WHERE primaryid IS NULL)                                   AS null_primaryid,
    count(*) FILTER (WHERE caseid IS NULL)                                      AS null_caseid,
    count(*) FILTER (WHERE TRY_CAST(caseversion AS INTEGER) IS NULL)            AS bad_caseversion,
    count(*) FILTER (WHERE TRY_CAST(fda_dt AS BIGINT) IS NULL)                  AS bad_fda_dt,
    count(*) FILTER (WHERE primaryid <> caseid || caseversion)                  AS primaryid_ne_case_plus_version
FROM raw_demo;

-- 3. How many versions does each case have?
SELECT versions_per_case, count(*) AS cases
FROM (SELECT caseid, count(*) AS versions_per_case FROM raw_demo GROUP BY caseid)
GROUP BY versions_per_case
ORDER BY versions_per_case;

-- 4. Do "latest caseversion" and "latest fda_dt" pick the same report?
--    Disagreements are the cases where the choice of rule actually matters.
WITH ranked AS (
    SELECT
        caseid,
        primaryid,
        ROW_NUMBER() OVER (
            PARTITION BY caseid
            ORDER BY TRY_CAST(caseversion AS INTEGER) DESC NULLS LAST,
                     TRY_CAST(fda_dt AS BIGINT)       DESC NULLS LAST,
                     TRY_CAST(primaryid AS BIGINT)    DESC NULLS LAST) AS rn_version_first,
        ROW_NUMBER() OVER (
            PARTITION BY caseid
            ORDER BY TRY_CAST(fda_dt AS BIGINT)       DESC NULLS LAST,
                     TRY_CAST(caseversion AS INTEGER) DESC NULLS LAST,
                     TRY_CAST(primaryid AS BIGINT)    DESC NULLS LAST) AS rn_date_first
    FROM raw_demo
)
SELECT count(*) AS cases_where_rules_disagree
FROM (
    SELECT caseid
    FROM ranked
    GROUP BY caseid
    HAVING max(primaryid) FILTER (WHERE rn_version_first = 1)
        <> max(primaryid) FILTER (WHERE rn_date_first = 1)
);

-- 5. Which quarter do superseded rows live in? (Single quarter now; informative once you load more.)
SELECT
    quarter,
    count(*)                      AS rows_loaded,
    count(*) FILTER (WHERE rn > 1) AS superseded_rows
FROM (
    SELECT quarter,
           ROW_NUMBER() OVER (
               PARTITION BY caseid
               ORDER BY TRY_CAST(caseversion AS INTEGER) DESC NULLS LAST,
                        TRY_CAST(fda_dt AS BIGINT)       DESC NULLS LAST,
                        TRY_CAST(primaryid AS BIGINT)    DESC NULLS LAST) AS rn
    FROM raw_demo
)
GROUP BY quarter
ORDER BY quarter;

-- 6. Orphans: child rows whose primaryid has no DEMO row at all.
--    NOT EXISTS (not NOT IN) so NULL keys can't silently hide orphans.
SELECT 'raw_drug' AS tbl, count(*) AS orphan_rows FROM raw_drug t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'raw_reac', count(*) FROM raw_reac t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'raw_outc', count(*) FROM raw_outc t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'raw_indi', count(*) FROM raw_indi t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'raw_ther', count(*) FROM raw_ther t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'raw_rpsr', count(*) FROM raw_rpsr t
  WHERE NOT EXISTS (SELECT 1 FROM raw_demo d WHERE d.primaryid = t.primaryid);

-- 7. Duplicate rows inside a single report (same primaryid + same event / outcome).
--    Not removed by case dedup. Later PRR counts must use COUNT(DISTINCT primaryid), not COUNT(*).
SELECT 'raw_reac (primaryid, pt)' AS tbl, coalesce(sum(c - 1), 0) AS duplicate_rows
FROM (SELECT count(*) AS c FROM raw_reac GROUP BY primaryid, pt HAVING count(*) > 1)
UNION ALL
SELECT 'raw_outc (primaryid, outc_cod)', coalesce(sum(c - 1), 0)
FROM (SELECT count(*) AS c FROM raw_outc GROUP BY primaryid, outc_cod HAVING count(*) > 1);