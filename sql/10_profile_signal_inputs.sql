-- sql/10_profile_signal_inputs.sql
-- Purpose: (1) explain the small count differences between sql/06 and drug_clean,
--          (2) profile the reaction data that PRR/ROR will use. Read-only.
-- Run: python src/run_sql.py sql/10_profile_signal_inputs.sql

-- 1. Which raw strings add extra reports to METHOTREXATE / TIRZEPATIDE / SEMAGLUTIDE?
--    (Expected: combination strings that contain them, which sql/06 counted under the combined string.)
SELECT ingredient, ingredient_raw, count(DISTINCT primaryid) AS reports
FROM drug_clean
WHERE ingredient IN ('METHOTREXATE', 'TIRZEPATIDE', 'SEMAGLUTIDE')
  AND ingredient_raw <> ingredient
GROUP BY ingredient, ingredient_raw
ORDER BY ingredient, reports DESC
LIMIT 30;

-- 2. Denominator for the 2x2 tables: cases that have BOTH a suspect ingredient and a reaction.
SELECT
    (SELECT count(*) FROM demo_clean)                                  AS all_cases,
    (SELECT count(DISTINCT primaryid) FROM case_ingredient)            AS cases_with_suspect,
    (SELECT count(DISTINCT primaryid) FROM reac_clean r
       WHERE EXISTS (SELECT 1 FROM case_ingredient c WHERE c.primaryid = r.primaryid))
                                                                       AS cases_with_suspect_and_reaction,
    (SELECT count(DISTINCT pt) FROM reac_clean)                        AS distinct_reaction_terms;

-- 3. Reaction terms per case.
SELECT quantile_cont(n, 0.5)  AS median_pts,
       quantile_cont(n, 0.9)  AS p90_pts,
       quantile_cont(n, 0.99) AS p99_pts,
       max(n)                 AS max_pts
FROM (SELECT primaryid, count(*) AS n FROM reac_clean GROUP BY primaryid);

-- 4. The 30 most frequent reaction terms. (Generic or administrative terms will show up here.)
SELECT pt,
       count(*) AS cases,
       round(100.0 * count(*) / (SELECT count(*) FROM demo_clean), 2) AS pct_of_cases
FROM reac_clean
GROUP BY pt
ORDER BY cases DESC
LIMIT 30;