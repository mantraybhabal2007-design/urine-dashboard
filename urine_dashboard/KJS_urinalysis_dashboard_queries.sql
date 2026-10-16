-- =====================================================================
--  KJS-HC-03  Urine Test Strip Reader  --  PostgreSQL dashboard queries
--  Dataset : Urine_Strip_Dataset_50000x15.xlsx (sheet Urinalysis_Dataset)
--  Run order: PART 1 (schema) -> load CSV -> PART 2 (views) -> PART 3 (panels)
--  pgAdmin: run PART 3 ONE QUERY AT A TIME (select the query text, press F5);
--  running the whole file shows only the last result.
--  Every panel query in PART 3 is stand-alone: point one chart/table
--  widget of your GUI (Metabase, Grafana, Superset, Power BI, Streamlit,
--  React + API ...) at each query.
--  NOTE: synthetic data, decision-support only; clinician review required.
-- =====================================================================


-- #####################################################################
-- PART 1 : SCHEMA + DATA LOAD
-- #####################################################################

DROP TABLE IF EXISTS urinalysis_results CASCADE;
DROP TABLE IF EXISTS reference_ranges   CASCADE;

CREATE TABLE urinalysis_results (
    record_id            VARCHAR(20)   PRIMARY KEY,          -- KJS-UR-000001
    patient_id           VARCHAR(10)   NOT NULL,             -- PT000001
    test_ts              TIMESTAMP     NOT NULL,             -- strip read time
    glucose_mg_dl        NUMERIC(6,1)  NOT NULL,
    protein_mg_dl        NUMERIC(6,1)  NOT NULL,
    ph                   NUMERIC(3,1)  NOT NULL,
    ketones_mg_dl        NUMERIC(6,1)  NOT NULL,
    blood_rbc_per_ul     NUMERIC(6,1)  NOT NULL,
    bilirubin_mg_dl      NUMERIC(5,2)  NOT NULL,
    urobilinogen_mg_dl   NUMERIC(5,2)  NOT NULL,
    nitrite_mg_dl        NUMERIC(5,3)  NOT NULL,
    leucocytes_per_ul    NUMERIC(6,1)  NOT NULL,
    specific_gravity     NUMERIC(5,3)  NOT NULL,
    clinical_flag        VARCHAR(10)   NOT NULL CHECK (clinical_flag IN ('Normal','Abnormal','Critical')),
    model_confidence_pct NUMERIC(4,1)  NOT NULL
);

CREATE INDEX idx_ur_patient_ts ON urinalysis_results (patient_id, test_ts);
CREATE INDEX idx_ur_ts         ON urinalysis_results (test_ts);
CREATE INDEX idx_ur_flag_ts    ON urinalysis_results (clinical_flag, test_ts);

-- LOAD THE DATA (do this BEFORE running Part 2 and Part 3):
--  * pgAdmin: right-click  urinalysis_results > Import/Export Data...
--      Import | Filename = urinalysis.csv | Format = csv | Header = ON | Delimiter = ,
--      (refresh the table first: Schemas > public > Tables > right-click > Refresh)
--  * psql:    \copy urinalysis_results FROM 'urinalysis.csv' WITH (FORMAT csv, HEADER true)
--  Check:     SELECT COUNT(*) FROM urinalysis_results;     -- must return 50000
--  CSV column order must match the table: Record_ID ... Model_Confidence_pct

-- Clinical reference intervals + critical cut-offs (from the Data_Dictionary sheet).
-- Kept in a table so thresholds can be changed without touching any query.
CREATE TABLE reference_ranges (
    analyte       VARCHAR(20) PRIMARY KEY,
    unit          VARCHAR(12) NOT NULL,
    normal_min    NUMERIC,              -- NULL = no lower limit
    normal_max    NUMERIC,              -- NULL = no upper limit
    max_inclusive BOOLEAN NOT NULL,     -- TRUE for "a - b" ranges, FALSE for "< x"
    critical_min  NUMERIC,              -- NULL = no critical rule
    valid_min     NUMERIC NOT NULL,     -- "Valid Range in Data"
    valid_max     NUMERIC NOT NULL,
    sort_order    INT NOT NULL
);

