"""Load FAERS/AEMS quarterly ASCII files into DuckDB (raw layer, no cleaning)."""
from pathlib import Path
import duckdb

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
DB_PATH = ROOT / "data" / "faers.duckdb"

TABLES = ["DEMO", "DRUG", "REAC", "OUTC", "INDI", "THER", "RPSR"]

def load():
    con = duckdb.connect(str(DB_PATH))
    for t in TABLES:
        pattern = (DATA / "faers_ascii_*" / "ASCII" / f"{t}*.txt").as_posix()
        con.execute(f"""
            CREATE OR REPLACE TABLE raw_{t.lower()} AS
            SELECT
                *,
                '20' || regexp_extract(filename, '(\\d{{2}})[Qq](\\d)', 1)
                     || 'Q' || regexp_extract(filename, '(\\d{{2}})[Qq](\\d)', 2) AS quarter
            FROM read_csv(
                '{pattern}',
                delim = '$',
                header = true,
                quote = '',
                escape = '',
                all_varchar = true,
                union_by_name = true,
                filename = true,
                encoding = 'latin-1'
            )
        """)
        n = con.execute(f"SELECT COUNT(*) FROM raw_{t.lower()}").fetchone()[0]
        print(f"raw_{t.lower():<6} {n:>12,} rows")
    con.close()

if __name__ == "__main__":
    load()