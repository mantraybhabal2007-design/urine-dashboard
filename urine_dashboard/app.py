"""
KJS-HC-03  Urine Test Strip Reader - Clinical Dashboard (Streamlit + PostgreSQL)

Run:   streamlit run app.py
Needs: the tables/views created by KJS_urinalysis_dashboard_queries.sql (Part 1 + 2)
       and the CSV already loaded into urinalysis_results.
Synthetic data - decision support only, clinician review required.
"""
import os
from datetime import timedelta

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import psycopg2
import streamlit as st

st.set_page_config(page_title="Urinalysis Dashboard", page_icon="🧪", layout="wide")

FLAG_COLORS = {"Normal": "#2a9d8f", "Abnormal": "#e9a23b", "Critical": "#d1495b"}
FLAG_ORDER = ["Normal", "Abnormal", "Critical"]
PLOT = dict(template="plotly_white", margin=dict(l=10, r=10, t=40, b=10))

st.markdown(
    """
    <style>
      .block-container {padding-top: 1.4rem;}
      div[data-testid="stMetric"] {background: rgba(128,128,128,.08); border-radius: 10px; padding: 10px 14px;}
    </style>
    """,
    unsafe_allow_html=True,
)

# ---------------------------------------------------------------- connection
with st.sidebar:
    st.header("PostgreSQL connection")
    host = st.text_input("Host", os.getenv("PGHOST", "localhost"))
    port = st.text_input("Port", os.getenv("PGPORT", "5432"))
    dbname = st.text_input("Database", os.getenv("PGDATABASE", "postgres"))
    user = st.text_input("User", os.getenv("PGUSER", "postgres"))
    password = st.text_input("Password", os.getenv("PGPASSWORD", ""), type="password")

CONN = dict(host=host, port=port, dbname=dbname, user=user, password=password)


@st.cache_data(ttl=300, show_spinner=False)
def q(sql: str, params: dict | None = None, conn: tuple = ()) -> pd.DataFrame:
    """Run a query and return a DataFrame (conn is part of the cache key)."""
    c = psycopg2.connect(**dict(conn), connect_timeout=8)
    try:
        with c.cursor() as cur:
            cur.execute(sql, params or {})
            cols = [d[0] for d in cur.description]
            df = pd.DataFrame(cur.fetchall(), columns=cols)
    finally:
        c.close()
    for col in df.columns:  # Decimal -> float for plotting
        if df[col].dtype == object:
            try:
                df[col] = pd.to_numeric(df[col])
            except (ValueError, TypeError):
                pass
    return df


CK = tuple(sorted(CONN.items()))


def Q(sql, **params):
    return q(sql, params, CK)


try:
    rng = Q("SELECT MIN(test_ts)::date AS d1, MAX(test_ts)::date AS d2, COUNT(*) AS n FROM urinalysis_results")
except Exception as e:  # noqa: BLE001
    st.title("🧪 Urinalysis Dashboard")
    st.error(f"Cannot read the database: {e}")
    st.info("Enter your PostgreSQL details in the sidebar. Make sure Part 1 + Part 2 of the SQL file ran "
            "and the CSV was imported into `urinalysis_results`.")
    st.stop()

if int(rng.n[0]) == 0:
    st.title("🧪 Urinalysis Dashboard")
    st.warning("Table `urinalysis_results` is empty. Import urinalysis.csv first (pgAdmin: right-click table > Import/Export Data).")
    st.stop()

# ------------------------------------------------------------------- filters
with st.sidebar:
    st.header("Filters")
    d_from, d_to = st.date_input("Date range", (rng.d1[0], rng.d2[0]), min_value=rng.d1[0], max_value=rng.d2[0])
    flags = st.multiselect("Clinical flag", FLAG_ORDER, default=FLAG_ORDER)
    st.caption("Reference intervals and critical cut-offs come from the `reference_ranges` table.")
    if st.button("Refresh data"):
        st.cache_data.clear()
        st.rerun()

if not flags:
    st.warning("Select at least one clinical flag.")
    st.stop()

