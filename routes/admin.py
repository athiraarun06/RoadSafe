"""Admin console: dashboard, management pages, assignment, payments, feedback, reports."""
from datetime import date, timedelta

import pymysql
from flask import Blueprint, flash, redirect, render_template, request, url_for
from werkzeug.security import generate_password_hash

from auth import role_required
from db import call_proc, db_message, execute, get_db, query

bp = Blueprint("admin", __name__, url_prefix="/admin")


# ------------------------------------------------------------- dashboard
@bp.route("/dashboard")
@role_required("admin")
def dashboard():
    stats = query("""SELECT
        (SELECT COUNT(*) FROM customers) AS customers,
        (SELECT COUNT(*) FROM mechanics WHERE is_active = 1) AS mechanics,
        (SELECT COUNT(*) FROM assistance_requests) AS requests,
        (SELECT COUNT(*) FROM assistance_requests WHERE status NOT IN ('COMPLETED','CANCELLED')) AS active,
        (SELECT COUNT(*) FROM assistance_requests WHERE status = 'PENDING') AS unassigned,
        (SELECT COALESCE(SUM(total_amount), 0) FROM payments WHERE payment_status = 'PAID') AS revenue,
        (SELECT COALESCE(SUM(total_amount), 0) FROM payments WHERE payment_status = 'PENDING') AS outstanding,
        (SELECT ROUND(AVG(rating), 2) FROM feedback) AS avg_rating""", one=True)
    by_status = query("SELECT status, COUNT(*) AS n FROM assistance_requests GROUP BY status")
    monthly = query("SELECT month, revenue FROM vw_monthly_revenue ORDER BY month")
    demand = query("SELECT service_name, total_requests FROM vw_service_demand ORDER BY total_requests DESC")
    queue = query("""SELECT * FROM vw_request_details WHERE status = 'PENDING'
                     ORDER BY FIELD(priority,'EMERGENCY','HIGH','MEDIUM','LOW'), requested_at""")
    recent = query("SELECT * FROM vw_request_details ORDER BY requested_at DESC LIMIT 6")
    return render_template("admin/dashboard.html", stats=stats, by_status=by_status, monthly=monthly,
                           demand=demand, queue=queue, recent=recent)


# ------------------------------------------------------------- customers
@bp.route("/customers")
@role_required("admin")
def customers():
    rows = query("""SELECT c.customer_id, c.full_name, c.email, c.phone, c.city, c.is_active, c.created_at,
                           COUNT(DISTINCT v.vehicle_id) AS vehicles,
                           COUNT(DISTINCT r.request_id) AS requests,
                           COALESCE((SELECT SUM(p.total_amount) FROM payments p
                                     JOIN assistance_requests r2 ON r2.request_id = p.request_id
                                     WHERE r2.customer_id = c.customer_id AND p.payment_status = 'PAID'), 0) AS spent
                    FROM customers c
                    LEFT JOIN vehicles v ON v.customer_id = c.customer_id
                    LEFT JOIN assistance_requests r ON r.customer_id = c.customer_id
                    GROUP BY c.customer_id, c.full_name, c.email, c.phone, c.city, c.is_active, c.created_at
                    ORDER BY c.customer_id""")
    return render_template("admin/customers.html", rows=rows)


@bp.route("/customers/<int:cid>/toggle", methods=["POST"])
@role_required("admin")
def customer_toggle(cid):
    execute("UPDATE customers SET is_active = 1 - is_active WHERE customer_id = %s", (cid,))
    flash("Customer status changed.", "success")
    return redirect(url_for("admin.customers"))


# -------------------------------------------------------------- mechanics
@bp.route("/mechanics")
@role_required("admin")
def mechanics():
    rows = query("SELECT * FROM vw_mechanic_performance ORDER BY mechanic_id")
    return render_template("admin/mechanics.html", rows=rows)


