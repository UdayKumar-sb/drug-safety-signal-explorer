-- sql/11b_validate_signals.sql
-- Purpose: prove the signal tables are arithmetically sound, check the event flag, preview the review queue.
-- Read-only. Run: python src/run_sql.py sql/11b_validate_signals.sql

-- 1. Size of each scope and how many pairs pass each rule.
SELECT scope,
       count(*)                                          AS scored_pairs,
       count(DISTINCT ingredient)                        AS ingredients,
       count(DISTINCT pt)                                AS events,
       max(n_total)                                      AS cases_in_scope,
       count(*) FILTER (WHERE meets_evans)               AS evans_pairs,
       count(*) FILTER (WHERE ror_signal)                AS ror_pairs,
       count(*) FILTER (WHERE meets_evans AND ror_signal) AS both_rules,
       count(*) FILTER (WHERE meets_evans AND NOT is_product_use_event) AS evans_clinical_pairs
FROM signals
GROUP BY scope
ORDER BY scope;

-- 2. Integrity checks: every row should show passed = true.
SELECT 'every scored pair has a >= 3' AS check_name, count(*) = 0 AS passed
FROM signals WHERE a < 3
UNION ALL
SELECT 'cells b, c, d are non-negative', count(*) = 0
FROM signals WHERE b < 0 OR c < 0 OR d < 0
UNION ALL
SELECT 'a + b equals the drug total', count(*) = 0
FROM signals WHERE a + b <> n_drug
UNION ALL
SELECT 'a + c equals the event total', count(*) = 0
FROM signals WHERE a + c <> n_event
UNION ALL
SELECT 'a + b + c + d equals the scope total', count(*) = 0
FROM signals WHERE a + b + c + d <> n_total
UNION ALL
SELECT 'no NULL metrics', count(*) = 0
FROM signals WHERE prr IS NULL OR ror IS NULL OR chi2 IS NULL OR ror_ci_low IS NULL OR prr_ci_low IS NULL
UNION ALL
SELECT 'ROR lies inside its own confidence interval', count(*) = 0
FROM signals WHERE NOT (ror_ci_low <= ror AND ror <= ror_ci_high)
UNION ALL
SELECT 'one row per (scope, ingredient, pt)',
       (SELECT count(*) FROM signals)
         = (SELECT count(*) FROM (SELECT DISTINCT scope, ingredient, pt FROM signals))
UNION ALL
SELECT 'PS_SS scope covers every case with a suspect and a reaction',
       (SELECT max(n_total) FROM signals WHERE scope = 'PS_SS') = (SELECT count(*) FROM signal_cases WHERE scope = 'PS_SS');

-- 3. Hand-check: recompute one row yourself (PRR = (a/(a+b)) / (c/(c+d))).
SELECT ingredient, pt, a, b, c, d, round(prr, 2) AS prr, round(ror, 2) AS ror, round(chi2, 1) AS chi2
FROM signals
WHERE scope = 'PS_SS' AND ingredient = 'DUPILUMAB'
ORDER BY a DESC
LIMIT 5;

-- 4. What the product-use flag catches (top flagged terms) ...
SELECT f.pt, count(*) AS cases
FROM event_flags f
JOIN reac_clean r ON r.pt = f.pt
WHERE f.is_product_use_event
GROUP BY f.pt
ORDER BY cases DESC
LIMIT 40;

SELECT count(*) FILTER (WHERE is_product_use_event) AS flagged_terms, count(*) AS all_terms
FROM event_flags;

-- 5. ... and what it may have missed (unflagged terms that look like product-use or error terms).
SELECT f.pt, count(*) AS cases
FROM event_flags f
JOIN reac_clean r ON r.pt = f.pt
WHERE NOT f.is_product_use_event
  AND regexp_matches(lower(f.pt), 'product|dose|medication|off.label|ineffective|wrong|incorrect|misuse|expired|storage')
GROUP BY f.pt
ORDER BY cases DESC
LIMIT 25;

-- 6. First look at the review queue: Evans + ROR signal, clinical events only, ranked by the
--    LOWER bound of the ROR interval (conservative: small counts cannot inflate it).
SELECT ingredient, pt, a AS cases, n_drug,
       round(prr, 1) AS prr, round(ror, 1) AS ror, round(ror_ci_low, 1) AS ror_ci_low, round(chi2, 0) AS chi2
FROM signals
WHERE scope = 'PS_SS' AND meets_evans AND ror_signal AND NOT is_product_use_event
ORDER BY ror_ci_low DESC
LIMIT 25;

-- 7. Sensitivity: how many PS+SS Evans pairs survive when only the primary suspect is used?
SELECT count(*) FILTER (WHERE s.meets_evans)                      AS evans_pairs_ps_ss,
       count(*) FILTER (WHERE s.meets_evans AND o.meets_evans)    AS also_evans_in_ps_only
FROM signals s
LEFT JOIN signals o
       ON o.scope = 'PS_only' AND o.ingredient = s.ingredient AND o.pt = s.pt
WHERE s.scope = 'PS_SS';