INSERT INTO reference_ranges VALUES
 ('Glucose',      'mg/dL', NULL,  15,    FALSE, 500, 0,     1000, 1),
 ('Protein',      'mg/dL', NULL,  15,    FALSE, 300, 0,     1000, 2),
 ('pH',           'pH',    5.0,   8.0,   TRUE,  NULL,5.0,   9.0,  3),
 ('Ketones',      'mg/dL', NULL,  5,     FALSE, 80,  0,     160,  4),
 ('Blood (RBC)',  'RBC/uL',NULL,  10,    FALSE, 150, 0,     250,  5),
 ('Bilirubin',    'mg/dL', NULL,  0.5,   FALSE, 3,   0,     6,    6),
 ('Urobilinogen', 'mg/dL', 0.2,   1.0,   TRUE,  NULL,0.1,   12,   7),
 ('Nitrite',      'mg/dL', NULL,  0.05,  FALSE, NULL,0,     0.5,  8),
 ('Leucocytes',   'WBC/uL',NULL,  15,    FALSE, NULL,0,     500,  9),
 ('Specific Gravity','-',  1.003, 1.025, TRUE,  NULL,1.000, 1.030,10);


-- #####################################################################
-- PART 2 : VIEWS (single source of truth for all dashboard panels)
-- #####################################################################

-- 2.1  Long ("unpivoted") format: one row per record x analyte
CREATE OR REPLACE VIEW v_analyte_long AS
SELECT r.record_id, r.patient_id, r.test_ts, r.clinical_flag, r.model_confidence_pct,
       a.analyte, a.value,
       rr.unit, rr.normal_min, rr.normal_max, rr.critical_min, rr.sort_order,
       CASE WHEN rr.normal_min IS NOT NULL AND a.value < rr.normal_min THEN 'LOW'
            WHEN rr.normal_max IS NOT NULL AND (a.value > rr.normal_max
                 OR (a.value = rr.normal_max AND NOT rr.max_inclusive)) THEN 'HIGH'
            ELSE 'NORMAL' END                                   AS direction,
       (rr.critical_min IS NOT NULL AND a.value >= rr.critical_min) AS is_critical
FROM urinalysis_results r
CROSS JOIN LATERAL (VALUES
    ('Glucose',          r.glucose_mg_dl),
    ('Protein',          r.protein_mg_dl),
    ('pH',               r.ph),
    ('Ketones',          r.ketones_mg_dl),
    ('Blood (RBC)',      r.blood_rbc_per_ul),
    ('Bilirubin',        r.bilirubin_mg_dl),
    ('Urobilinogen',     r.urobilinogen_mg_dl),
    ('Nitrite',          r.nitrite_mg_dl),
    ('Leucocytes',       r.leucocytes_per_ul),
    ('Specific Gravity', r.specific_gravity)
) AS a(analyte, value)
JOIN reference_ranges rr ON rr.analyte = a.analyte;

-- 2.2  One row per record, enriched with rule-derived flag + reasons
CREATE OR REPLACE VIEW v_results AS
SELECT r.*,
       DATE(r.test_ts)                         AS test_date,
       DATE_TRUNC('month', r.test_ts)::date    AS test_month,
       EXTRACT(HOUR FROM r.test_ts)::int       AS test_hour,
       EXTRACT(ISODOW FROM r.test_ts)::int     AS test_dow,           -- 1=Mon .. 7=Sun
       x.abnormal_count,
       x.critical_count,
       x.abnormal_reasons,
       x.critical_reasons,
       CASE WHEN x.critical_count > 0 THEN 'Critical'
            WHEN x.abnormal_count > 0 THEN 'Abnormal'
            ELSE 'Normal' END                  AS derived_flag,
       (r.model_confidence_pct < 90)           AS low_confidence