@bp.route("/mechanics/new", methods=["GET", "POST"])
@bp.route("/mechanics/<int:mid>/edit", methods=["GET", "POST"])
@role_required("admin")
def mechanic_form(mid=None):
    services = query("SELECT service_id, service_name FROM services ORDER BY service_id")
    m = query("SELECT * FROM mechanics WHERE mechanic_id = %s", (mid,), one=True) if mid else None
    if mid and not m:
        flash("Mechanic not found.", "danger")
        return redirect(url_for("admin.mechanics"))
    chosen = {r["service_id"] for r in query("SELECT service_id FROM mechanic_services WHERE mechanic_id = %s", (mid,))} if mid else set()
    if request.method == "POST":
        f = request.form
        picked = [int(s) for s in f.getlist("services")]
        conn = get_db()
        try:
            conn.begin()   # one transaction: mechanic row + service links
            with conn.cursor() as cur:
                if mid:
                    cur.execute("""UPDATE mechanics SET full_name = %s, phone = %s, city = %s, experience_years = %s
                                   WHERE mechanic_id = %s""",
                                (f["full_name"].strip(), f["phone"].strip(), f["city"].strip(), int(f["experience_years"]), mid))
                    if f.get("password"):
                        cur.execute("UPDATE mechanics SET password_hash = %s WHERE mechanic_id = %s",
                                    (generate_password_hash(f["password"]), mid))
                    cur.execute("DELETE FROM mechanic_services WHERE mechanic_id = %s", (mid,))
                    new_id = mid
                else:
                    if len(f.get("password", "")) < 6:
                        raise ValueError("Password must be at least 6 characters.")
                    cur.execute("""INSERT INTO mechanics (full_name, email, phone, password_hash, city, experience_years)
                                   VALUES (%s, %s, %s, %s, %s, %s)""",
                                (f["full_name"].strip(), f["email"].strip().lower(), f["phone"].strip(),
                                 generate_password_hash(f["password"]), f["city"].strip(), int(f["experience_years"])))
                    new_id = cur.lastrowid
                for sid in picked:
                    cur.execute("INSERT INTO mechanic_services (mechanic_id, service_id) VALUES (%s, %s)", (new_id, sid))
            conn.commit()
            flash("Mechanic saved.", "success")
            return redirect(url_for("admin.mechanics"))
        except (pymysql.MySQLError, ValueError, KeyError) as exc:
            conn.rollback()
            if isinstance(exc, pymysql.MySQLError):
                flash(db_message(exc), "danger")
            elif isinstance(exc, ValueError) and str(exc).startswith("Password"):
                flash(str(exc), "danger")
            else:
                flash("Please fill in all fields with valid values.", "danger")
        chosen = set(picked)
        m = request.form
    return render_template("admin/mechanic_form.html", m=m, services=services, chosen=chosen, edit=bool(mid))


@bp.route("/mechanics/<int:mid>/toggle", methods=["POST"])
@role_required("admin")
def mechanic_toggle(mid):
    execute("UPDATE mechanics SET is_active = 1 - is_active WHERE mechanic_id = %s", (mid,))
    flash("Mechanic status changed.", "success")
    return redirect(url_for("admin.mechanics"))


# --------------------------------------------------------------- services
@bp.route("/services")
@role_required("admin")
def services():
    rows = query("""SELECT s.*, vd.total_requests, vd.revenue,
                           (SELECT COUNT(*) FROM mechanic_services ms WHERE ms.service_id = s.service_id) AS mechanics
                    FROM services s JOIN vw_service_demand vd ON vd.service_id = s.service_id ORDER BY s.service_id""")
    return render_template("admin/services.html", rows=rows)


