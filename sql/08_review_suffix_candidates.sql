-- sql/08_review_suffix_candidates.sql (read-only)
SELECT upper(trim(prod_ai)) AS ingredient, count(DISTINCT primaryid) AS reports
FROM drug_dedup
WHERE role_cod IN ('PS', 'SS')
  AND regexp_matches(upper(trim(prod_ai)), '-[A-Z]{4}$')
GROUP BY 1
ORDER BY reports DESC;