FROM urinalysis_results r
JOIN LATERAL (
    SELECT COUNT(*) FILTER (WHERE l.direction <> 'NORMAL')                      AS abnormal_count,
           COUNT(*) FILTER (WHERE l.is_critical)                                AS critical_count,
           STRING_AGG(l.analyte || ' ' || l.direction || ' (' || l.value || ' ' || l.unit || ')',
                      '; ' ORDER BY l.sort_order) FILTER (WHERE l.direction <> 'NORMAL') AS abnormal_reasons,
           STRING_AGG(l.analyte || ' ' || l.value || ' ' || l.unit,
                      '; ' ORDER BY l.sort_order) FILTER (WHERE l.is_critical)  AS critical_reasons
    FROM v_analyte_long l
    WHERE l.record_id = r.record_id
) x ON TRUE;
-- Tip: 50k rows is fast as a normal view. For bigger data use
--   CREATE MATERIALIZED VIEW ... ; REFRESH MATERIALIZED VIEW CONCURRENTLY ...;


-- #####################################################################
-- PART 3 : DASHBOARD PANELS
-- Dates are anchored to the latest test in the data (not CURRENT_DATE),
-- so the dashboard still shows content for a static/synthetic dataset.
-- For a live system replace (SELECT MAX(test_ts) ...) with NOW().
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. HEADLINE KPI TILES
-- ---------------------------------------------------------------------

-- A1. Overall KPI row (one row -> several stat tiles)
SELECT COUNT(*)                                                         AS total_tests,
       COUNT(DISTINCT patient_id)                                       AS unique_patients,
       ROUND(COUNT(*)::numeric / NULLIF(COUNT(DISTINCT patient_id), 0), 2)         AS avg_tests_per_patient,
       COUNT(*) FILTER (WHERE clinical_flag = 'Critical')               AS critical_tests,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag = 'Critical') / NULLIF(COUNT(*), 0), 2) AS critical_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag = 'Abnormal') / NULLIF(COUNT(*), 0), 2) AS abnormal_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag = 'Normal')   / NULLIF(COUNT(*), 0), 2) AS normal_pct,
       ROUND(AVG(model_confidence_pct), 2)                              AS avg_model_confidence_pct,
       COUNT(*) FILTER (WHERE model_confidence_pct < 90)                AS low_confidence_tests,
       MIN(test_ts) AS first_test, MAX(test_ts) AS last_test
FROM urinalysis_results;

-- A2. Last 30 days vs previous 30 days (tiles with up/down arrows)
WITH anchor AS (SELECT MAX(test_ts) AS t FROM urinalysis_results),
w AS (
  SELECT CASE WHEN r.test_ts >  a.t - INTERVAL '30 days' THEN 'last_30d'
              WHEN r.test_ts >  a.t - INTERVAL '60 days' THEN 'prev_30d' END AS period,
         r.*
  FROM urinalysis_results r, anchor a
  WHERE r.test_ts > a.t - INTERVAL '60 days'
)
SELECT period,
       COUNT(*)                                                        AS tests,
       COUNT(DISTINCT patient_id)                                      AS patients,
       COUNT(*) FILTER (WHERE clinical_flag = 'Critical')              AS critical,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag <> 'Normal') / COUNT(*), 2) AS non_normal_pct,
       ROUND(AVG(model_confidence_pct), 2)                             AS avg_confidence
FROM w
GROUP BY period
ORDER BY period DESC;


-- ---------------------------------------------------------------------
-- B. VOLUME & CLINICAL-FLAG PANELS
-- ---------------------------------------------------------------------

-- B1. Clinical flag distribution  (donut / pie)
SELECT clinical_flag,
       COUNT(*)                                          AS tests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM urinalysis_results
GROUP BY clinical_flag
ORDER BY CASE clinical_flag WHEN 'Normal' THEN 1 WHEN 'Abnormal' THEN 2 ELSE 3 END;

-- B2. Monthly tests by flag  (stacked bar / 100% stacked bar)
SELECT DATE_TRUNC('month', test_ts)::date AS month,
       COUNT(*) FILTER (WHERE clinical_flag = 'Normal')   AS normal,
       COUNT(*) FILTER (WHERE clinical_flag = 'Abnormal') AS abnormal,
       COUNT(*) FILTER (WHERE clinical_flag = 'Critical') AS critical,
       COUNT(*)                                           AS total,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag = 'Critical') / COUNT(*), 2) AS critical_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE clinical_flag <> 'Normal') / COUNT(*), 2)  AS non_normal_pct
FROM urinalysis_results
GROUP BY 1
ORDER BY 1;

