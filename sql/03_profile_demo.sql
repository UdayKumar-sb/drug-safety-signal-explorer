-- sql/03_profile_demo.sql
-- Purpose: see the real values in the columns we are about to clean. Read-only.
-- Run: python src/run_sql.py sql/03_profile_demo.sql

SELECT 'age_cod' AS col, age_cod AS val, count(*) AS n FROM demo_dedup GROUP BY 2
UNION ALL SELECT 'sex', sex, count(*) FROM demo_dedup GROUP BY 2
UNION ALL SELECT 'wt_cod', wt_cod, count(*) FROM demo_dedup GROUP BY 2
UNION ALL SELECT 'event_dt_len', length(event_dt)::VARCHAR, count(*) FROM demo_dedup GROUP BY 2
UNION ALL SELECT 'fda_dt_len', length(fda_dt)::VARCHAR, count(*) FROM demo_dedup GROUP BY 2
UNION ALL SELECT 'rept_cod', rept_cod, count(*) FROM demo_dedup GROUP BY 2
ORDER BY col, n DESC;