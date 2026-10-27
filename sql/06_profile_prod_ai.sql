-- sql/06_profile_prod_ai.sql
-- Purpose: decide whether prod_ai (active ingredient) can be the backbone of drug normalization,
--          and define the right unit of analysis for signal counting. Read-only.
-- Run: python src/run_sql.py sql/06_profile_prod_ai.sql

-- 1a. Cases with more than one primary-suspect (PS) row: how common?
SELECT ps_rows, count(*) AS cases
FROM (SELECT primaryid, count(*) AS ps_rows FROM drug_dedup WHERE role_cod = 'PS' GROUP BY primaryid)
GROUP BY ps_rows
ORDER BY ps_rows
LIMIT 10;

-- 1b. In those multi-PS cases, is it the same ingredient repeated, or genuinely different drugs?
SELECT count(*)                                  AS cases_with_multiple_ps_rows,
       count(*) FILTER (WHERE n_ingredients = 1) AS same_ingredient_repeated,
       count(*) FILTER (WHERE n_ingredients > 1) AS different_ingredients
FROM (
    SELECT primaryid, count(DISTINCT upper(trim(prod_ai))) AS n_ingredients
    FROM drug_dedup
    WHERE role_cod = 'PS'
    GROUP BY primaryid
    HAVING count(*) > 1
);

-- 1c. Exact duplicate drug_seq within a report?
SELECT coalesce(sum(c - 1), 0) AS duplicate_drug_seq_rows
FROM (SELECT count(*) AS c FROM drug_dedup GROUP BY primaryid, drug_seq HAVING count(*) > 1);

-- 2. Messiness INSIDE prod_ai (suspect rows): delimiters, biologic suffixes, salt words.
SELECT count(DISTINCT ai)                                                           AS distinct_ingredients,
       count(DISTINCT ai) FILTER (WHERE strpos(ai, ';') > 0)                        AS has_semicolon,
       count(DISTINCT ai) FILTER (WHERE strpos(ai, chr(92)) > 0)                    AS has_backslash,
       count(DISTINCT ai) FILTER (WHERE strpos(ai, '/') > 0)                        AS has_slash,
       count(DISTINCT ai) FILTER (WHERE strpos(ai, ',') > 0)                        AS has_comma,
       count(DISTINCT ai) FILTER (WHERE regexp_matches(ai, '-[A-Z]{4}$'))           AS has_biologic_suffix,
       count(DISTINCT ai) FILTER (WHERE regexp_matches(ai,
           'HYDROCHLORIDE|SODIUM|SULFATE|ACETATE|MESYLATE|MALEATE|TARTRATE|CITRATE|PHOSPHATE|BESYLATE|FUMARATE|SUCCINATE'))
                                                                                    AS has_salt_word
FROM (
    SELECT upper(trim(prod_ai)) AS ai
    FROM drug_dedup
    WHERE role_cod IN ('PS', 'SS') AND prod_ai IS NOT NULL
);

-- 3a. Ambiguity: how many suspect names map to MORE than one ingredient?
WITH m AS (
    SELECT upper(trim(drugname)) AS nm,
           count(DISTINCT upper(trim(prod_ai))) AS n_ai,
           count(*) AS n
    FROM drug_dedup
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY 1
)
SELECT count(*)                                  AS suspect_names,
       count(*) FILTER (WHERE n_ai > 1)          AS names_with_multiple_ingredients,
       sum(n) FILTER (WHERE n_ai > 1)            AS rows_in_those_names,
       sum(n)                                    AS suspect_rows
FROM m;

-- 3b. The biggest ambiguous names (these decide whether prod_ai can be trusted blindly).
WITH m AS (
    SELECT upper(trim(drugname)) AS nm,
           count(DISTINCT upper(trim(prod_ai))) AS n_ai,
           count(*) AS n
    FROM drug_dedup
    WHERE role_cod IN ('PS', 'SS')
    GROUP BY 1
)
SELECT nm AS drug_name, n_ai AS ingredients_mapped, n AS rows
FROM m
WHERE n_ai > 1
ORDER BY n DESC
LIMIT 15;

-- 4. How often does the name already contain the ingredient? (Cases a simple rule can resolve.)
SELECT count(*) AS suspect_rows,
       count(*) FILTER (WHERE strpos(upper(drugname), upper(trim(prod_ai))) > 0) AS name_contains_ingredient,
       round(100.0 * count(*) FILTER (WHERE strpos(upper(drugname), upper(trim(prod_ai))) > 0) / count(*), 2)
                                                                                  AS pct_name_contains_ingredient
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS');

-- 5. Does val_vbm line up with prod_ai being present? (Tests the layout-document reading against YOUR data.)
SELECT role_cod, val_vbm, count(*) AS n, count(prod_ai) AS with_prod_ai
FROM drug_dedup
GROUP BY role_cod, val_vbm
ORDER BY role_cod, val_vbm;

-- 6. The grouping key PRR will use: top 30 ingredients by number of reports, with how many names feed each.
SELECT upper(trim(prod_ai))                       AS ingredient,
       count(DISTINCT primaryid)                  AS reports,
       count(DISTINCT upper(trim(drugname)))      AS distinct_names
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS')
GROUP BY 1
ORDER BY reports DESC
LIMIT 30;