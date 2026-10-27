-- sql/05_profile_drug.sql
-- Purpose: understand drug roles and drug-name messiness BEFORE writing normalization rules.
-- Read-only. Run: python src/run_sql.py sql/05_profile_drug.sql

-- 1. Drug roles: PS = primary suspect, SS = secondary suspect, C = concomitant, I = interacting.
SELECT role_cod,
       count(*)                                           AS drug_rows,
       count(DISTINCT primaryid)                          AS reports,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_drug_rows
FROM drug_dedup
GROUP BY role_cod
ORDER BY drug_rows DESC;

-- 2. How many cases have a suspect drug at all? (Cases with none cannot contribute to signal analysis.)
SELECT count(*)                                              AS cases,
       count(*) FILTER (WHERE coalesce(has_ps, false))       AS cases_with_ps,
       count(*) FILTER (WHERE coalesce(has_suspect, false))  AS cases_with_ps_or_ss,
       count(*) FILTER (WHERE NOT coalesce(has_suspect, false)) AS cases_without_suspect
FROM (
    SELECT c.primaryid,
           bool_or(g.role_cod = 'PS')              AS has_ps,
           bool_or(g.role_cod IN ('PS', 'SS'))     AS has_suspect
    FROM demo_clean c
    LEFT JOIN drug_dedup g ON g.primaryid = c.primaryid
    GROUP BY c.primaryid
);

-- 3. Drugs listed per report (polypharmacy).
SELECT count(*)                          AS reports_with_drugs,
       quantile_cont(n, 0.5)             AS median_drugs,
       quantile_cont(n, 0.9)             AS p90_drugs,
       quantile_cont(n, 0.99)            AS p99_drugs,
       max(n)                            AS max_drugs
FROM (SELECT primaryid, count(*) AS n FROM drug_dedup GROUP BY primaryid);

-- 4. Name cardinality: how much collapses with trivial cleaning (case + whitespace only)?
SELECT count(*)                                              AS drug_rows,
       count(drugname)                                       AS drugname_present,
       count(*) FILTER (WHERE trim(drugname) = '')           AS drugname_blank,
       count(DISTINCT drugname)                              AS distinct_raw,
       count(DISTINCT upper(trim(drugname)))                 AS distinct_upper_trim,
       count(prod_ai)                                        AS prod_ai_present,
       count(DISTINCT upper(trim(prod_ai)))                  AS distinct_prod_ai
FROM drug_dedup;

-- 5. Messiness patterns among distinct (upper/trimmed) names.
SELECT count(*)                                                                 AS distinct_names,
       count(*) FILTER (WHERE regexp_matches(nm, '[0-9]'))                      AS has_digit,
       count(*) FILTER (WHERE nm LIKE '%(%')                                    AS has_parenthesis,
       count(*) FILTER (WHERE nm LIKE '%/%')                                    AS has_slash,
       count(*) FILTER (WHERE nm LIKE '%,%')                                    AS has_comma,
       count(*) FILTER (WHERE regexp_matches(nm, '^(UNKNOWN|UNSPECIFIED|NOT SPECIFIED|NOT AVAILABLE|N/A|NA|NONE|UNK)$'))
                                                                                AS placeholder_names
FROM (SELECT DISTINCT upper(trim(drugname)) AS nm FROM drug_dedup WHERE drugname IS NOT NULL);

-- 6. Concentration: how many distinct names cover 50 / 80 / 90 / 95% of suspect-drug rows?
--    This sizes the hand-labeled sample and the week-4 LLM bill.
WITH freq AS (
    SELECT upper(trim(drugname)) AS nm, count(*) AS n
    FROM drug_dedup
    WHERE role_cod IN ('PS', 'SS') AND drugname IS NOT NULL
    GROUP BY 1
),
ranked AS (
    SELECT nm, n,
           row_number() OVER (ORDER BY n DESC, nm) AS rnk,
           sum(n) OVER (ORDER BY n DESC, nm)       AS cum_n,
           sum(n) OVER ()                          AS total
    FROM freq
)
SELECT count(*)                                              AS distinct_suspect_names,
       min(rnk) FILTER (WHERE cum_n >= 0.50 * total)         AS names_for_50pct,
       min(rnk) FILTER (WHERE cum_n >= 0.80 * total)         AS names_for_80pct,
       min(rnk) FILTER (WHERE cum_n >= 0.90 * total)         AS names_for_90pct,
       min(rnk) FILTER (WHERE cum_n >= 0.95 * total)         AS names_for_95pct,
       max(total)                                            AS suspect_rows
FROM ranked;

-- 7. Top 30 suspect-drug names by report count.
SELECT upper(trim(drugname)) AS drug_name, count(DISTINCT primaryid) AS reports
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS') AND drugname IS NOT NULL
GROUP BY 1
ORDER BY reports DESC
LIMIT 30;

-- 8. Is prod_ai (active ingredient) a usable anchor? Coverage, then the most common name -> ingredient pairs.
SELECT count(*)                                              AS suspect_rows,
       count(prod_ai)                                        AS with_prod_ai,
       round(100.0 * count(prod_ai) / count(*), 2)           AS pct_with_prod_ai
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS');

SELECT upper(trim(drugname)) AS drug_name, upper(trim(prod_ai)) AS prod_ai, count(*) AS n
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS')
GROUP BY 1, 2
ORDER BY n DESC
LIMIT 25;

-- 9. val_vbm: distribution only. Check the FDA layout document for what the codes mean before using it.
SELECT val_vbm, count(*) AS n FROM drug_dedup GROUP BY val_vbm ORDER BY n DESC;

-- 10. Random sample of 40 DISTINCT names (rare, messy names show up, unlike a frequency-weighted sample).
SELECT sample_name
FROM (
    SELECT DISTINCT upper(trim(drugname)) AS sample_name
    FROM drug_dedup
    WHERE drugname IS NOT NULL
)
ORDER BY random()
LIMIT 40;