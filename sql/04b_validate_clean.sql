-- sql/04b_validate_clean.sql
-- Purpose: prove the cleaning did what we intended. Read-only.
-- Run: python src/run_sql.py sql/04b_validate_clean.sql

-- 1. Row counts: demo must be unchanged (no case lost); reac shows duplicates removed.
SELECT tbl, rows_before, rows_after, rows_before - rows_after AS rows_removed
FROM (
    SELECT 'demo' AS tbl, (SELECT count(*) FROM demo_dedup) AS rows_before, (SELECT count(*) FROM demo_clean) AS rows_after
    UNION ALL
    SELECT 'reac', (SELECT count(*) FROM reac_dedup), (SELECT count(*) FROM reac_clean)
);

-- 2. Age group result and where it came from (this is the "how much rests on fallback" table).
SELECT age_group, age_group_source, count(*) AS n,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_cases
FROM demo_clean
GROUP BY age_group, age_group_source
ORDER BY age_group, age_group_source;

-- 3. Age conversion: how many given ages were nulled, and the resulting distribution.
SELECT
    count(*) FILTER (WHERE TRY_CAST(d.age AS DOUBLE) IS NOT NULL)                         AS age_value_present,
    count(*) FILTER (WHERE TRY_CAST(d.age AS DOUBLE) IS NOT NULL AND c.age_years IS NULL) AS age_nulled_total,
    count(*) FILTER (WHERE TRY_CAST(d.age AS DOUBLE) IS NOT NULL AND d.age_cod IS NULL)   AS nulled_no_unit,
    round(min(c.age_years), 2)                 AS min_age,
    round(quantile_cont(c.age_years, 0.25), 1) AS p25,
    round(quantile_cont(c.age_years, 0.5), 1)  AS median_age,
    round(quantile_cont(c.age_years, 0.75), 1) AS p75,
    round(max(c.age_years), 1)                 AS max_age
FROM demo_dedup d
JOIN demo_clean c ON c.primaryid = d.primaryid;

-- 4. How reliable is the age_grp code? Compare it with the group derived from numeric age.
SELECT d.age_grp AS age_grp_code, c.age_group AS group_from_numeric_age, count(*) AS n
FROM demo_dedup d
JOIN demo_clean c ON c.primaryid = d.primaryid
WHERE c.age_group_source = 'age_value' AND d.age_grp IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, n DESC;

SELECT count(*) AS both_present,
       count(*) FILTER (WHERE mapped <> age_group) AS disagree,
       round(100.0 * count(*) FILTER (WHERE mapped <> age_group) / count(*), 2) AS pct_disagree
FROM (
    SELECT c.age_group,
           CASE d.age_grp WHEN 'N' THEN 'Neonate' WHEN 'I' THEN 'Infant' WHEN 'C' THEN 'Child'
                          WHEN 'T' THEN 'Adolescent' WHEN 'A' THEN 'Adult' WHEN 'E' THEN 'Elderly' END AS mapped
    FROM demo_dedup d
    JOIN demo_clean c ON c.primaryid = d.primaryid
    WHERE c.age_group_source = 'age_value' AND d.age_grp IS NOT NULL
);

-- 5. Sex.
SELECT sex, count(*) AS n, round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM demo_clean GROUP BY sex ORDER BY n DESC;

-- 6. Weight: how many given values were nulled as implausible, and the distribution.
SELECT
    count(*) FILTER (WHERE d.wt IS NOT NULL)                           AS weight_present,
    count(*) FILTER (WHERE d.wt IS NOT NULL AND c.weight_kg IS NULL)   AS weight_nulled,
    round(min(c.weight_kg), 2)                AS min_kg,
    round(quantile_cont(c.weight_kg, 0.5), 1) AS median_kg,
    round(max(c.weight_kg), 1)                AS max_kg
FROM demo_dedup d
JOIN demo_clean c ON c.primaryid = d.primaryid;

-- 7. Dates: parse failures and range-rule nulls (all should be small).
SELECT
    count(*) FILTER (WHERE d.event_dt IS NOT NULL AND TRY_STRPTIME(d.event_dt, '%Y%m%d') IS NULL)  AS event_dt_unparseable,
    count(*) FILTER (WHERE d.event_dt IS NOT NULL AND TRY_STRPTIME(d.event_dt, '%Y%m%d') IS NOT NULL
                       AND c.event_date IS NULL)                                                   AS event_dt_out_of_range,
    count(*) FILTER (WHERE d.init_fda_dt IS NOT NULL AND c.init_fda_date IS NULL)                  AS init_fda_dt_unparseable,
    count(*) FILTER (WHERE d.fda_dt IS NOT NULL AND c.fda_date IS NULL)                            AS fda_dt_unparseable
FROM demo_dedup d
JOIN demo_clean c ON c.primaryid = d.primaryid;

-- 8. Do the quarter labels match the FDA receipt dates?
SELECT quarter, count(*) AS n, min(fda_date) AS first_fda_date, max(fda_date) AS last_fda_date
FROM demo_clean GROUP BY quarter ORDER BY quarter;

-- 9. Integrity checks: every row should show passed = true.
SELECT 'demo_clean: one row per primaryid' AS check_name,
       count(*) = count(DISTINCT primaryid) AS passed
FROM demo_clean
UNION ALL
SELECT 'demo_clean: same row count as demo_dedup',
       (SELECT count(*) FROM demo_clean) = (SELECT count(*) FROM demo_dedup)
UNION ALL
SELECT 'demo_clean: no age_years outside 0-120',
       count(*) = 0 FROM demo_clean WHERE age_years < 0 OR age_years > 120
UNION ALL
SELECT 'reac_clean: no duplicate (primaryid, pt)',
       count(*) = 0 FROM (SELECT 1 FROM reac_clean GROUP BY primaryid, pt HAVING count(*) > 1)
UNION ALL
SELECT 'reac_clean: no blank pt',
       count(*) = 0 FROM reac_clean WHERE pt IS NULL OR pt = ''
UNION ALL
SELECT 'reac_clean: no orphans',
       count(*) = 0 FROM reac_clean r
       WHERE NOT EXISTS (SELECT 1 FROM demo_clean d WHERE d.primaryid = r.primaryid);