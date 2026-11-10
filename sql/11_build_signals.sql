-- sql/11_build_signals.sql
-- Purpose: disproportionality signals (PRR, ROR) for every ingredient x reaction pair with >= 3 reports.
-- Inputs: case_ingredient, reac_clean. Idempotent (CREATE OR REPLACE).
-- Run: python src/run_sql.py sql/11_build_signals.sql
--
-- The 2x2 table for one drug-event pair (counts of CASES, never rows):
--                      event      no event
--     drug               a           b        a + b = n_drug
--     all other drugs    c           d        c + d = everything else in the scope
--     N = n_total = all cases in the scope
--
--   PRR = [a / (a+b)] / [c / (c+d)]   share of the drug's cases with the event vs the same share elsewhere
--   ROR = (a*d) / (b*c)               odds ratio, same table
--   Evans screening rule (common in pharmacovigilance): a >= 3 AND PRR >= 2 AND chi-square >= 4.
--   ROR signal: lower bound of the 95% CI above 1.
--
-- Two scopes, run side by side:
--   PS_SS   : primary + secondary suspect (main analysis)
--   PS_only : primary suspect only (sensitivity check)
--
-- Zero cells: if b, c or d is 0, 0.5 is added to every cell (Haldane-Anscombe) for PRR / ROR / CI.
-- The chi-square uses the raw counts. Pairs with fewer than 3 reports are not scored.
-- Signals are statistical flags for review, NOT proof of causation.

-- 1. Flag reaction terms that describe product USE (off label, ineffective, dosing errors),
--    not clinical reactions. Kept in the table, but excluded from the default review queue.
--    This is a v1 keyword rule; sql/11b lists what it flags and what it might have missed.
CREATE OR REPLACE TABLE event_flags AS
SELECT pt,
       regexp_matches(lower(pt),
           '^(off label use|drug ineffective|product |incorrect |wrong |inappropriate schedule|intentional product|drug dose omission|dose omission|underdose|extra dose|expired product|therapeutic product|therapeutic response)')
           AS is_product_use_event
FROM (SELECT DISTINCT pt FROM reac_clean);

-- 2. Exposure per scope: one row per (scope, case, ingredient), cases with at least one reaction only.
CREATE OR REPLACE TABLE signal_exposure AS
WITH exposure AS (
    SELECT 'PS_SS' AS scope, primaryid, ingredient FROM case_ingredient
    UNION ALL
    SELECT 'PS_only', primaryid, ingredient FROM case_ingredient WHERE is_primary_suspect
)
SELECT e.*
FROM exposure e
WHERE EXISTS (SELECT 1 FROM reac_clean r WHERE r.primaryid = e.primaryid);

-- 3. The case universe per scope (this defines N).
CREATE OR REPLACE TABLE signal_cases AS
SELECT DISTINCT scope, primaryid FROM signal_exposure;

-- 4. Counts: a (pair), n_drug, n_event, n_total. Pairs below 3 reports are dropped here.
CREATE OR REPLACE TABLE signal_counts AS
WITH tot AS (
    SELECT scope, count(*) AS n_total FROM signal_cases GROUP BY scope
),
drug_n AS (
    SELECT scope, ingredient, count(*) AS n_drug FROM signal_exposure GROUP BY scope, ingredient
),
event_n AS (
    SELECT c.scope, r.pt, count(*) AS n_event
    FROM signal_cases c
    JOIN reac_clean r ON r.primaryid = c.primaryid
    GROUP BY c.scope, r.pt
),
pairs AS (
    SELECT e.scope, e.ingredient, r.pt, count(*) AS a
    FROM signal_exposure e
    JOIN reac_clean r ON r.primaryid = e.primaryid
    GROUP BY e.scope, e.ingredient, r.pt
    HAVING count(*) >= 3
)
SELECT scope, ingredient, pt, a, n_drug, n_event, n_total
FROM pairs
JOIN drug_n  USING (scope, ingredient)
JOIN event_n USING (scope, pt)
JOIN tot     USING (scope);

-- 5. Metrics. Everything is cast to DOUBLE: a * d reaches ~1e11, and its square would overflow BIGINT.
CREATE OR REPLACE TABLE signals AS
WITH cells AS (
    SELECT scope, ingredient, pt, a, n_drug, n_event, n_total,
           n_drug - a                      AS b,
           n_event - a                     AS c,
           n_total - n_drug - n_event + a  AS d
    FROM signal_counts
),
adj AS (
    SELECT *, CASE WHEN b = 0 OR c = 0 OR d = 0 THEN 0.5 ELSE 0.0 END AS k FROM cells
),
stats AS (
    SELECT *,
           (a + k)::DOUBLE AS a2, (b + k)::DOUBLE AS b2, (c + k)::DOUBLE AS c2, (d + k)::DOUBLE AS d2
    FROM adj
),
metrics AS (
    SELECT scope, ingredient, pt, a, b, c, d, n_drug, n_event, n_total,
           (a2 / (a2 + b2)) / (c2 / (c2 + d2))                      AS prr,
           sqrt(1 / a2 - 1 / (a2 + b2) + 1 / c2 - 1 / (c2 + d2))    AS se_ln_prr,
           (a2 * d2) / (b2 * c2)                                    AS ror,
           sqrt(1 / a2 + 1 / b2 + 1 / c2 + 1 / d2)                  AS se_ln_ror,
           n_total::DOUBLE * power(a::DOUBLE * d - b::DOUBLE * c, 2)
             / ((a + b)::DOUBLE * (c + d) * (a + c) * (b + d))      AS chi2
    FROM stats
)
SELECT m.scope, m.ingredient, m.pt, f.is_product_use_event,
       m.a, m.b, m.c, m.d, m.n_drug, m.n_event, m.n_total,
       m.prr,
       exp(ln(m.prr) - 1.96 * m.se_ln_prr)  AS prr_ci_low,
       m.chi2,
       m.ror,
       exp(ln(m.ror) - 1.96 * m.se_ln_ror)  AS ror_ci_low,
       exp(ln(m.ror) + 1.96 * m.se_ln_ror)  AS ror_ci_high,
       (m.a >= 3 AND m.prr >= 2 AND m.chi2 >= 4)           AS meets_evans,
       (exp(ln(m.ror) - 1.96 * m.se_ln_ror) > 1)           AS ror_signal
FROM metrics m
JOIN event_flags f ON f.pt = m.pt;