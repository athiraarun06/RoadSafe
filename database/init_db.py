"""Create the RoadSafe database: schema -> procedures -> views -> triggers -> sample data.

Usage:  python database/init_db.py            (full reset + sample data)
        python database/init_db.py --no-data  (schema/logic only)
"""
import os
import sys

import pymysql
from werkzeug.security import generate_password_hash

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from config import Config  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["schema.sql", "procedures.sql", "views.sql", "triggers.sql", "sample_data.sql"]
DEMO_PASSWORD = "Password@123"


def statements(text):
    """Split a SQL script into statements, honouring DELIMITER commands."""
    delimiter, buf = ";", []
    for line in text.splitlines():
        stripped = line.strip()
        if not buf and (not stripped or stripped.startswith("--")):
            continue
        if stripped.upper().startswith("DELIMITER "):
            delimiter = stripped.split()[1]
            continue
        buf.append(line)
        if stripped.endswith(delimiter):
            stmt = "\n".join(buf).rstrip()
            yield stmt[: -len(delimiter)].strip()
            buf = []
    if buf and "".join(buf).strip():
        yield "\n".join(buf).strip()


def main():
    load_data = "--no-data" not in sys.argv
    conn = pymysql.connect(host=Config.DB_HOST, port=Config.DB_PORT, user=Config.DB_USER,
                           password=Config.DB_PASSWORD, charset="utf8mb4", autocommit=True)
    pw_hash = generate_password_hash(DEMO_PASSWORD)
    with conn.cursor() as cur:
        for name in FILES:
            if name == "sample_data.sql" and not load_data:
                continue
            with open(os.path.join(HERE, name), encoding="utf-8") as fh:
                script = fh.read().replace("__HASH__", pw_hash)
            count = 0
            for stmt in statements(script):
                try:
                    cur.execute(stmt)
                    while cur.nextset():
                        pass
                except pymysql.MySQLError as exc:
                    print(f"\n[ERROR] {name}: {exc}\n--- statement ---\n{stmt[:400]}")
                    sys.exit(1)
                count += 1
            print(f"  ran {name:<18} ({count} statements)")
    conn.close()
    print("\nDatabase 'roadsafe' is ready.")
    if load_data:
        print(f"Demo logins (password for all: {DEMO_PASSWORD})")
        print("  admin     : admin@roadsafe.in")
        print("  customer  : aarav.sharma@example.com")
        print("  mechanic  : murugan.selvam@roadsafe.in")


if __name__ == "__main__":
    main()
