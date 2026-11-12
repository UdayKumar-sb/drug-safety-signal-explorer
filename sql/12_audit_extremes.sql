-- D1. Exact cells for the representative pairs
SELECT s.ingredient, s.pt, s.a, s.b, s.c, s.d, s.n_drug, s.n_event,
       round(s.prr, 1) AS prr, round(s.ror, 1) AS ror, round(s.chi2, 0) AS chi2
FROM signals s
JOIN (VALUES
    ('PENFLURIDOL', 'Paroxysmal perceptual alteration'),
    ('SULFAGUANIDINE', 'Amyloid arthropathy'),
    ('MESTRANOL', 'Ovarian endometrioid carcinoma'),
    ('ALOSETRON', 'Congenital epiblepharon'),
    ('SEVOFLURANE', 'Anaesthetic complication neurological'),
    ('MAGNESIUM OROTATE', 'Fractional exhaled nitric oxide increased'),
    ('TECHNETIUM TC-99M TETROFOSMIN', 'Radioisotope scan abnormal'),
    ('DIBUCAINE HYDROCHLORIDE', 'Heart sounds')
) AS p(ing, pt) ON s.ingredient = p.ing AND s.pt = p.pt
WHERE s.scope = 'PS_SS';

-- D2. Are the "Amyloid arthropathy" cases near-duplicates? Eyeball the profiles.
WITH hits AS (
    SELECT DISTINCT ci.primaryid
    FROM case_ingredient ci
    JOIN reac_clean r ON r.primaryid = ci.primaryid
    WHERE ci.ingredient = 'SULFAGUANIDINE' AND r.pt = 'Amyloid arthropathy'
)
SELECT d.primaryid, d.caseid, d.quarter, d.age_years, d.sex, d.event_date, d.fda_date,
       d.reporter_country, d.occp_cod,
       (SELECT count(*) FROM case_ingredient x WHERE x.primaryid = d.primaryid) AS n_ingredients,
       (SELECT count(*) FROM reac_clean y WHERE y.primaryid = d.primaryid)      AS n_pts
FROM demo_clean d
JOIN hits h ON h.primaryid = d.primaryid
ORDER BY d.fda_date, d.primaryid
LIMIT 50;

-- D3. Where do the Evans pairs come from, by case count?
SELECT CASE WHEN a < 5 THEN '3-4' WHEN a < 10 THEN '5-9' WHEN a < 30 THEN '10-29' ELSE '30+' END AS a_bucket,
       count(*) AS pairs,
       count(*) FILTER (WHERE meets_evans) AS evans_pairs,
       round(100.0 * count(*) FILTER (WHERE meets_evans) / count(*), 1) AS pct_evans,
       count(*) FILTER (WHERE meets_evans AND b <= 2 AND c <= 2) AS evans_near_exclusive
FROM signals
WHERE scope = 'PS_SS' AND NOT is_product_use_event
GROUP BY 1
ORDER BY min(a);

-- D4. How much of the current top 200 would move to a watchlist?
SELECT count(*) AS top_200,
       count(*) FILTER (WHERE n_drug <= 50 AND n_event <= 50 AND b <= 2 AND c <= 2) AS tiny_near_exclusive
FROM (
    SELECT * FROM signals
    WHERE scope = 'PS_SS' AND meets_evans AND ror_signal AND NOT is_product_use_event
    ORDER BY ror_ci_low DESC
    LIMIT 200
);