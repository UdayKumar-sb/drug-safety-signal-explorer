-- sql/09_build_drug_clean.sql
-- Purpose: turn drug_dedup into signal-ready tables.
--   drug_clean      : one row per suspect drug entry and ingredient component
--   case_ingredient : one row per (case, ingredient)  <- the table PRR / ROR will read
-- Inputs: drug_dedup. Idempotent (CREATE OR REPLACE).
-- Run: python src/run_sql.py sql/09_build_drug_clean.sql
--
-- Approved decisions (see project notes):
--   1. Roles: PS and SS only (PS-only kept as a flag for the sensitivity run). C, I, DN excluded.
--   2. Ingredient comes from prod_ai (100% present on suspect rows); original drugname kept.
--   3. Counting unit: distinct (case, ingredient).
--   4. Combination products are split on backslash; is_combination flag kept.
--   5. Biologic suffix (-xxxx) stripped to the base ingredient; raw string kept.
--   6. Salts are NOT touched here (deferred to the week-4 experiment).
--
-- ORDER MATTERS: split on backslash FIRST, then strip the suffix from each component.
-- (e.g. DARATUMUMAB\HYALURONIDASE-FIHJ -> DARATUMUMAB + HYALURONIDASE)

CREATE OR REPLACE TABLE drug_clean AS
WITH suspect AS (
    -- DISTINCT collapses the repeated drug_seq rows (they differ only in dose / lot / route,
    -- which we do not use). sql/07 showed name, ingredient and role never differ inside a group.
    SELECT DISTINCT
        primaryid,
        caseid,
        drug_seq,
        role_cod,
        upper(trim(drugname)) AS drug_name,
        upper(trim(prod_ai))  AS ingredient_raw
    FROM drug_dedup
    WHERE role_cod IN ('PS', 'SS')
      AND prod_ai IS NOT NULL
      AND trim(prod_ai) <> ''
),
split AS (
    SELECT *,
           unnest(string_split(ingredient_raw, chr(92))) AS component   -- chr(92) = backslash
    FROM suspect
),
parsed AS (
    SELECT
        primaryid,
        caseid,
        drug_seq,
        role_cod,
        drug_name,
        ingredient_raw,
        trim(regexp_replace(trim(component), '-[A-Z]{4}$', ''))  AS ingredient,
        strpos(ingredient_raw, chr(92)) > 0                      AS is_combination,
        regexp_matches(trim(component), '-[A-Z]{4}$')            AS suffix_stripped
    FROM split
)
SELECT *
FROM parsed
WHERE ingredient <> '';

-- One row per (case, ingredient). A case counts once per ingredient even if the drug
-- appears on several rows, under several brand names, or twice inside a combination.
CREATE OR REPLACE TABLE case_ingredient AS
SELECT
    primaryid,
    caseid,
    ingredient,
    bool_or(role_cod = 'PS')   AS is_primary_suspect,   -- for the PS-only sensitivity run
    bool_or(is_combination)    AS from_combination
FROM drug_clean
GROUP BY primaryid, caseid, ingredient;