@bp.route("/services/new", methods=["GET", "POST"])
@bp.route("/services/<int:sid>/edit", methods=["GET", "POST"])
@role_required("admin")
def service_form(sid=None):
    s = query("SELECT * FROM services WHERE service_id = %s", (sid,), one=True) if sid else None
    if request.method == "POST":
        f = request.form
        try:
            vals = (f["service_name"].strip(), f.get("description", "").strip() or None,
                    float(f["base_charge"]), f.get("icon", "").strip() or "bi-tools")
            if sid:
                execute("UPDATE services SET service_name = %s, description = %s, base_charge = %s, icon = %s WHERE service_id = %s",
                        vals + (sid,))
            else:
                execute("INSERT INTO services (service_name, description, base_charge, icon) VALUES (%s, %s, %s, %s)", vals)
            flash("Service saved.", "success")
            return redirect(url_for("admin.services"))
        except (pymysql.MySQLError, ValueError, KeyError) as exc:
            flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Enter a valid name and charge.", "danger")
        s = request.form
    return render_template("admin/service_form.html", s=s, edit=bool(sid))


@bp.route("/services/<int:sid>/toggle", methods=["POST"])
@role_required("admin")
def service_toggle(sid):
    execute("UPDATE services SET is_active = 1 - is_active WHERE service_id = %s", (sid,))
    flash("Service availability changed.", "success")
    return redirect(url_for("admin.services"))


# --------------------------------------------------------------- requests
@bp.route("/requests")
@role_required("admin")
def requests_list():
    status, priority = request.args.get("status", ""), request.args.get("priority", "")
    sql, args = "SELECT * FROM vw_request_details WHERE 1 = 1", []
    if status:
        sql += " AND status = %s"
        args.append(status)
    if priority:
        sql += " AND priority = %s"
        args.append(priority)
    rows = query(sql + " ORDER BY requested_at DESC", args)
    return render_template("admin/requests.html", rows=rows, status=status, priority=priority)


@bp.route("/requests/<int:rid>")
@role_required("admin")
def request_detail(rid):
    r = query("SELECT * FROM vw_request_details WHERE request_id = %s", (rid,), one=True)
    if not r:
        flash("Request not found.", "danger")
        return redirect(url_for("admin.requests_list"))
    candidates = []
    if r["status"] in ("PENDING", "ASSIGNED", "ACCEPTED"):
        candidates, _ = call_proc("sp_recommend_mechanics", (rid,))
    return render_template("admin/request_detail.html", r=r, candidates=candidates)


@bp.route("/requests/<int:rid>/assign", methods=["POST"])
@role_required("admin")
def assign(rid):
    try:
        if request.form.get("mode") == "auto":
            _, out = call_proc("sp_auto_assign_mechanic", (rid,), outs=1)
            flash("Best-scoring mechanic assigned automatically." if out[0]
                  else "No eligible mechanic is available for this request.", "success" if out[0] else "warning")
        else:
            call_proc("sp_assign_mechanic", (rid, int(request.form["mechanic_id"]), "ADMIN"))
            flash("Mechanic assigned.", "success")
    except (pymysql.MySQLError, ValueError, KeyError) as exc:
        flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Select a mechanic.", "danger")
    return redirect(url_for("admin.request_detail", rid=rid))


@bp.route("/requests/<int:rid>/cancel", methods=["POST"])
@role_required("admin")
def cancel(rid):
    r = query("SELECT customer_id FROM assistance_requests WHERE request_id = %s", (rid,), one=True)
    try:
        call_proc("sp_cancel_request", (rid, r["customer_id"] if r else 0))
        flash("Request cancelled.", "info")
    except pymysql.MySQLError as exc:
        flash(db_message(exc), "danger")
    return redirect(url_for("admin.request_detail", rid=rid))


