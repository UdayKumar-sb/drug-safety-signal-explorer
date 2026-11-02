-- sql/09b_validate_drug_clean.sql
-- Purpose: prove drug_clean and case_ingredient behave as intended. Read-only.
-- Run: python src/run_sql.py sql/09b_validate_drug_clean.sql

-- 1. Pipeline counts. drug_clean_rows > suspect_drug_entries because combinations are split.
SELECT
    (SELECT count(*) FROM (SELECT DISTINCT primaryid, drug_seq FROM drug_dedup WHERE role_cod IN ('PS', 'SS')))
                                                          AS suspect_drug_entries,
    (SELECT count(*) FROM drug_clean)                     AS drug_clean_rows,
    (SELECT count(*) FROM case_ingredient)                AS case_ingredient_rows,
    (SELECT count(DISTINCT primaryid) FROM case_ingredient) AS cases_covered,
    (SELECT count(DISTINCT ingredient) FROM case_ingredient) AS distinct_ingredients;

-- 2. How much did canonicalization shrink the ingredient vocabulary?
SELECT
    count(DISTINCT ingredient_raw)                                       AS raw_ingredient_strings,
    count(DISTINCT ingredient_raw) FILTER (WHERE is_combination)         AS combination_strings,
    count(DISTINCT ingredient_raw) FILTER (WHERE suffix_stripped)        AS strings_with_suffix_removed,
    count(DISTINCT ingredient)                                           AS canonical_ingredients
FROM drug_clean;

-- 3. Integrity checks: every row should show passed = true.
SELECT 'no blank ingredient' AS check_name,
       count(*) = 0 AS passed
FROM drug_clean WHERE ingredient IS NULL OR ingredient = ''
UNION ALL
SELECT 'no backslash left in ingredient',
       count(*) = 0 FROM drug_clean WHERE strpos(ingredient, chr(92)) > 0
UNION ALL
SELECT 'no biologic suffix left in ingredient',
       count(*) = 0 FROM drug_clean WHERE regexp_matches(ingredient, '-[A-Z]{4}$')
UNION ALL
SELECT 'case_ingredient: one row per (case, ingredient)',
       (SELECT count(*) FROM case_ingredient)
         = (SELECT count(*) FROM (SELECT DISTINCT primaryid, ingredient FROM case_ingredient))
UNION ALL
SELECT 'no case lost (suspect cases in drug_dedup = cases in case_ingredient)',
       (SELECT count(DISTINCT primaryid) FROM drug_dedup WHERE role_cod IN ('PS', 'SS'))
         = (SELECT count(DISTINCT primaryid) FROM case_ingredient)
UNION ALL
SELECT 'no conflicting rows per (primaryid, drug_seq)',
       (SELECT count(*) FROM (SELECT DISTINCT primaryid, drug_seq FROM drug_clean))
         = (SELECT count(*) FROM (SELECT DISTINCT primaryid, drug_seq, role_cod, drug_name, ingredient_raw FROM drug_clean))
UNION ALL
SELECT 'case_ingredient: no orphans vs demo_clean',
       count(*) = 0 FROM case_ingredient ci
       WHERE NOT EXISTS (SELECT 1 FROM demo_clean d WHERE d.primaryid = ci.primaryid);

-- 4. Reconciliation with sql/06 (those counts were taken before splitting and stripping).
--    A mismatch is a prompt to investigate (a combination may legitimately contain the ingredient).
SELECT e.ing                           AS ingredient,
       e.expected                      AS reports_in_profile_06,
       count(ci.primaryid)             AS reports_now,
       count(ci.primaryid) = e.expected AS matches
FROM (VALUES ('DUPILUMAB', 77013), ('TIRZEPATIDE', 38202), ('SEMAGLUTIDE', 20872), ('METHOTREXATE', 6700))
     AS e(ing, expected)
LEFT JOIN case_ingredient ci ON ci.ingredient = e.ing
GROUP BY e.ing, e.expected;

-- 5. Effect of suffix stripping on the biologics that have many biosimilar variants.
SELECT ingredient,
       count(DISTINCT primaryid)                                   AS reports_after_merge,
       count(DISTINCT primaryid) FILTER (WHERE NOT suffix_stripped) AS reports_with_plain_name,
       count(DISTINCT primaryid) FILTER (WHERE suffix_stripped)     AS reports_via_suffixed_name,
       count(DISTINCT ingredient_raw)                              AS raw_strings_merged
FROM drug_clean
WHERE ingredient IN ('ADALIMUMAB', 'INFLIXIMAB', 'USTEKINUMAB', 'RITUXIMAB', 'TRASTUZUMAB',
                     'DENOSUMAB', 'BEVACIZUMAB', 'INSULIN GLARGINE', 'PEGFILGRASTIM', 'FILGRASTIM')
GROUP BY ingredient
ORDER BY reports_after_merge DESC;

-- 6. Combination edge cases: the HYALURONIDASE co-formulations and the duplicated TREMELIMUMAB string.
SELECT ingredient_raw, ingredient, count(DISTINCT primaryid) AS reports
FROM drug_clean
WHERE ingredient_raw LIKE '%HYALURONIDASE%' OR ingredient_raw LIKE 'TREMELIMUMAB%'
GROUP BY ingredient_raw, ingredient
ORDER BY ingredient_raw, ingredient;

SELECT ingredient,
       count(*)                                   AS cases,
       count(*) FILTER (WHERE from_combination)   AS cases_from_combination
FROM case_ingredient
WHERE ingredient = 'HYALURONIDASE'
GROUP BY ingredient;

-- 7. Preview of what PRR will see: top 20 ingredients, with the PS-only count for the sensitivity run.
SELECT ingredient,
       count(*)                                   AS reports_ps_or_ss,
       count(*) FILTER (WHERE is_primary_suspect) AS reports_ps_only
FROM case_ingredient
GROUP BY ingredient
ORDER BY reports_ps_or_ss DESC
LIMIT 20;