-- B3. Daily test volume, last 90 days + 7-day moving average  (line)
WITH anchor AS (SELECT MAX(test_ts)::date AS d FROM urinalysis_results),
daily AS (
  SELECT g::date AS day, COUNT(r.record_id) AS tests,
         COUNT(r.record_id) FILTER (WHERE r.clinical_flag = 'Critical') AS critical
  FROM anchor a
  CROSS JOIN generate_series(a.d - 89, a.d, INTERVAL '1 day') g
  LEFT JOIN urinalysis_results r ON r.test_ts >= g AND r.test_ts < g + INTERVAL '1 day'
  GROUP BY g
)
SELECT day, tests, critical,
       ROUND(AVG(tests) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1) AS tests_7d_avg
FROM daily
ORDER BY day;

-- B4. Usage heat-map: weekday x hour  (heat-map)
SELECT TO_CHAR(test_ts, 'Dy')                AS weekday,
       EXTRACT(ISODOW FROM test_ts)::int     AS weekday_no,
       EXTRACT(HOUR FROM test_ts)::int       AS hour_of_day,
       COUNT(*)                              AS tests
FROM urinalysis_results
GROUP BY 1, 2, 3
ORDER BY 2, 3;

-- B5. Year-over-year by month (line, one series per year)
SELECT EXTRACT(MONTH FROM test_ts)::int AS month_no,
       TO_CHAR(test_ts, 'Mon')          AS month,
       EXTRACT(YEAR FROM test_ts)::int  AS year,
       COUNT(*)                         AS tests
FROM urinalysis_results
GROUP BY 1, 2, 3
ORDER BY 3, 1;


-- ---------------------------------------------------------------------
-- C. ANALYTE PANELS (10 pads)
-- ---------------------------------------------------------------------

-- C1. Out-of-range rate per analyte  (horizontal bar, sorted)
SELECT analyte,
       COUNT(*) FILTER (WHERE direction = 'HIGH')            AS high_count,
       COUNT(*) FILTER (WHERE direction = 'LOW')             AS low_count,
       COUNT(*) FILTER (WHERE direction <> 'NORMAL')         AS out_of_range,
       ROUND(100.0 * COUNT(*) FILTER (WHERE direction <> 'NORMAL') / COUNT(*), 2) AS out_of_range_pct,
       COUNT(*) FILTER (WHERE is_critical)                   AS critical_count
FROM v_analyte_long
GROUP BY analyte
ORDER BY out_of_range_pct DESC;

-- C2. Analyte summary table  (table with min / mean / median / p95 / max + reference interval)
SELECT l.analyte, l.unit,
       CASE WHEN l.normal_min IS NULL THEN '< ' || l.normal_max
            ELSE l.normal_min || ' - ' || l.normal_max END                      AS reference_interval,
       MIN(l.value)                                                              AS min_value,
       ROUND(AVG(l.value), 3)                                                    AS mean_value,
       PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY l.value)::numeric(12,3)      AS median_value,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY l.value)::numeric(12,3)      AS p95_value,
       MAX(l.value)                                                              AS max_value,
       ROUND(STDDEV_SAMP(l.value), 3)                                            AS std_dev
FROM v_analyte_long l
GROUP BY l.analyte, l.unit, l.normal_min, l.normal_max, l.sort_order
ORDER BY l.sort_order;

-- C3. Monthly average of every analyte  (multi-line chart / small multiples)
SELECT DATE_TRUNC('month', test_ts)::date AS month,
       ROUND(AVG(glucose_mg_dl), 1)       AS glucose,
       ROUND(AVG(protein_mg_dl), 1)       AS protein,
       ROUND(AVG(ph), 2)                  AS ph,
       ROUND(AVG(ketones_mg_dl), 2)       AS ketones,
       ROUND(AVG(blood_rbc_per_ul), 1)    AS blood_rbc,
       ROUND(AVG(bilirubin_mg_dl), 3)     AS bilirubin,
       ROUND(AVG(urobilinogen_mg_dl), 2)  AS urobilinogen,
       ROUND(AVG(nitrite_mg_dl), 4)       AS nitrite,
       ROUND(AVG(leucocytes_per_ul), 1)   AS leucocytes,
       ROUND(AVG(specific_gravity), 4)    AS specific_gravity