P = dict(d1=d_from, d2=d_to + timedelta(days=1), flags=flags)
W = "test_ts >= %(d1)s AND test_ts < %(d2)s AND clinical_flag = ANY(%(flags)s)"

st.title("🧪 Urine Test Strip Reader - Clinical Dashboard")
st.caption("KJS-HC-03 · K. J. Somaiya Hospital & Paramcare Lifesciences · synthetic data · decision support only - "
           "every result needs clinician review")

# ----------------------------------------------------------------------- KPIs
k = Q(f"""
SELECT COUNT(*) AS tests, COUNT(DISTINCT patient_id) AS patients,
       COUNT(*) FILTER (WHERE clinical_flag='Critical') AS critical,
       COUNT(*) FILTER (WHERE clinical_flag='Abnormal') AS abnormal,
       ROUND(AVG(model_confidence_pct),2) AS conf,
       COUNT(*) FILTER (WHERE model_confidence_pct < 90) AS low_conf
FROM urinalysis_results WHERE {W}""", **P).iloc[0]

if k.tests == 0:
    st.warning("No tests match the current filters.")
    st.stop()

c = st.columns(6)
c[0].metric("Tests", f"{int(k.tests):,}")
c[1].metric("Patients", f"{int(k.patients):,}")
c[2].metric("Critical", f"{int(k.critical):,}", f"{100*k.critical/k.tests:.1f}% of tests", delta_color="off", delta_arrow="off")
c[3].metric("Abnormal", f"{int(k.abnormal):,}", f"{100*k.abnormal/k.tests:.1f}% of tests", delta_color="off", delta_arrow="off")
c[4].metric("Avg model confidence", f"{k.conf:.1f}%")
c[5].metric("Low confidence (<90%)", f"{int(k.low_conf):,}", f"{100*k.low_conf/k.tests:.1f}%", delta_color="off", delta_arrow="off")

tabs = st.tabs(["Overview", "Analytes", "Critical alerts", "Patients", "AI confidence", "Clinical patterns", "Data quality"])

