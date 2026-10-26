-- sql/03b_profile_age_weight.sql
-- Purpose: check age/unit overlap, age_grp coverage, weight/unit overlap, and converted-age sanity.
-- Read-only. Run: python src/run_sql.py sql/03b_profile_age_weight.sql

-- 1. Is an age value present when the unit is missing (and vice versa)?
SELECT (age IS NOT NULL) AS has_age, (age_cod IS NOT NULL) AS has_age_cod, count(*) AS n
FROM demo_dedup
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2. age_grp coverage, and how many of those rows have no usable numeric age
SELECT age_grp, count(*) AS n,
       count(*) FILTER (WHERE age IS NULL OR age_cod IS NULL) AS no_usable_age
FROM demo_dedup
GROUP BY 1
ORDER BY n DESC;

-- 3. Weight value vs weight unit
SELECT (wt IS NOT NULL) AS has_wt, wt_cod, count(*) AS n
FROM demo_dedup
GROUP BY 1, 2
ORDER BY n DESC;

-- 4. Converted age sanity (negatives, >120, min / median / max)
WITH a AS (
    SELECT TRY_CAST(age AS DOUBLE) *
           CASE age_cod
               WHEN 'DEC' THEN 10.0
               WHEN 'YR'  THEN 1.0
               WHEN 'MON' THEN 1 / 12.0
               WHEN 'WK'  THEN 1 / 52.18
               WHEN 'DY'  THEN 1 / 365.25
               WHEN 'HR'  THEN 1 / 8766.0
           END AS age_years
    FROM demo_dedup
)
SELECT count(*) FILTER (WHERE age_years IS NOT NULL)  AS convertible,
       count(*) FILTER (WHERE age_years < 0)          AS negative,
       count(*) FILTER (WHERE age_years > 120)        AS over_120,
       round(min(age_years), 3)                       AS min_age,
       round(quantile_cont(age_years, 0.5), 1)        AS median_age,
       round(max(age_years), 1)                       AS max_age
FROM a;