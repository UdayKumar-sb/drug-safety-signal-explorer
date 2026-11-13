-- sql/12b_audit_cluster_recount_quality.sql
-- Read-only audit, round 2. Creates only SESSION-LEVEL temp tables (audit_*); they disappear when the
-- runner exits. No project table is created, changed or dropped.
-- Run: python src/run_sql.py sql/12b_audit_cluster_recount_quality.sql

-- ======================================================================================
-- A. The SULFAGUANIDINE / Amyloid arthropathy cluster
-- ======================================================================================
CREATE OR REPLACE TEMP TABLE audit_cluster AS
SELECT DISTINCT ci.primaryid
FROM case_ingredient ci
JOIN reac_clean r ON r.primaryid = ci.primaryid
WHERE ci.ingredient = 'SULFAGUANIDINE' AND r.pt = 'Amyloid arthropathy';

-- A1. RAW source fields (untouched by our cleaning): are the shared values genuine source values?
--     Also shows sender, version number and the primary-suspect product of each case.
SELECT d.primaryid, d.caseid, d.caseversion, d.i_f_code, d.rept_cod, d.mfr_sndr,
       d.reporter_country, d.occr_country, d.event_dt, d.init_fda_dt, d.fda_dt,
       d.age, d.age_cod, d.sex, d.e_sub,
       (SELECT min(upper(trim(g.drugname))) FROM drug_dedup g
         WHERE g.primaryid = d.primaryid AND g.role_cod = 'PS')                AS ps_drug_alpha_first,
       (SELECT count(DISTINCT upper(trim(g.drugname))) FROM drug_dedup g
         WHERE g.primaryid = d.primaryid AND g.role_cod = 'PS')                AS n_ps_names
FROM demo_dedup d
JOIN audit_cluster h ON h.primaryid = d.primaryid
ORDER BY d.fda_dt, d.primaryid;

-- A2. The "core" profile: ingredients and reaction terms present in at least 20 of the cluster cases.
SELECT kind, term, count(*) AS cases_in_cluster,
       round(100.0 * count(*) / (SELECT count(*) FROM audit_cluster), 0) AS pct_of_cluster
FROM (
    SELECT 'ingredient' AS kind, ci.ingredient AS term, ci.primaryid
    FROM case_ingredient ci JOIN audit_cluster h ON h.primaryid = ci.primaryid
    UNION ALL
    SELECT 'reaction', r.pt, r.primaryid
    FROM reac_clean r JOIN audit_cluster h ON h.primaryid = r.primaryid
)
GROUP BY kind, term
HAVING count(*) >= 20
ORDER BY kind, cases_in_cluster DESC;

-- A3. Pairwise Jaccard similarity of ingredient sets and reaction sets across all case pairs in the cluster
--     (1.0 = identical sets, 0 = nothing shared).
WITH items AS (
    SELECT ci.primaryid, 'ingredient' AS kind, ci.ingredient AS term
    FROM case_ingredient ci JOIN audit_cluster h ON h.primaryid = ci.primaryid
    UNION ALL
    SELECT r.primaryid, 'reaction', r.pt
    FROM reac_clean r JOIN audit_cluster h ON h.primaryid = r.primaryid
),
sizes AS (
    SELECT kind, primaryid, count(*) AS n FROM items GROUP BY kind, primaryid
),
shared AS (
    SELECT x.kind, x.primaryid AS p1, y.primaryid AS p2, count(*) AS n_shared
    FROM items x
    JOIN items y ON x.kind = y.kind AND x.term = y.term AND x.primaryid < y.primaryid
    GROUP BY x.kind, x.primaryid, y.primaryid
)
SELECT s.kind,
       count(*)                                                        AS case_pairs,
       round(min(s.n_shared * 1.0 / (a.n + b.n - s.n_shared)), 2)      AS min_jaccard,
       round(quantile_cont(s.n_shared * 1.0 / (a.n + b.n - s.n_shared), 0.5), 2) AS median_jaccard,
       round(avg(s.n_shared * 1.0 / (a.n + b.n - s.n_shared)), 2)      AS mean_jaccard