# ------------------------------------------------------------------- Overview
with tabs[0]:
    a, b = st.columns([1, 2])
    d = Q(f"SELECT clinical_flag, COUNT(*) AS tests FROM urinalysis_results WHERE {W} GROUP BY 1", **P)
    fig = px.pie(d, names="clinical_flag", values="tests", hole=.55, color="clinical_flag",
                 color_discrete_map=FLAG_COLORS, category_orders={"clinical_flag": FLAG_ORDER},
                 title="Clinical flag distribution")
    fig.update_layout(**PLOT)
    a.plotly_chart(fig, width="stretch")

    d = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month, clinical_flag, COUNT(*) AS tests
              FROM urinalysis_results WHERE {W} GROUP BY 1,2 ORDER BY 1""", **P)
    fig = px.bar(d, x="month", y="tests", color="clinical_flag", color_discrete_map=FLAG_COLORS,
                 category_orders={"clinical_flag": FLAG_ORDER}, title="Tests per month by flag")
    fig.update_layout(**PLOT, legend_title_text="")
    b.plotly_chart(fig, width="stretch")

    a, b = st.columns([2, 1])
    d = Q(f"""SELECT test_date AS day, COUNT(*) AS tests,
                     COUNT(*) FILTER (WHERE clinical_flag='Critical') AS critical
              FROM v_results WHERE {W} GROUP BY 1 ORDER BY 1""", **P)
    d["7-day average"] = d.tests.rolling(7, min_periods=1).mean()
    fig = go.Figure()
    fig.add_bar(x=d.day, y=d.tests, name="Tests/day", marker_color="#9db4c0")
    fig.add_scatter(x=d.day, y=d["7-day average"], name="7-day avg", line=dict(color="#264653", width=2))
    fig.add_scatter(x=d.day, y=d.critical, name="Critical", line=dict(color=FLAG_COLORS["Critical"], width=1.5))
    fig.update_layout(**PLOT, title="Daily test volume", legend=dict(orientation="h", y=-0.22))
    a.plotly_chart(fig, width="stretch")

    d = Q(f"""SELECT test_dow, test_hour, COUNT(*) AS tests FROM v_results WHERE {W} GROUP BY 1,2""", **P)
    m = d.pivot(index="test_dow", columns="test_hour", values="tests").reindex(range(1, 8)).fillna(0)
    m.index = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    fig = px.imshow(m, aspect="auto", color_continuous_scale="Blues", title="Usage: weekday x hour",
                    labels=dict(x="Hour", y="", color="Tests"))
    fig.update_layout(**PLOT)
    b.plotly_chart(fig, width="stretch")

# -------------------------------------------------------------------- Analytes
with tabs[1]:
    d = Q(f"""SELECT analyte,
                     COUNT(*) FILTER (WHERE direction='HIGH') AS high,
                     COUNT(*) FILTER (WHERE direction='LOW')  AS low,
                     ROUND(100.0*COUNT(*) FILTER (WHERE direction<>'NORMAL')/COUNT(*),2) AS out_pct
              FROM v_analyte_long WHERE {W} GROUP BY analyte ORDER BY out_pct""", **P)
    a, b = st.columns(2)
    fig = px.bar(d, y="analyte", x="out_pct", orientation="h", text="out_pct",
                 title="% of tests outside reference interval", color_discrete_sequence=["#e9a23b"])
    fig.update_layout(**PLOT, xaxis_title="% out of range", yaxis_title="")
    a.plotly_chart(fig, width="stretch")

    s = Q(f"""SELECT l.analyte, l.unit,
                     CASE WHEN l.normal_min IS NULL THEN '< '||l.normal_max ELSE l.normal_min||' - '||l.normal_max END AS reference,
                     MIN(l.value) AS min, ROUND(AVG(l.value),3) AS mean,
                     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.value)::numeric(12,3) AS median,
                     PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY l.value)::numeric(12,3) AS p95,
                     MAX(l.value) AS max, l.sort_order
              FROM v_analyte_long l WHERE {W} GROUP BY l.analyte,l.unit,l.normal_min,l.normal_max,l.sort_order
              ORDER BY l.sort_order""", **P).drop(columns="sort_order")
    b.markdown("**Analyte summary**")
    b.dataframe(s, hide_index=True, width="stretch", height=390)

    analytes = Q("SELECT analyte FROM reference_ranges ORDER BY sort_order").analyte.tolist()
    sel = st.selectbox("Analyte detail", analytes)
    ref = Q("SELECT normal_min, normal_max, unit FROM reference_ranges WHERE analyte=%(a)s", a=sel).iloc[0]
    a, b = st.columns(2)
    h = Q(f"""WITH lim AS (SELECT PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY value) AS lo,
                                 PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY value) AS hi
                          FROM v_analyte_long WHERE analyte=%(a)s AND {W})
              SELECT WIDTH_BUCKET(LEAST(GREATEST(l.value,m.lo),m.hi-1e-9), m.lo, m.hi, 30) AS bucket,
                     MIN(m.lo) + (WIDTH_BUCKET(LEAST(GREATEST(l.value,m.lo),m.hi-1e-9), m.lo, m.hi, 30)-0.5)
                       * (MIN(m.hi)-MIN(m.lo))/30 AS center, COUNT(*) AS tests
              FROM v_analyte_long l CROSS JOIN lim m WHERE l.analyte=%(a)s AND {W}
              GROUP BY 1 ORDER BY 1""", a=sel, **P)
    fig = px.bar(h, x="center", y="tests", title=f"{sel} distribution ({ref.unit})", color_discrete_sequence=["#457b9d"])
    for v in (ref.normal_min, ref.normal_max):
        if pd.notna(v):
            fig.add_vline(x=float(v), line_dash="dash", line_color=FLAG_COLORS["Normal"])
    fig.update_layout(**PLOT, xaxis_title=ref.unit)
    a.plotly_chart(fig, width="stretch")

    t = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month,
                     PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY value)::float AS median,
                     ROUND(100.0*COUNT(*) FILTER (WHERE direction<>'NORMAL')/COUNT(*),2)::float AS out_pct
              FROM v_analyte_long WHERE analyte=%(a)s AND {W} GROUP BY 1 ORDER BY 1""", a=sel, **P)
    fig = go.Figure()
    fig.add_scatter(x=t.month, y=t["median"], name="Monthly median", line=dict(color="#264653"))
    fig.add_bar(x=t.month, y=t.out_pct, name="% out of range", yaxis="y2", marker_color="rgba(233,162,59,.45)")
    fig.update_layout(**PLOT, title=f"{sel}: monthly median and % out of range",
                      yaxis2=dict(overlaying="y", side="right", showgrid=False), legend=dict(orientation="h", y=-0.22))
    b.plotly_chart(fig, width="stretch")

    a, b = st.columns(2)
    hm = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month, analyte, sort_order,
                      ROUND(100.0*COUNT(*) FILTER (WHERE direction<>'NORMAL')/COUNT(*),1) AS out_pct
               FROM v_analyte_long WHERE {W} GROUP BY 1,2,3""", **P)
    m = hm.pivot(index="analyte", columns="month", values="out_pct")
    m = m.loc[[x for x in analytes if x in m.index]]
    m.columns = [c.strftime("%b %y") for c in m.columns]
    fig = px.imshow(m, aspect="auto", color_continuous_scale="YlOrRd", title="% out of range: analyte x month",
                    labels=dict(color="%"))
    fig.update_layout(**PLOT)
    a.plotly_chart(fig, width="stretch")

    cr = Q(f"""SELECT x.analyte AS ax, y.analyte AS ay, CORR(x.value::float8, y.value::float8) AS r
               FROM v_analyte_long x JOIN v_analyte_long y ON y.record_id = x.record_id
               WHERE x.test_ts >= %(d1)s AND x.test_ts < %(d2)s AND x.clinical_flag = ANY(%(flags)s)
               GROUP BY 1,2""", **P)
    m = cr.pivot(index="ax", columns="ay", values="r").reindex(index=analytes, columns=analytes)
    fig = px.imshow(m.round(2), text_auto=True, aspect="auto", zmin=-1, zmax=1,
                    color_continuous_scale="RdBu_r", title="Correlation between pads (inter-analyte dependency)")
    fig.update_layout(**PLOT)
    b.plotly_chart(fig, width="stretch")

# -------------------------------------------------------------- Critical alerts
with tabs[2]:
    crit = Q(f"""SELECT COUNT(*) FILTER (WHERE test_ts > mx.t - INTERVAL '1 day')   AS h24,
                        COUNT(*) FILTER (WHERE test_ts > mx.t - INTERVAL '7 days')  AS d7,
                        COUNT(*) FILTER (WHERE test_ts > mx.t - INTERVAL '30 days') AS d30
                 FROM urinalysis_results, (SELECT MAX(test_ts) AS t FROM urinalysis_results) mx
                 WHERE clinical_flag='Critical'""").iloc[0]
    c = st.columns(3)
    c[0].metric("Critical - last 24 h of data", int(crit.h24))
    c[1].metric("Critical - last 7 days", int(crit.d7))
    c[2].metric("Critical - last 30 days", int(crit.d30))

    a, b = st.columns([1, 2])
    d = Q(f"SELECT analyte, COUNT(*) AS tests FROM v_analyte_long WHERE is_critical AND {W} GROUP BY 1 ORDER BY 2", **P)
    fig = px.bar(d, y="analyte", x="tests", orientation="h", title="What triggers Critical?",
                 color_discrete_sequence=[FLAG_COLORS["Critical"]])
    fig.update_layout(**PLOT, yaxis_title="")
    a.plotly_chart(fig, width="stretch")

    d = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month,
                     ROUND(100.0*COUNT(*) FILTER (WHERE clinical_flag='Critical')/COUNT(*),2)::float AS critical_pct
              FROM urinalysis_results WHERE test_ts >= %(d1)s AND test_ts < %(d2)s GROUP BY 1 ORDER BY 1""", **P)
    fig = px.line(d, x="month", y="critical_pct", markers=True, title="Critical rate by month (%)",
                  color_discrete_sequence=[FLAG_COLORS["Critical"]])
    fig.update_layout(**PLOT)
    b.plotly_chart(fig, width="stretch")

    st.subheader("Review worklist - latest critical results")
    d = Q(f"""SELECT record_id, patient_id, test_ts, critical_reasons AS critical_values, abnormal_count AS abnormal_pads,
                     model_confidence_pct AS confidence,
                     CASE WHEN low_confidence THEN 'RE-TEST / VERIFY' ELSE 'Review' END AS action
              FROM v_results WHERE clinical_flag='Critical' AND {W} ORDER BY test_ts DESC LIMIT 100""", **P)
    st.dataframe(d, hide_index=True, width="stretch", height=360)

    st.subheader("Patients with repeated critical results")
    d = Q(f"""SELECT patient_id, COUNT(*) AS critical_events, MIN(test_ts) AS first_critical, MAX(test_ts) AS last_critical
              FROM urinalysis_results WHERE clinical_flag='Critical' AND {W}
              GROUP BY 1 HAVING COUNT(*)>=2 ORDER BY 2 DESC, 4 DESC LIMIT 50""", **P)
    st.dataframe(d, hide_index=True, width="stretch")