FROM urinalysis_results
GROUP BY 1
ORDER BY 1;

-- C4. Distribution (histogram) of ONE analyte chosen from a dropdown.
--     Replace 'Glucose' with the dropdown value; 20 equal-width bins between the 1st and 99th percentile.
WITH lim AS (
  SELECT PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY value) AS lo,
         PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY value) AS hi
  FROM v_analyte_long WHERE analyte = 'Glucose'
),
b AS (
  SELECT WIDTH_BUCKET(LEAST(GREATEST(l.value, m.lo), m.hi - 1e-9), m.lo, m.hi, 20) AS bucket, m.lo, m.hi
  FROM v_analyte_long l CROSS JOIN lim m
  WHERE l.analyte = 'Glucose'
)
SELECT bucket,
       ROUND((MIN(lo) + (bucket - 1) * (MIN(hi) - MIN(lo)) / 20)::numeric, 3) AS bin_from,
       ROUND((MIN(lo) +  bucket      * (MIN(hi) - MIN(lo)) / 20)::numeric, 3) AS bin_to,
       COUNT(*) AS tests
FROM b
GROUP BY bucket
ORDER BY bucket;

-- C5. Trend of ONE analyte: monthly median + % out-of-range  (dropdown driven line)
SELECT DATE_TRUNC('month', test_ts)::date                                   AS month,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY value)::numeric(12,3)    AS median_value,
       ROUND(AVG(value), 3)                                                 AS mean_value,
       ROUND(100.0 * COUNT(*) FILTER (WHERE direction <> 'NORMAL') / COUNT(*), 2) AS out_of_range_pct
FROM v_analyte_long
WHERE analyte = 'Glucose'                 -- <-- dropdown value
GROUP BY 1
ORDER BY 1;

-- C6. Reference-interval compliance by month for ALL analytes (heat-map: analyte x month)
SELECT DATE_TRUNC('month', test_ts)::date AS month, analyte,
       ROUND(100.0 * COUNT(*) FILTER (WHERE direction <> 'NORMAL') / COUNT(*), 2) AS out_of_range_pct
FROM v_analyte_long
GROUP BY 1, analyte, sort_order
ORDER BY sort_order, 1;

-- C7. Number of abnormal pads per test  (bar) -- how many of the 10 pads are off
SELECT abnormal_count AS abnormal_pads, COUNT(*) AS tests,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM v_results
GROUP BY abnormal_count
ORDER BY abnormal_count;


-- ---------------------------------------------------------------------
-- D. CRITICAL ALERTS  (Human-in-the-loop clinician review)
-- ---------------------------------------------------------------------

-- D1. Critical-results worklist: latest 50, with the reason  (table, "needs review")
SELECT record_id, patient_id, test_ts,
       critical_reasons,
       abnormal_count        AS abnormal_pads,
       model_confidence_pct,
       CASE WHEN low_confidence THEN 'RE-TEST / VERIFY' ELSE 'Review' END AS action
FROM v_results
WHERE clinical_flag = 'Critical'
ORDER BY test_ts DESC
LIMIT 50;

-- D2. Which analytes trigger Critical?  (bar)
SELECT analyte, COUNT(*) AS critical_tests
FROM v_analyte_long
WHERE is_critical
GROUP BY analyte
ORDER BY critical_tests DESC;

-- D3. Critical in last 24 h of data / 7 d / 30 d  (alert counters)
WITH anchor AS (SELECT MAX(test_ts) AS t FROM urinalysis_results)
SELECT COUNT(*) FILTER (WHERE r.test_ts > a.t - INTERVAL '1 day')   AS critical_24h,
       COUNT(*) FILTER (WHERE r.test_ts > a.t - INTERVAL '7 days')  AS critical_7d,
       COUNT(*) FILTER (WHERE r.test_ts > a.t - INTERVAL '30 days') AS critical_30d
FROM urinalysis_results r, anchor a
WHERE r.clinical_flag = 'Critical';

-- D4. Patients with repeated critical results  (table)
SELECT patient_id,
       COUNT(*)       AS critical_events,
       MIN(test_ts)   AS first_critical,
       MAX(test_ts)   AS last_critical
