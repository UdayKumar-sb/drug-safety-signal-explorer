-- sql/02_dedup.sql
-- Purpose: keep ONE report per caseid (latest version) and restrict child tables to survivors.
-- Idempotent: rebuilds the *_dedup tables from raw_* every run, so re-run after loading more quarters.
-- Run: python src/run_sql.py sql/02_dedup.sql
--
-- Rule (defend in interviews):
--   A case can be reported many times (initial + follow-ups, from different manufacturers' submissions).
--   Counting every version would inflate drug-event counts and bias PRR/ROR upward for
--   heavily followed-up cases. We keep the latest version because it supersedes earlier ones.
--   Ordering: caseversion DESC, then fda_dt DESC, then primaryid DESC (deterministic tiebreak).
--   Casts are essential: as VARCHAR, '9' sorts above '10'.

-- 1. DEMO: one row per caseid.
CREATE OR REPLACE TABLE demo_dedup AS
SELECT *
FROM raw_demo
WHERE primaryid IS NOT NULL
  AND caseid IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY caseid
    ORDER BY TRY_CAST(caseversion AS INTEGER) DESC NULLS LAST,
             TRY_CAST(fda_dt AS BIGINT)       DESC NULLS LAST,
             TRY_CAST(primaryid AS BIGINT)    DESC NULLS LAST
) = 1;

-- 2. Child tables: keep only rows belonging to surviving primaryids.
CREATE OR REPLACE TABLE drug_dedup AS
SELECT t.* FROM raw_drug t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

CREATE OR REPLACE TABLE reac_dedup AS
SELECT t.* FROM raw_reac t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

CREATE OR REPLACE TABLE outc_dedup AS
SELECT t.* FROM raw_outc t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

CREATE OR REPLACE TABLE indi_dedup AS
SELECT t.* FROM raw_indi t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

CREATE OR REPLACE TABLE ther_dedup AS
SELECT t.* FROM raw_ther t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

CREATE OR REPLACE TABLE rpsr_dedup AS
SELECT t.* FROM raw_rpsr t
WHERE EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);

-- 3. Before/after audit table (paste the printed markdown into the README).
CREATE OR REPLACE TABLE dedup_audit AS
WITH counts AS (
    SELECT 1 AS ord, 'demo' AS tbl, (SELECT count(*) FROM raw_demo) AS rows_before, (SELECT count(*) FROM demo_dedup) AS rows_after
    UNION ALL SELECT 2, 'drug', (SELECT count(*) FROM raw_drug), (SELECT count(*) FROM drug_dedup)
    UNION ALL SELECT 3, 'reac', (SELECT count(*) FROM raw_reac), (SELECT count(*) FROM reac_dedup)
    UNION ALL SELECT 4, 'outc', (SELECT count(*) FROM raw_outc), (SELECT count(*) FROM outc_dedup)
    UNION ALL SELECT 5, 'indi', (SELECT count(*) FROM raw_indi), (SELECT count(*) FROM indi_dedup)
    UNION ALL SELECT 6, 'ther', (SELECT count(*) FROM raw_ther), (SELECT count(*) FROM ther_dedup)
    UNION ALL SELECT 7, 'rpsr', (SELECT count(*) FROM raw_rpsr), (SELECT count(*) FROM rpsr_dedup)
)
SELECT
    ord,
    tbl,
    rows_before,
    rows_after,
    rows_before - rows_after                                          AS rows_removed,
    round(100.0 * (rows_before - rows_after) / rows_before, 2)        AS pct_removed
FROM counts;

SELECT tbl, rows_before, rows_after, rows_removed, pct_removed
FROM dedup_audit
ORDER BY ord;

-- 4. Integrity checks: every row should show passed = true.
SELECT 'demo_dedup: one row per caseid' AS check_name,
       count(*) = count(DISTINCT caseid) AS passed
FROM demo_dedup
UNION ALL
SELECT 'demo_dedup: one row per primaryid',
       count(*) = count(DISTINCT primaryid)
FROM demo_dedup
UNION ALL
SELECT 'no case lost (distinct caseid raw = rows dedup)',
       (SELECT count(DISTINCT caseid) FROM raw_demo) = (SELECT count(*) FROM demo_dedup)
UNION ALL
SELECT 'drug_dedup has no orphans', count(*) = 0 FROM drug_dedup t
  WHERE NOT EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'reac_dedup has no orphans', count(*) = 0 FROM reac_dedup t
  WHERE NOT EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid)
UNION ALL
SELECT 'outc_dedup has no orphans', count(*) = 0 FROM outc_dedup t
  WHERE NOT EXISTS (SELECT 1 FROM demo_dedup d WHERE d.primaryid = t.primaryid);