"""Loads urinalysis.csv into the urinalysis_results table (run once).
Usage:  python load_data.py        (urinalysis.csv must be in the same folder)
Tables must already exist (Part 1 of the SQL file)."""
import getpass, os, sys
import psycopg2

here = os.path.dirname(os.path.abspath(__file__))
csv_path = os.path.join(here, "urinalysis.csv")
if not os.path.exists(csv_path):
    sys.exit(f"Cannot find {csv_path}. Put urinalysis.csv in the same folder as this script.")

host = input("Host [localhost]: ").strip() or "localhost"
port = input("Port [5432]: ").strip() or "5432"
db   = input("Database [Mantray]: ").strip() or "Mantray"
user = input("User [postgres]: ").strip() or "postgres"
pw   = os.getenv("PGPASSWORD") or getpass.getpass("Password (typing is hidden): ")

conn = psycopg2.connect(host=host, port=port, dbname=db, user=user, password=pw)
try:
    with conn, conn.cursor() as cur:
        cur.execute("TRUNCATE urinalysis_results")
        with open(csv_path, newline="", encoding="utf-8") as f:
            cur.copy_expert("COPY urinalysis_results FROM STDIN WITH (FORMAT csv, HEADER true)", f)
        cur.execute("SELECT COUNT(*) FROM urinalysis_results")
        print("Rows loaded:", cur.fetchone()[0])
finally:
    conn.close()