FROM urinalysis_results
WHERE clinical_flag = 'Critical'
GROUP BY patient_id
HAVING COUNT(*) >= 2
ORDER BY critical_events DESC, last_critical DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- E. PATIENT VIEW (time-series monitoring)
-- ---------------------------------------------------------------------

-- E1. Patient search / drop-down list with visit counts
SELECT patient_id, COUNT(*) AS visits, MAX(test_ts) AS last_visit,
       (ARRAY_AGG(clinical_flag ORDER BY test_ts DESC))[1] AS latest_flag
FROM urinalysis_results
GROUP BY patient_id
ORDER BY visits DESC, patient_id;

-- E2. One patient's full history  (table + line charts)   -- replace 'PT003560'
SELECT record_id, test_ts, clinical_flag,
       glucose_mg_dl, protein_mg_dl, ph, ketones_mg_dl, blood_rbc_per_ul,
       bilirubin_mg_dl, urobilinogen_mg_dl, nitrite_mg_dl, leucocytes_per_ul,
       specific_gravity, model_confidence_pct, abnormal_reasons
FROM v_results
WHERE patient_id = 'PT003560'
ORDER BY test_ts;

-- E3. One patient's change since previous visit  (delta arrows)   -- replace patient id
SELECT record_id, test_ts, clinical_flag,
       glucose_mg_dl,  glucose_mg_dl  - LAG(glucose_mg_dl)  OVER w AS glucose_delta,
       protein_mg_dl,  protein_mg_dl  - LAG(protein_mg_dl)  OVER w AS protein_delta,
       leucocytes_per_ul, leucocytes_per_ul - LAG(leucocytes_per_ul) OVER w AS leuco_delta,
       test_ts - LAG(test_ts) OVER w AS time_since_prev
FROM urinalysis_results
WHERE patient_id = 'PT003560'
WINDOW w AS (ORDER BY test_ts)
ORDER BY test_ts;

-- E4. Repeat-visit distribution  (bar: how many patients had 1, 2, 3 ... tests)
SELECT visits, COUNT(*) AS patients
FROM (SELECT patient_id, COUNT(*) AS visits FROM urinalysis_results GROUP BY patient_id) v
GROUP BY visits
ORDER BY visits;

-- E5. Patients whose latest result is WORSE than the previous one  (watch-list)
WITH ranked AS (
  SELECT patient_id, record_id, test_ts, clinical_flag,
         CASE clinical_flag WHEN 'Normal' THEN 0 WHEN 'Abnormal' THEN 1 ELSE 2 END AS sev,
         ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY test_ts DESC) AS rn
  FROM urinalysis_results
),
pair AS (
  SELECT cur.patient_id, cur.test_ts AS latest_ts, cur.clinical_flag AS latest_flag,
         prv.clinical_flag AS previous_flag, cur.sev - prv.sev AS worsening
  FROM ranked cur JOIN ranked prv ON prv.patient_id = cur.patient_id AND prv.rn = 2
  WHERE cur.rn = 1
)
SELECT * FROM pair
WHERE worsening > 0
ORDER BY worsening DESC, latest_ts DESC
LIMIT 100;

-- E6. High-risk patient ranking, last 180 days  (table)
--     score = 5 x critical + 1 x abnormal tests; only patients with >= 2 non-normal tests
WITH anchor AS (SELECT MAX(test_ts) AS t FROM urinalysis_results)
SELECT r.patient_id,
       COUNT(*)                                            AS tests_180d,
       COUNT(*) FILTER (WHERE r.clinical_flag = 'Critical') AS critical,
       COUNT(*) FILTER (WHERE r.clinical_flag = 'Abnormal') AS abnormal,
       5 * COUNT(*) FILTER (WHERE r.clinical_flag = 'Critical')
         + COUNT(*) FILTER (WHERE r.clinical_flag = 'Abnormal') AS risk_score,
       MAX(r.test_ts)                                      AS last_test
FROM urinalysis_results r, anchor a
WHERE r.test_ts > a.t - INTERVAL '180 days'
  AND r.clinical_flag <> 'Normal'
