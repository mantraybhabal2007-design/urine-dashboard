# Urine Test Strip Reader – Clinical Dashboard

An interactive dashboard built with **Streamlit** and **PostgreSQL** for the use case
**KJS-HC-03: Urine Test Strip Reader using Colorimetry as a Point-of-Care Technology**
(K. J. Somaiya Hospital & Research Center, Mumbai, with Paramcare Lifesciences Pvt. Ltd.).

The dashboard analyses 50,000 synthetic urinalysis records (10 analytes per strip) and supports
clinician review, patient time-series monitoring and AI-confidence tracking.

> **Disclaimer:** the dataset is synthetic. The dashboard is a decision-support demo and is not a
> medical device. All results need clinician review.

## Features

| Tab | What it shows |
|---|---|
| **Overview** | Flag distribution (Normal / Abnormal / Critical), monthly trend, daily volume with 7-day average, weekday × hour heat-map |
| **Analytes** | % out of reference range per analyte, summary statistics, histogram and monthly trend for any analyte, analyte × month heat-map, correlation matrix |
| **Critical alerts** | Last 24 h / 7 d / 30 d counters, review worklist, critical triggers, patients with repeated criticals |
| **Patients** | Search by patient ID, per-patient trends with the reference band shaded, watch-list of patients getting worse |
| **AI confidence** | Confidence distribution, drift over time, low-confidence abnormal/critical results to re-test, stored flag vs rule-derived flag |
| **Clinical patterns** | Rule-based screening patterns (diabetes, UTI, kidney, liver, dehydration) – not a diagnosis |
| **Data quality** | Duplicates, out-of-range values, reference intervals in use |

The sidebar has a date-range filter and a Normal / Abnormal / Critical selector that apply to the charts.

## Project files

| File | Purpose |
|---|---|
| `app.py` | The Streamlit dashboard |
| `KJS_urinalysis_dashboard_queries.sql` | Schema, reference ranges, two views and ready-to-use SQL panel queries |
| `urinalysis.csv` | The 50,000-row synthetic dataset |
| `load_data.py` | One-time script that loads the CSV into PostgreSQL |
| `requirements.txt` | Python dependencies |

## Requirements

- Python 3.10 or newer
- PostgreSQL 14 or newer (tested on 16) and pgAdmin (or `psql`)

## Setup

### 1. Clone and install

```bash
git clone https://github.com/YOURNAME/urine-dashboard.git
cd urine-dashboard
pip install -r requirements.txt
```

### 2. Create the tables (Part 1 of the SQL file)

Create a database (for example `urinalysis`) and open a Query Tool on it. Open
`KJS_urinalysis_dashboard_queries.sql` and run everything from the top down to the line
`-- PART 2`. This creates the `urinalysis_results` and `reference_ranges` tables.

### 3. Load the data

```bash
python load_data.py
```

Enter your host, port, database name, user and password when asked. It should print `Rows loaded: 50000`.
Check in SQL: `SELECT COUNT(*) FROM urinalysis_results;` → `50000`.

### 4. Create the views (Part 2 of the SQL file)

Run the section from `-- PART 2` down to just before `-- PART 3`. This creates `v_analyte_long` and `v_results`.

### 5. Run the dashboard

```bash
streamlit run app.py
```

Open http://localhost:8501, then enter your connection details in the sidebar
(host, port, database, user, password). The password is never stored in the code.

You can also pre-fill the connection with environment variables:
`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`.

## SQL queries

Part 3 of `KJS_urinalysis_dashboard_queries.sql` contains the panel queries (KPIs, trends, analyte
statistics, critical alerts, patient history, AI confidence, pattern screening, data quality).
In pgAdmin run them **one at a time** (select a query, press F5). They can also be used directly in
other BI tools such as Metabase, Grafana or Superset.

## Dataset

Columns: `Record_ID`, `Patient_ID`, `Timestamp`, ten predicted analytes (glucose, protein, pH, ketones,
blood/RBC, bilirubin, urobilinogen, nitrite, leucocytes, specific gravity), `Clinical_Flag`
(Normal / Abnormal / Critical) and `Model_Confidence_pct`. Records span Jan 2024 – Oct 2026 across
about 13,500 patients with repeat visits.

Reference intervals and critical cut-offs are stored in the `reference_ranges` table, so they can be
changed without editing any query.

## Known data observation

The query comparing the stored `Clinical_Flag` with the flag derived from the reference intervals shows
153 mismatches (for example, records with protein of 16–28 mg/dL stored as Normal). These are visible in the
**AI confidence** tab and are worth investigating, since missed abnormal results are the main risk named in the
use case's responsible-AI section.

## Troubleshooting

- **Cannot read the database:** check host, port, database name, user and password in the sidebar.
- **Table is empty:** run `python load_data.py` (step 3).
- **`relation "v_results" does not exist`:** run Part 2 of the SQL file (step 4).
- **`streamlit` not recognised:** use `python -m streamlit run app.py` (or `py -m streamlit run app.py` on Windows).

## Tech stack

Python · Streamlit · Plotly · pandas · psycopg2 · PostgreSQL

## License

Add a license of your choice (for example MIT) before sharing publicly.