FROM shared s
JOIN sizes a ON a.kind = s.kind AND a.primaryid = s.p1
JOIN sizes b ON b.kind = s.kind AND b.primaryid = s.p2
GROUP BY s.kind;

-- A4a. Is day 1 of the month an over-used "default" onset day across the whole database?
SELECT count(*) AS dated_cases,
       round(100.0 * count(*) FILTER (WHERE day(event_date) = 1) / count(*), 1) AS pct_event_dates_on_day_1,
       round(100.0 / 30.4, 1) AS expected_pct_if_uniform
FROM demo_clean
WHERE event_date IS NOT NULL;

-- A4b. How busy is 2020-10-01 compared with its neighbouring days?
SELECT event_date, count(*) AS cases
FROM demo_clean
WHERE event_date BETWEEN DATE '2020-09-27' AND DATE '2020-10-05'
GROUP BY event_date
ORDER BY event_date;

-- A4c. How rare is the demographic profile (F, age 68-69, GB, onset 2020-10-01) in the whole database?
SELECT count(*) AS cases_with_profile,
       count(*) FILTER (WHERE d.primaryid IN (SELECT primaryid FROM audit_cluster)) AS of_which_in_cluster
FROM demo_clean d
WHERE d.sex = 'F' AND d.age_years >= 68 AND d.age_years < 70
  AND d.reporter_country = 'GB' AND d.event_date = DATE '2020-10-01';

-- ======================================================================================
-- B. Independent recount from the pre-clean tables (drug_dedup, reac_dedup), NOT from signal_* tables
-- ======================================================================================
-- Sample = 7 fixed pairs + 12 random pairs. Random pairs are limited to ingredients whose prod_ai string
-- needs no splitting or suffix stripping, so a raw recount should match exactly.
-- chi2_expected uses the sum of (O-E)^2/E, an algebraically different route from the build.
WITH fixed(ing, pt) AS (
    VALUES ('DUPILUMAB', 'Pruritus'),
           ('DUPILUMAB', 'Dermatitis atopic'),
           ('SEVOFLURANE', 'Anaesthetic complication neurological'),
           ('TECHNETIUM TC-99M TETROFOSMIN', 'Radioisotope scan abnormal'),
           ('MAGNESIUM OROTATE', 'Fractional exhaled nitric oxide increased'),
           ('SULFAGUANIDINE', 'Amyloid arthropathy'),
           ('PENFLURIDOL', 'Paroxysmal perceptual alteration')
),
safe_ingredients AS (
    SELECT DISTINCT ingredient FROM drug_clean
    EXCEPT
    SELECT DISTINCT ingredient FROM drug_clean WHERE ingredient_raw <> ingredient
),
random_pairs AS (
    SELECT ingredient AS ing, pt
    FROM signals
    WHERE scope = 'PS_SS' AND ingredient IN (SELECT ingredient FROM safe_ingredients)
    ORDER BY random()
    LIMIT 12
),
all_pairs AS (
    SELECT ing, pt FROM fixed
    UNION
    SELECT ing, pt FROM random_pairs
),
raw_universe AS (
    SELECT DISTINCT g.primaryid
    FROM drug_dedup g
    WHERE g.role_cod IN ('PS', 'SS')
      AND EXISTS (SELECT 1 FROM reac_dedup r WHERE r.primaryid = g.primaryid AND trim(r.pt) <> '')
),
raw_counts AS (
    SELECT p.ing, p.pt,
           (SELECT count(*) FROM raw_universe) AS n_total_raw,
           (SELECT count(DISTINCT g.primaryid) FROM drug_dedup g
             WHERE g.role_cod IN ('PS', 'SS') AND upper(trim(g.prod_ai)) = p.ing) AS n_drug_raw,
           (SELECT count(DISTINCT r.primaryid) FROM reac_dedup r
             JOIN raw_universe u ON u.primaryid = r.primaryid
             WHERE trim(r.pt) = p.pt) AS n_event_raw,
           (SELECT count(DISTINCT g.primaryid) FROM drug_dedup g
             JOIN reac_dedup r ON r.primaryid = g.primaryid
             WHERE g.role_cod IN ('PS', 'SS') AND upper(trim(g.prod_ai)) = p.ing
               AND trim(r.pt) = p.pt) AS a_raw
    FROM all_pairs p
),
cells AS (
    SELECT rc.*, s.a, s.n_drug, s.n_event, s.n_total, s.prr, s.chi2,
           rc.a_raw::DOUBLE                                                         AS a_,
           (rc.n_drug_raw - rc.a_raw)::DOUBLE                                       AS b_,
           (rc.n_event_raw - rc.a_raw)::DOUBLE                                      AS c_,
           (rc.n_total_raw - rc.n_drug_raw - rc.n_event_raw + rc.a_raw)::DOUBLE     AS d_,
           rc.n_drug_raw::DOUBLE * rc.n_event_raw / rc.n_total_raw                  AS e_a,
           rc.n_drug_raw::DOUBLE * (rc.n_total_raw - rc.n_event_raw) / rc.n_total_raw AS e_b,
           (rc.n_total_raw - rc.n_drug_raw)::DOUBLE * rc.n_event_raw / rc.n_total_raw AS e_c,
           (rc.n_total_raw - rc.n_drug_raw)::DOUBLE * (rc.n_total_raw - rc.n_event_raw) / rc.n_total_raw AS e_d
    FROM raw_counts rc
    JOIN signals s ON s.scope = 'PS_SS' AND s.ingredient = rc.ing AND s.pt = rc.pt
)
SELECT ing AS ingredient, pt,
       a, a_raw, n_drug, n_drug_raw, n_event, n_event_raw, n_total, n_total_raw,
       (a = a_raw AND n_drug = n_drug_raw AND n_event = n_event_raw AND n_total = n_total_raw) AS counts_match,
       round(prr, 2)                                              AS prr_signals,
       round((a_ / (a_ + b_)) / (c_ / (c_ + d_)), 2)              AS prr_recomputed_null_if_zero_cell,
       round(chi2, 1)                                             AS chi2_signals,
       round(power(a_ - e_a, 2) / e_a + power(b_ - e_b, 2) / e_b
           + power(c_ - e_c, 2) / e_c + power(d_ - e_d, 2) / e_d, 1) AS chi2_expected