GROUP BY r.patient_id
HAVING COUNT(*) >= 2
ORDER BY risk_score DESC, last_test DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- F. AI TRUSTWORTHINESS / UNCERTAINTY  (use case sec. 13)
-- ---------------------------------------------------------------------

-- F1. Model-confidence distribution by flag  (stacked histogram, 2-pt bins)
SELECT (FLOOR(model_confidence_pct / 2) * 2)::int AS confidence_bin_from,
       COUNT(*) FILTER (WHERE clinical_flag = 'Normal')   AS normal,
       COUNT(*) FILTER (WHERE clinical_flag = 'Abnormal') AS abnormal,
       COUNT(*) FILTER (WHERE clinical_flag = 'Critical') AS critical,
       COUNT(*)                                           AS total
FROM urinalysis_results
GROUP BY 1
ORDER BY 1;

-- F2. Confidence summary per flag  (table / bar)
SELECT clinical_flag,
       ROUND(AVG(model_confidence_pct), 2) AS avg_conf,
       MIN(model_confidence_pct)           AS min_conf,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY model_confidence_pct)::numeric(5,1) AS median_conf,
       COUNT(*) FILTER (WHERE model_confidence_pct < 90) AS below_90,
       ROUND(100.0 * COUNT(*) FILTER (WHERE model_confidence_pct < 90) / COUNT(*), 2) AS below_90_pct
FROM urinalysis_results
GROUP BY clinical_flag
ORDER BY avg_conf DESC;

-- F3. Monthly average confidence + % low-confidence  (line; drift / LED-aging monitor)
SELECT DATE_TRUNC('month', test_ts)::date AS month,
       ROUND(AVG(model_confidence_pct), 2) AS avg_conf,
       ROUND(100.0 * COUNT(*) FILTER (WHERE model_confidence_pct < 90) / COUNT(*), 2) AS low_conf_pct
FROM urinalysis_results
GROUP BY 1
ORDER BY 1;

-- F4. Low-confidence results that need verification / re-test  (table)
--     Abnormal & Critical first, lowest confidence first
SELECT record_id, patient_id, test_ts, clinical_flag, model_confidence_pct, abnormal_reasons
FROM v_results
WHERE model_confidence_pct < 90 AND clinical_flag <> 'Normal'
ORDER BY CASE clinical_flag WHEN 'Critical' THEN 0 ELSE 1 END, model_confidence_pct, test_ts DESC
LIMIT 100;

-- F5. Flag-vs-rule consistency check  (confusion matrix: stored flag vs rule-derived flag)
--     Off-diagonal cells = potential false negatives / false positives to investigate.
SELECT clinical_flag AS stored_flag, derived_flag, COUNT(*) AS records
FROM v_results
GROUP BY 1, 2
ORDER BY 1, 2;


-- ---------------------------------------------------------------------
-- G. CLINICAL PATTERN SCREENING  (decision support, NOT diagnosis)
--    Simple rule-based patterns for the profiles in the dataset notes.
-- ---------------------------------------------------------------------

-- G1. Pattern prevalence  (bar)
SELECT pattern, COUNT(*) AS tests,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM urinalysis_results), 2) AS pct_of_all_tests,
       COUNT(DISTINCT patient_id) AS patients
FROM (
  SELECT patient_id, 'Possible diabetes (glucose high + ketones)' AS pattern
    FROM urinalysis_results WHERE glucose_mg_dl >= 15 AND ketones_mg_dl >= 5
  UNION ALL
  SELECT patient_id, 'Glucosuria only (glucose high)'
    FROM urinalysis_results WHERE glucose_mg_dl >= 15 AND ketones_mg_dl < 5
  UNION ALL
  SELECT patient_id, 'Possible UTI (nitrite + leucocytes)'
    FROM urinalysis_results WHERE nitrite_mg_dl >= 0.05 AND leucocytes_per_ul >= 15
  UNION ALL
  SELECT patient_id, 'Possible kidney disease (protein + blood)'
    FROM urinalysis_results WHERE protein_mg_dl >= 15 AND blood_rbc_per_ul >= 10
  UNION ALL
  SELECT patient_id, 'Possible liver disorder (bilirubin / urobilinogen)'
    FROM urinalysis_results WHERE bilirubin_mg_dl >= 0.5 OR urobilinogen_mg_dl > 1.0
  UNION ALL
  SELECT patient_id, 'Possible dehydration (high SG)'
    FROM urinalysis_results WHERE specific_gravity > 1.025
) p
GROUP BY pattern
ORDER BY tests DESC;

