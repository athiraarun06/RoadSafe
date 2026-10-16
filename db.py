"""Thin MySQL helper layer (PyMySQL). One connection per request, stored in flask.g."""
import pymysql
from flask import g
from config import Config


def get_db():
    if "db" not in g:
        g.db = pymysql.connect(
            host=Config.DB_HOST, port=Config.DB_PORT, user=Config.DB_USER,
            password=Config.DB_PASSWORD, database=Config.DB_NAME, charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor, autocommit=True)
    return g.db


def close_db(_exc=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query(sql, args=None, one=False):
    """SELECT helper -> list of dicts (or a single dict / None when one=True)."""
    with get_db().cursor() as cur:
        cur.execute(sql, args)
        rows = cur.fetchall()
    if one:
        return rows[0] if rows else None
    return rows


def execute(sql, args=None):
    """INSERT / UPDATE / DELETE helper -> lastrowid."""
    with get_db().cursor() as cur:
        cur.execute(sql, args)
        return cur.lastrowid


def call_proc(name, args=(), outs=0):
    """CALL a stored procedure. Returns (rows_of_first_result_set, [OUT values])."""
    marks = ["%s"] * len(args) + [f"@_o{i}" for i in range(outs)]
    with get_db().cursor() as cur:
        cur.execute(f"CALL {name}({', '.join(marks)})", tuple(args))
        rows = cur.fetchall()
        while cur.nextset():
            pass
        out = []
        if outs:
            cur.execute("SELECT " + ", ".join(f"@_o{i} AS o{i}" for i in range(outs)))
            row = cur.fetchone()
            out = [row[f"o{i}"] for i in range(outs)]
    return rows, out


def db_message(exc):
    """Human friendly text for a MySQL error (SIGNAL messages are shown as-is)."""
    code = exc.args[0] if exc.args else 0
    msg = exc.args[1] if len(exc.args) > 1 else str(exc)
    if code == 1062:
        return "That value already exists (duplicate email, phone, registration or name)."
    if code in (1451, 1452):
        return "This record is linked to other data and cannot be changed this way."
    if code == 3819:
        return "A value violated a database rule (CHECK constraint)."
    return msg