FROM cells
ORDER BY counts_match, ingredient, pt;

-- ======================================================================================
-- C. Which reaction terms actually reach the top of the queue? (Eyeball for non-clinical terms.)
-- ======================================================================================
SELECT pt, count(*) AS pairs_in_top_500, max(a) AS max_cases
FROM (
    SELECT * FROM signals
    WHERE scope = 'PS_SS' AND meets_evans AND ror_signal AND NOT is_product_use_event
    ORDER BY ror_ci_low DESC
    LIMIT 500
)
GROUP BY pt
ORDER BY pairs_in_top_500 DESC, max_cases DESC
LIMIT 60;

-- ======================================================================================
-- D. Quality evidence for the current top 200 queue pairs (nothing is excluded here)
-- ======================================================================================
CREATE OR REPLACE TEMP TABLE audit_top_pairs AS
SELECT ingredient, pt, a, b, c, n_drug, n_event, ror_ci_low
FROM signals
WHERE scope = 'PS_SS' AND meets_evans AND ror_signal AND NOT is_product_use_event
ORDER BY ror_ci_low DESC
LIMIT 200;

CREATE OR REPLACE TEMP TABLE audit_top_quality AS
WITH suspects AS (
    SELECT primaryid, count(*) AS n_suspects FROM case_ingredient GROUP BY primaryid
),
case_prof AS (
    SELECT t.ingredient, t.pt, ci.primaryid, s.n_suspects,
           d.sex || '|' || coalesce(CAST(round(d.age_years) AS VARCHAR), 'NA') || '|'
                 || coalesce(CAST(d.event_date AS VARCHAR), 'NA') || '|'
                 || coalesce(d.reporter_country, 'NA')                         AS fingerprint,
           (d.age_years IS NOT NULL AND d.event_date IS NOT NULL)              AS fully_dated
    FROM audit_top_pairs t
    JOIN case_ingredient ci ON ci.ingredient = t.ingredient
    JOIN reac_clean r ON r.primaryid = ci.primaryid AND r.pt = t.pt
    JOIN suspects s ON s.primaryid = ci.primaryid
    JOIN demo_clean d ON d.primaryid = ci.primaryid
)
SELECT ingredient, pt,
       count(*)                                                                AS cases,
       round(100.0 * count(*) FILTER (WHERE n_suspects >= 10) / count(*), 0)   AS pct_cases_with_10plus_suspects,
       median(n_suspects)                                                      AS median_suspects_per_case,
       count(*) FILTER (WHERE fully_dated)                                     AS dated_cases,
       count(DISTINCT fingerprint) FILTER (WHERE fully_dated)                  AS distinct_fingerprints
