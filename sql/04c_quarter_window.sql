-- sql/04c_quarter_window.sql  (read-only)
-- How many reports fall outside each quarter's calendar window?
SELECT quarter, fda_month, count(*) AS n
FROM demo_clean
GROUP BY quarter, fda_month
ORDER BY quarter, fda_month;