-- G2. Pattern trend by month  (multi-line)
SELECT DATE_TRUNC('month', test_ts)::date AS month,
       COUNT(*) FILTER (WHERE glucose_mg_dl >= 15 AND ketones_mg_dl >= 5)        AS diabetes_pattern,
       COUNT(*) FILTER (WHERE nitrite_mg_dl >= 0.05 AND leucocytes_per_ul >= 15) AS uti_pattern,
       COUNT(*) FILTER (WHERE protein_mg_dl >= 15 AND blood_rbc_per_ul >= 10)    AS kidney_pattern,
       COUNT(*) FILTER (WHERE bilirubin_mg_dl >= 0.5 OR urobilinogen_mg_dl > 1.0) AS liver_pattern,
       COUNT(*) FILTER (WHERE specific_gravity > 1.025)                           AS dehydration_pattern
FROM urinalysis_results
GROUP BY 1
ORDER BY 1;

-- G3. Analyte correlation matrix  (heat-map; shows the inter-pad dependency from use-case challenge 4)
SELECT x.analyte AS analyte_x, y.analyte AS analyte_y,
       ROUND(CORR(x.value::float8, y.value::float8)::numeric, 3) AS correlation
FROM v_analyte_long x
JOIN v_analyte_long y ON y.record_id = x.record_id
GROUP BY x.analyte, y.analyte, x.sort_order, y.sort_order
ORDER BY x.sort_order, y.sort_order;


-- ---------------------------------------------------------------------
-- H. DATA QUALITY / GOVERNANCE
-- ---------------------------------------------------------------------

-- H1. Values outside the dictionary's "valid range"  (should be 0 rows -> green tile)
SELECT l.analyte, COUNT(*) AS invalid_values
FROM v_analyte_long l
JOIN reference_ranges rr USING (analyte)
WHERE l.value < rr.valid_min OR l.value > rr.valid_max
GROUP BY l.analyte;

-- H2. Duplicate checks  (should be 0)
SELECT (SELECT COUNT(*) - COUNT(DISTINCT record_id) FROM urinalysis_results) AS duplicate_record_ids,
       (SELECT COUNT(*) FROM (SELECT 1 FROM urinalysis_results
                              GROUP BY patient_id, test_ts HAVING COUNT(*) > 1) d)  AS same_patient_same_time;

-- H3. Data freshness / completeness  (tile)
SELECT MAX(test_ts)                                  AS latest_record,
       NOW() - MAX(test_ts)                          AS age_of_latest_record,
       COUNT(*)                                      AS rows_loaded,
       COUNT(*) FILTER (WHERE model_confidence_pct IS NULL OR clinical_flag IS NULL) AS rows_missing_key_fields
FROM urinalysis_results;


-- ---------------------------------------------------------------------
-- I. FILTERABLE DETAIL TABLE  (bottom of dashboard; one prepared statement for all filters)
--    $1 = from date, $2 = to date, $3 = 'All' | Normal | Abnormal | Critical, $4 = patient id ('' = all)
-- ---------------------------------------------------------------------
PREPARE detail_q (date, date, text, text) AS
SELECT record_id, patient_id, test_ts, clinical_flag, model_confidence_pct,
       glucose_mg_dl, protein_mg_dl, ph, ketones_mg_dl, blood_rbc_per_ul,
       bilirubin_mg_dl, urobilinogen_mg_dl, nitrite_mg_dl, leucocytes_per_ul,
       specific_gravity, abnormal_reasons
FROM v_results
WHERE test_ts >= $1
  AND test_ts <  $2 + 1
  AND ($3 = 'All' OR clinical_flag = $3)
  AND ($4 = ''    OR patient_id    = $4)
ORDER BY test_ts DESC
LIMIT 500;
-- usage:  EXECUTE detail_q('2026-01-01', '2026-10-16', 'Critical', '');