FROM case_prof
GROUP BY ingredient, pt;

-- D1. Detail for the top 40: overlap shares, crowded suspect lists, profile homogeneity, PS-only replication.
SELECT t.ingredient, t.pt, t.a, t.n_drug, t.n_event,
       round(t.a * 1.0 / t.n_event, 2)  AS share_of_event_cases,
       round(t.a * 1.0 / t.n_drug, 2)   AS share_of_drug_cases,
       q.pct_cases_with_10plus_suspects, q.median_suspects_per_case,
       q.dated_cases, q.distinct_fingerprints,
       o.a AS a_ps_only, o.n_drug AS n_drug_ps_only, o.meets_evans AS evans_in_ps_only
FROM audit_top_pairs t
JOIN audit_top_quality q ON q.ingredient = t.ingredient AND q.pt = t.pt
LEFT JOIN signals o ON o.scope = 'PS_only' AND o.ingredient = t.ingredient AND o.pt = t.pt
ORDER BY t.ror_ci_low DESC
LIMIT 40;

-- D2. Summary over all 200.
SELECT count(*) AS top_pairs,
       count(*) FILTER (WHERE q.pct_cases_with_10plus_suspects >= 50)                     AS majority_crowded_cases,
       count(*) FILTER (WHERE q.dated_cases >= 10
                          AND q.distinct_fingerprints * 1.0 / q.dated_cases <= 0.5)       AS homogeneous_profiles,
       count(*) FILTER (WHERE t.a * 1.0 / t.n_event >= 0.8
                          AND t.a * 1.0 / t.n_drug  >= 0.8)                               AS mutually_concentrated,
       count(*) FILTER (WHERE o.meets_evans IS NOT TRUE)                                  AS not_flagged_in_ps_only
FROM audit_top_pairs t
JOIN audit_top_quality q ON q.ingredient = t.ingredient AND q.pt = t.pt
LEFT JOIN signals o ON o.scope = 'PS_only' AND o.ingredient = t.ingredient AND o.pt = t.pt;

-- D3. Positive controls: well-documented label effects. Where do they rank in the current queue?
--     (Confirm each pair against the product labels before citing it in the README.)
--     A pair that is absent here is NOT in the queue, which is informative too.
WITH ranked AS (
    SELECT ingredient, pt, a, n_drug, n_event, prr, ror_ci_low,
           rank() OVER (ORDER BY ror_ci_low DESC) AS rank_in_queue,
           count(*) OVER ()                       AS queue_size
    FROM signals
    WHERE scope = 'PS_SS' AND meets_evans AND ror_signal AND NOT is_product_use_event
)
SELECT r.ingredient, r.pt, r.a, r.n_drug, r.n_event,
       round(r.prr, 1) AS prr, round(r.ror_ci_low, 1) AS ror_ci_low, r.rank_in_queue, r.queue_size
FROM ranked r
JOIN (VALUES ('DUPILUMAB', 'Conjunctivitis'),
             ('TIRZEPATIDE', 'Nausea'),
             ('SEMAGLUTIDE', 'Pancreatitis'),
             ('INFLIXIMAB', 'Infusion related reaction'),
             ('METHOTREXATE', 'Pancytopenia')) AS p(ing, pt)
  ON r.ingredient = p.ing AND r.pt = p.pt
ORDER BY r.rank_in_queue;