# -------------------------------------------------------------------- Patients
with tabs[3]:
    a, b = st.columns([1, 2])
    pl = Q("""SELECT patient_id, COUNT(*) AS visits FROM urinalysis_results GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 2000""")
    typed = a.text_input("Patient ID (e.g. PT003560)", "")
    pid = typed.strip().upper() or a.selectbox("...or pick (most visits first)", pl.patient_id.tolist())
    hist = Q("SELECT * FROM v_results WHERE patient_id=%(p)s ORDER BY test_ts", p=pid)
    if hist.empty:
        st.warning(f"No tests found for {pid}.")
    else:
        a.metric("Visits", len(hist))
        a.metric("Latest flag", hist.clinical_flag.iloc[-1])
        a.metric("Critical events", int((hist.clinical_flag == "Critical").sum()))
        an = {"Glucose": "glucose_mg_dl", "Protein": "protein_mg_dl", "pH": "ph", "Ketones": "ketones_mg_dl",
              "Blood (RBC)": "blood_rbc_per_ul", "Bilirubin": "bilirubin_mg_dl", "Urobilinogen": "urobilinogen_mg_dl",
              "Nitrite": "nitrite_mg_dl", "Leucocytes": "leucocytes_per_ul", "Specific Gravity": "specific_gravity"}
        pick = b.multiselect("Analytes to plot", list(an), default=["Glucose", "Protein", "Leucocytes"])
        for name in pick:
            r = Q("SELECT normal_min, normal_max FROM reference_ranges WHERE analyte=%(a)s", a=name).iloc[0]
            fig = go.Figure()
            fig.add_scatter(x=hist.test_ts, y=hist[an[name]].astype(float), mode="lines+markers",
                            line=dict(color="#264653"),
                            marker=dict(size=9, color=[FLAG_COLORS[f] for f in hist.clinical_flag]), name=name)
            lo = float(r.normal_min) if pd.notna(r.normal_min) else None
            hi = float(r.normal_max) if pd.notna(r.normal_max) else None
            if hi is not None:
                fig.add_hrect(y0=lo if lo is not None else 0, y1=hi, fillcolor=FLAG_COLORS["Normal"], opacity=.12, line_width=0)
            fig.update_layout(**PLOT, title=f"{name} (green band = reference interval; dot colour = visit flag)", height=240)
            b.plotly_chart(fig, width="stretch")
        st.subheader(f"All tests for {pid}")
        st.dataframe(hist[["record_id", "test_ts", "clinical_flag", *an.values(), "model_confidence_pct", "abnormal_reasons"]],
                     hide_index=True, width="stretch")

    st.subheader("Watch-list: latest result worse than previous")
    d = Q("""WITH ranked AS (
               SELECT patient_id, test_ts, clinical_flag,
                      CASE clinical_flag WHEN 'Normal' THEN 0 WHEN 'Abnormal' THEN 1 ELSE 2 END AS sev,
                      ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY test_ts DESC) AS rn
               FROM urinalysis_results)
             SELECT c.patient_id, c.test_ts AS latest_test, p.clinical_flag AS previous_flag, c.clinical_flag AS latest_flag
             FROM ranked c JOIN ranked p ON p.patient_id=c.patient_id AND p.rn=2
             WHERE c.rn=1 AND c.sev > p.sev ORDER BY c.sev - p.sev DESC, c.test_ts DESC LIMIT 100""")
    st.dataframe(d, hide_index=True, width="stretch", height=300)

