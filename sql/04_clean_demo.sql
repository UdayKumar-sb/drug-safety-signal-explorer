-- sql/04_clean_demo.sql
-- Purpose: typed, analysis-ready demographics (demo_clean) and distinct reactions (reac_clean).
-- Inputs: demo_dedup, reac_dedup. Idempotent (CREATE OR REPLACE).
-- Run: python src/run_sql.py sql/04_clean_demo.sql
--
-- Design rules (defend in interviews):
--   * No imputation in SQL. Missing stays NULL; the model step fills values using training data only.
--   * Age is converted to years only when a unit exists. We never guess a missing unit.
--   * Numeric age wins over the age_grp code; age_grp is only a fallback (and is labelled as such).
--   * Implausible values become NULL (not dropped rows), so no case is lost.

CREATE OR REPLACE TABLE demo_clean AS
WITH typed AS (
    SELECT
        primaryid,
        caseid,
        TRY_CAST(caseversion AS INTEGER)               AS caseversion,
        quarter,
        i_f_code,
        rept_cod,
        occp_cod,
        reporter_country,
        occr_country,
        CASE WHEN sex IN ('F', 'M') THEN sex ELSE 'Unknown' END AS sex,
        age_cod,
        age_grp,
        TRY_CAST(age AS DOUBLE)                        AS age_value,
        -- age converted to years; NULL when the unit is missing or unrecognised
        TRY_CAST(age AS DOUBLE) * CASE age_cod
            WHEN 'DEC' THEN 10.0
            WHEN 'YR'  THEN 1.0
            WHEN 'MON' THEN 1 / 12.0
            WHEN 'WK'  THEN 7 / 365.25
            WHEN 'DY'  THEN 1 / 365.25
            WHEN 'HR'  THEN 1 / 8766.0
        END                                            AS age_years_raw,
        -- weight in kg; NULL when the unit is missing
        CASE wt_cod
            WHEN 'KG'  THEN TRY_CAST(wt AS DOUBLE)
            WHEN 'LBS' THEN TRY_CAST(wt AS DOUBLE) * 0.45359237
        END                                            AS weight_kg_raw,
        TRY_STRPTIME(event_dt,    '%Y%m%d')::DATE      AS event_date_raw,
        TRY_STRPTIME(init_fda_dt, '%Y%m%d')::DATE      AS init_fda_date,
        TRY_STRPTIME(fda_dt,      '%Y%m%d')::DATE      AS fda_date
    FROM demo_dedup
)
SELECT
    primaryid,
    caseid,
    caseversion,
    quarter,
    i_f_code,
    rept_cod,
    occp_cod,
    reporter_country,
    occr_country,
    sex,

    -- Age in years, plausible range only (0-120)
    CASE WHEN age_years_raw BETWEEN 0 AND 120 THEN age_years_raw END AS age_years,

    -- Where the age group came from, so every analysis can report how much rests on the fallback
    CASE
        WHEN age_years_raw BETWEEN 0 AND 120 THEN 'age_value'
        WHEN age_grp IS NOT NULL             THEN 'age_grp'
        ELSE 'missing'
    END AS age_group_source,

    -- Six FDA-style groups plus Unknown
    CASE
        WHEN age_years_raw BETWEEN 0 AND 120 THEN
            CASE
                -- "0 years" means under 1 year: neonate vs infant is ambiguous, so use the code if it says N
                WHEN age_cod = 'YR' AND age_value = 0 THEN
                    CASE WHEN age_grp = 'N' THEN 'Neonate' ELSE 'Infant' END
                WHEN age_years_raw < 1 / 12.0 THEN 'Neonate'
                WHEN age_years_raw < 2        THEN 'Infant'
                WHEN age_years_raw < 12       THEN 'Child'
                WHEN age_years_raw < 18       THEN 'Adolescent'
                WHEN age_years_raw < 65       THEN 'Adult'
                ELSE 'Elderly'
            END
        ELSE
            CASE age_grp
                WHEN 'N' THEN 'Neonate'
                WHEN 'I' THEN 'Infant'
                WHEN 'C' THEN 'Child'
                WHEN 'T' THEN 'Adolescent'
                WHEN 'A' THEN 'Adult'
                WHEN 'E' THEN 'Elderly'
                ELSE 'Unknown'
            END
    END AS age_group,

    CASE WHEN weight_kg_raw BETWEEN 0.3 AND 500 THEN round(weight_kg_raw, 2) END AS weight_kg,

    -- An event cannot happen after FDA received the report, or before 1900
    CASE WHEN event_date_raw BETWEEN DATE '1900-01-01' AND fda_date THEN event_date_raw END AS event_date,
    init_fda_date,
    fda_date,
    date_trunc('month', fda_date)::DATE AS fda_month
FROM typed;

-- Reactions: one row per (report, preferred term). Removes within-report duplicates
-- and blank terms. Note: PRR must still use COUNT(DISTINCT primaryid).
CREATE OR REPLACE TABLE reac_clean AS
SELECT DISTINCT
    primaryid,
    caseid,
    trim(pt) AS pt
FROM reac_dedup
WHERE pt IS NOT NULL
  AND trim(pt) <> '';