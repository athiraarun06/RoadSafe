"""Landing page, login, registration, logout."""
import pymysql
from flask import Blueprint, flash, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from db import db_message, execute, query

bp = Blueprint("main", __name__)

ROLE_TABLES = {
    "customer": ("customers", "customer_id", "customer.dashboard"),
    "mechanic": ("mechanics", "mechanic_id", "mechanic.dashboard"),
    "admin":    ("admins",    "admin_id",    "admin.dashboard"),
}


@bp.route("/")
def index():
    stats = query("""SELECT (SELECT COUNT(*) FROM customers)  AS customers,
                            (SELECT COUNT(*) FROM mechanics WHERE is_active = 1) AS mechanics,
                            (SELECT COUNT(*) FROM service_history) AS jobs,
                            (SELECT ROUND(AVG(rating), 1) FROM feedback) AS rating""", one=True)
    services = query("SELECT * FROM services WHERE is_active = 1 ORDER BY service_id")
    return render_template("index.html", stats=stats, services=services)


@bp.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        role = request.form.get("role", "customer")
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        if role not in ROLE_TABLES:
            role = "customer"
        table, pk, target = ROLE_TABLES[role]
        user = query(f"SELECT * FROM {table} WHERE email = %s", (email,), one=True)
        if not user or not check_password_hash(user["password_hash"], password):
            flash("Invalid email or password.", "danger")
        elif not user.get("is_active", 1):
            flash("This account has been deactivated. Please contact support.", "danger")
        else:
            session.clear()
            session.update(role=role, user_id=user[pk], name=user["full_name"])
            flash(f"Welcome back, {user['full_name']}!", "success")
            return redirect(url_for(target))
    return render_template("login.html", role=request.args.get("role", "customer"))


@bp.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        f = request.form
        name, email = f.get("full_name", "").strip(), f.get("email", "").strip().lower()
        phone, pw = f.get("phone", "").strip(), f.get("password", "")
        if not (name and email and phone):
            flash("Name, email and phone are required.", "danger")
        elif len(pw) < 6:
            flash("Password must be at least 6 characters.", "danger")
        elif pw != f.get("confirm", ""):
            flash("Passwords do not match.", "danger")
        else:
            try:
                execute("""INSERT INTO customers (full_name, email, phone, password_hash, address, city)
                           VALUES (%s, %s, %s, %s, %s, %s)""",
                        (name, email, phone, generate_password_hash(pw),
                         f.get("address", "").strip() or None, f.get("city", "").strip() or None))
                flash("Account created. Please log in.", "success")
                return redirect(url_for("main.login"))
            except pymysql.MySQLError as exc:
                flash(db_message(exc), "danger")
    return render_template("register.html")


@bp.route("/logout")
def logout():
    session.clear()
    flash("You have been logged out.", "info")
    return redirect(url_for("main.index"))