# ---------------------------------------------------------------- AI confidence
with tabs[4]:
    a, b = st.columns(2)
    d = Q(f"""SELECT (FLOOR(model_confidence_pct/2)*2)::int AS conf_bin, clinical_flag, COUNT(*) AS tests
              FROM urinalysis_results WHERE {W} GROUP BY 1,2 ORDER BY 1""", **P)
    fig = px.bar(d, x="conf_bin", y="tests", color="clinical_flag", color_discrete_map=FLAG_COLORS,
                 category_orders={"clinical_flag": FLAG_ORDER}, title="Model confidence distribution")
    fig.update_layout(**PLOT, xaxis_title="Confidence % (2-pt bins)", legend_title_text="")
    a.plotly_chart(fig, width="stretch")

    d = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month, ROUND(AVG(model_confidence_pct),2)::float AS avg_conf,
                     ROUND(100.0*COUNT(*) FILTER (WHERE model_confidence_pct<90)/COUNT(*),2)::float AS low_pct
              FROM urinalysis_results WHERE {W} GROUP BY 1 ORDER BY 1""", **P)
    fig = go.Figure()
    fig.add_scatter(x=d.month, y=d.avg_conf, name="Avg confidence %", line=dict(color="#264653"))
    fig.add_bar(x=d.month, y=d.low_pct, name="% below 90", yaxis="y2", marker_color="rgba(209,73,91,.4)")
    fig.update_layout(**PLOT, title="Confidence drift (LED ageing / calibration monitor)",
                      yaxis2=dict(overlaying="y", side="right", showgrid=False), legend=dict(orientation="h", y=-0.22))
    b.plotly_chart(fig, width="stretch")

    st.subheader("Low-confidence abnormal / critical results - verify or re-test")
    d = Q(f"""SELECT record_id, patient_id, test_ts, clinical_flag, model_confidence_pct, abnormal_reasons
              FROM v_results WHERE model_confidence_pct<90 AND clinical_flag<>'Normal' AND {W}
              ORDER BY CASE clinical_flag WHEN 'Critical' THEN 0 ELSE 1 END, model_confidence_pct LIMIT 100""", **P)
    st.dataframe(d, hide_index=True, width="stretch", height=300)

    st.subheader("Stored flag vs rule-derived flag (possible false negatives)")
    d = Q("SELECT clinical_flag AS stored_flag, derived_flag, COUNT(*) AS records FROM v_results GROUP BY 1,2 ORDER BY 1,2")
    m = d.pivot(index="stored_flag", columns="derived_flag", values="records").reindex(index=FLAG_ORDER, columns=FLAG_ORDER).fillna(0)
    a, b = st.columns([1, 1])
    fig = px.imshow(m, text_auto=True, color_continuous_scale="Blues", title="Rows = stored flag, columns = rule-derived flag",
                    labels=dict(x="Derived from reference rules", y="Stored in dataset"))
    fig.update_layout(**PLOT)
    a.plotly_chart(fig, width="stretch")
    b.markdown("Off-diagonal cells are records where the stored `Clinical_Flag` disagrees with the reference intervals "
               "in the data dictionary. The cell **Normal → Abnormal** is the dangerous one (a missed abnormal result).")
    mis = Q("""SELECT record_id, patient_id, test_ts, clinical_flag AS stored, derived_flag, abnormal_reasons
               FROM v_results WHERE clinical_flag <> derived_flag ORDER BY test_ts DESC LIMIT 200""")
    b.dataframe(mis, hide_index=True, width="stretch", height=240)

# --------------------------------------------------------------------- Patterns
with tabs[5]:
    st.caption("Simple rule-based screening patterns - decision support, not a diagnosis.")
    PAT = {
        "Possible diabetes (glucose + ketones)": "glucose_mg_dl >= 15 AND ketones_mg_dl >= 5",
        "Glucosuria only": "glucose_mg_dl >= 15 AND ketones_mg_dl < 5",
        "Possible UTI (nitrite + leucocytes)": "nitrite_mg_dl >= 0.05 AND leucocytes_per_ul >= 15",
        "Possible kidney disease (protein + blood)": "protein_mg_dl >= 15 AND blood_rbc_per_ul >= 10",
        "Possible liver disorder (bilirubin / urobilinogen)": "bilirubin_mg_dl >= 0.5 OR urobilinogen_mg_dl > 1.0",
        "Possible dehydration (high SG)": "specific_gravity > 1.025",
    }
    sel_cols = ",\n".join(f"COUNT(*) FILTER (WHERE {c}) AS \"{n}\"" for n, c in PAT.items())
    mon = Q(f"""SELECT DATE_TRUNC('month', test_ts)::date AS month, COUNT(*) AS total, {sel_cols}
                FROM urinalysis_results WHERE {W} GROUP BY 1 ORDER BY 1""", **P)
    tot = mon[list(PAT)].sum().sort_values().reset_index()
    tot.columns = ["pattern", "tests"]
    a, b = st.columns([1, 2])
    fig = px.bar(tot, y="pattern", x="tests", orientation="h", title="Pattern prevalence (tests)",
                 color_discrete_sequence=["#457b9d"])
    fig.update_layout(**PLOT, yaxis_title="")
    a.plotly_chart(fig, width="stretch")
    long = mon.melt(id_vars="month", value_vars=list(PAT), var_name="pattern", value_name="tests")
    fig = px.line(long, x="month", y="tests", color="pattern", title="Monthly trend")
    fig.update_layout(**PLOT, legend=dict(orientation="h", y=-0.3, title_text=""))
    b.plotly_chart(fig, width="stretch")

# ----------------------------------------------------------------- Data quality
with tabs[6]:
    inv = Q("""SELECT l.analyte, COUNT(*) AS invalid_values FROM v_analyte_long l
               JOIN reference_ranges r USING (analyte) WHERE l.value < r.valid_min OR l.value > r.valid_max GROUP BY 1""")
    dup = Q("""SELECT (SELECT COUNT(*)-COUNT(DISTINCT record_id) FROM urinalysis_results) AS dup_ids,
                      (SELECT COUNT(*) FROM (SELECT 1 FROM urinalysis_results GROUP BY patient_id,test_ts HAVING COUNT(*)>1) d) AS dup_pt_time,
                      MAX(test_ts) AS latest, COUNT(*) AS rows FROM urinalysis_results""").iloc[0]
    c = st.columns(4)
    c[0].metric("Rows loaded", f"{int(dup.rows):,}")
    c[1].metric("Duplicate record IDs", int(dup.dup_ids))
    c[2].metric("Same patient + same time", int(dup.dup_pt_time))
    c[3].metric("Values outside valid range", int(inv.invalid_values.sum()) if len(inv) else 0)
    st.caption(f"Latest record: {dup.latest}")
    st.markdown("**Reference intervals in use** (edit table `reference_ranges` to change)")
    st.dataframe(Q("SELECT analyte, unit, normal_min, normal_max, critical_min, valid_min, valid_max FROM reference_ranges ORDER BY sort_order"),
                 hide_index=True, width="stretch")