# --------------------------------------------------- payments / feedback
@bp.route("/payments")
@role_required("admin")
def payments():
    status = request.args.get("status", "")
    sql, args = "SELECT * FROM vw_request_details WHERE payment_id IS NOT NULL", []
    if status:
        sql += " AND payment_status = %s"
        args.append(status)
    rows = query(sql + " ORDER BY requested_at DESC", args)
    totals = query("""SELECT COALESCE(SUM(CASE WHEN payment_status = 'PAID' THEN total_amount END), 0) AS paid,
                             COALESCE(SUM(CASE WHEN payment_status = 'PENDING' THEN total_amount END), 0) AS pending
                      FROM payments""", one=True)
    methods = query("""SELECT payment_method, COUNT(*) AS n, SUM(total_amount) AS amount FROM payments
                       WHERE payment_status = 'PAID' GROUP BY payment_method""")
    return render_template("admin/payments.html", rows=rows, status=status, totals=totals, methods=methods)


@bp.route("/feedback")
@role_required("admin")
def feedback():
    rating = request.args.get("rating", type=int)
    sql, args = "SELECT * FROM vw_request_details WHERE feedback_id IS NOT NULL", []
    if rating:
        sql += " AND rating = %s"
        args.append(rating)
    rows = query(sql + " ORDER BY completed_at DESC", args)
    summary = query("SELECT COUNT(*) AS n, ROUND(AVG(rating), 2) AS avg FROM feedback", one=True)
    return render_template("admin/feedback.html", rows=rows, summary=summary, rating=rating)


# ---------------------------------------------------------------- reports
@bp.route("/reports")
@role_required("admin")
def reports():
    try:
        d_from = date.fromisoformat(request.args.get("from", ""))
        d_to = date.fromisoformat(request.args.get("to", ""))
    except ValueError:
        d_to, d_from = date.today(), date.today() - timedelta(days=90)
    revenue_rows, _ = call_proc("sp_revenue_report", (d_from, d_to))
    mech = query("""SELECT m.full_name, m.city, COUNT(*) AS jobs, ROUND(AVG(f.rating), 2) AS avg_rating
                    FROM mechanics m
                    JOIN request_assignments ra ON ra.mechanic_id = m.mechanic_id
                    JOIN feedback f ON f.request_id = ra.request_id
                    GROUP BY m.mechanic_id, m.full_name, m.city
                    HAVING COUNT(*) >= 2 AND AVG(f.rating) >= 4
                    ORDER BY avg_rating DESC, jobs DESC""")
    cities = query("""SELECT l.city, COUNT(*) AS requests,
                             SUM(r.priority = 'EMERGENCY') AS emergencies,
                             COALESCE(SUM(p.total_amount), 0) AS revenue
                      FROM assistance_requests r
                      JOIN locations l ON l.location_id = r.location_id
                      LEFT JOIN payments p ON p.request_id = r.request_id AND p.payment_status = 'PAID'
                      GROUP BY l.city ORDER BY requests DESC""")
    priorities = query("SELECT priority, COUNT(*) AS n FROM assistance_requests GROUP BY priority")
    top_customers = query("""SELECT c.full_name, c.city, COUNT(r.request_id) AS requests,
                                    COALESCE(SUM(p.total_amount), 0) AS spent
                             FROM customers c
                             JOIN assistance_requests r ON r.customer_id = c.customer_id
                             LEFT JOIN payments p ON p.request_id = r.request_id AND p.payment_status = 'PAID'
                             GROUP BY c.customer_id, c.full_name, c.city
                             HAVING COUNT(r.request_id) >= 2 ORDER BY spent DESC LIMIT 5""")
    avg_response = query("""SELECT ROUND(AVG(TIMESTAMPDIFF(MINUTE, requested_at, completed_at))) AS avg_minutes
                            FROM assistance_requests WHERE status = 'COMPLETED'""", one=True)
    monthly = query("SELECT month, payments_count, revenue FROM vw_monthly_revenue ORDER BY month")
    return render_template("admin/reports.html", d_from=d_from, d_to=d_to, revenue_rows=revenue_rows,
                           mech=mech, cities=cities, priorities=priorities, top_customers=top_customers,
                           avg_response=avg_response, monthly=monthly)
