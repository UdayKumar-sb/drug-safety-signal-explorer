"""Run a .sql file against data/faers.duckdb, printing every SELECT result as a markdown table.

Usage (from repo root):
    python src/run_sql.py sql/01_diagnose_case_versions.sql
    python src/run_sql.py sql/02_dedup.sql

Override the database with the FAERS_DB environment variable (handy for tests).
Markdown output means result tables can be pasted straight into the README.
"""
import os
import sys
from pathlib import Path

import duckdb

DEFAULT_DB = Path(__file__).resolve().parents[1] / "data" / "faers.duckdb"


def to_markdown(columns, rows):
    """Render a result set as a GitHub-flavoured markdown table."""
    def fmt(v):
        return f"{v:,}" if isinstance(v, int) and not isinstance(v, bool) else str(v)

    lines = [
        "| " + " | ".join(columns) + " |",
        "|" + "|".join("---" for _ in columns) + "|",
    ]
    lines += ["| " + " | ".join(fmt(v) for v in row) + " |" for row in rows]
    return "\n".join(lines)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python src/run_sql.py <path-to-sql-file>")

    sql_path = Path(sys.argv[1])
    db_path = Path(os.environ.get("FAERS_DB", DEFAULT_DB))
    con = duckdb.connect(str(db_path))

    # extract_statements splits correctly even with semicolons inside comments or strings.
    statements = con.extract_statements(sql_path.read_text(encoding="utf-8"))
    for i, stmt in enumerate(statements, start=1):
        con.execute(stmt)
        if stmt.type == duckdb.StatementType.SELECT:
            columns = [c[0] for c in con.description]
            rows = con.fetchall()
            print(f"\n-- statement {i}")
            print(to_markdown(columns, rows))
        else:
            print(f"\n-- statement {i}: OK ({stmt.query.strip().splitlines()[0][:70]})")
    con.close()


if __name__ == "__main__":
    main()