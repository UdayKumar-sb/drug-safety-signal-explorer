-- sql/07_check_duplicate_drug_rows.sql
-- Purpose: 472,181 drug rows share a (primaryid, drug_seq) with another row. Find out why
--          before we join THER / INDI tables on drug_seq (duplicates would multiply rows).
-- Read-only. Run: python src/run_sql.py sql/07_check_duplicate_drug_rows.sql

-- 1. Do the duplicate rows within a (primaryid, drug_seq) group actually differ, and in which columns?
WITH g AS (
    SELECT primaryid, drug_seq,
           count(*)                    AS n_rows,
           count(DISTINCT drugname)    AS d_name,
           count(DISTINCT prod_ai)     AS d_ai,
           count(DISTINCT role_cod)    AS d_role,
           count(DISTINCT route)       AS d_route,
           count(DISTINCT dose_vbm)    AS d_dose,
           count(DISTINCT lot_num)     AS d_lot
    FROM drug_dedup
    GROUP BY primaryid, drug_seq
    HAVING count(*) > 1
)
SELECT count(*)                                   AS duplicate_groups,
       sum(n_rows)                                AS rows_in_groups,
       count(*) FILTER (WHERE d_name  > 1)        AS groups_differing_name,
       count(*) FILTER (WHERE d_ai    > 1)        AS groups_differing_ingredient,
       count(*) FILTER (WHERE d_role  > 1)        AS groups_differing_role,
       count(*) FILTER (WHERE d_route > 1)        AS groups_differing_route,
       count(*) FILTER (WHERE d_dose  > 1)        AS groups_differing_dose,
       count(*) FILTER (WHERE d_lot   > 1)        AS groups_differing_lot,
       count(*) FILTER (WHERE d_name <= 1 AND d_ai <= 1 AND d_role <= 1
                          AND d_route <= 1 AND d_dose <= 1 AND d_lot <= 1) AS no_difference_in_these_columns
FROM g;

-- 2. Is it one quarter or both? (A single quarter would point at the load step, not the source data.)
SELECT quarter, sum(c - 1) AS duplicate_rows
FROM (
    SELECT quarter, count(*) AS c
    FROM drug_dedup
    GROUP BY quarter, primaryid, drug_seq
    HAVING count(*) > 1
)
GROUP BY quarter
ORDER BY quarter;

-- 3. Look at a few examples with your own eyes.
WITH dups AS (
    SELECT primaryid, drug_seq
    FROM drug_dedup
    GROUP BY primaryid, drug_seq
    HAVING count(*) > 1
    ORDER BY primaryid
    LIMIT 5
)
SELECT d.primaryid, d.drug_seq, d.role_cod, d.drugname, d.prod_ai, d.route, d.dose_vbm, d.lot_num
FROM drug_dedup d
JOIN dups USING (primaryid, drug_seq)
ORDER BY d.primaryid, d.drug_seq;