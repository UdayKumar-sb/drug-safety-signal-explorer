-- sql/03c_validate_age_grp.sql
-- Purpose: confirm age_grp meanings and boundaries against numeric age; check for age = 0. Read-only.

-- 1. Numeric age range per age_grp (rows where both exist)
WITH a AS (
    SELECT age_grp,
           TRY_CAST(age AS DOUBLE) *
           CASE age_cod
               WHEN 'DEC' THEN 10.0 WHEN 'YR' THEN 1.0 WHEN 'MON' THEN 1 / 12.0
               WHEN 'WK' THEN 1 / 52.18 WHEN 'DY' THEN 1 / 365.25 WHEN 'HR' THEN 1 / 8766.0
           END AS age_years
    FROM demo_dedup
)
SELECT age_grp,
       count(*)                                AS n_with_both,
       round(min(age_years), 2)                AS min_yrs,
       round(quantile_cont(age_years, 0.05), 2) AS p05,
       round(quantile_cont(age_years, 0.5), 1)  AS median_yrs,
       round(quantile_cont(age_years, 0.95), 1) AS p95,
       round(max(age_years), 1)                AS max_yrs
FROM a
WHERE age_grp IS NOT NULL AND age_years IS NOT NULL
GROUP BY age_grp
ORDER BY median_yrs;

-- 2. How many ages are exactly 0 (newborn vs placeholder)?
SELECT count(*) FILTER (WHERE TRY_CAST(age AS DOUBLE) = 0)  AS age_value_zero,
       count(*) FILTER (WHERE TRY_CAST(age AS DOUBLE) = 0 AND age_cod = 'YR') AS zero_in_years
FROM demo_dedup;