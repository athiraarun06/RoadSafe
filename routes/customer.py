"""Customer portal: profile, vehicles, assistance requests, billing, history, feedback."""
import pymysql
from flask import Blueprint, flash, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from auth import role_required
from db import call_proc, db_message, execute, query

bp = Blueprint("customer", __name__, url_prefix="/customer")

VEHICLE_TYPES = ["CAR", "SUV", "BIKE", "AUTO", "VAN", "TRUCK"]
FUEL_TYPES = ["PETROL", "DIESEL", "CNG", "ELECTRIC", "HYBRID"]
PRIORITIES = ["LOW", "MEDIUM", "HIGH", "EMERGENCY"]


def cid():
    return session["user_id"]


# ------------------------------------------------------------ dashboard
@bp.route("/dashboard")
@role_required("customer")
def dashboard():
    stats = query("""SELECT
        (SELECT COUNT(*) FROM vehicles WHERE customer_id = %(c)s) AS vehicles,
        (SELECT COUNT(*) FROM assistance_requests WHERE customer_id = %(c)s
            AND status NOT IN ('COMPLETED','CANCELLED')) AS active,
        (SELECT COUNT(*) FROM assistance_requests WHERE customer_id = %(c)s AND status = 'COMPLETED') AS completed,
        (SELECT COALESCE(SUM(total_amount), 0) FROM vw_request_details
            WHERE customer_id = %(c)s AND payment_status = 'PAID') AS spent,
        (SELECT COUNT(*) FROM vw_request_details
            WHERE customer_id = %(c)s AND payment_status = 'PENDING') AS unpaid,
        (SELECT COUNT(*) FROM vw_request_details
            WHERE customer_id = %(c)s AND status = 'COMPLETED' AND feedback_id IS NULL) AS to_rate""",
        {"c": cid()}, one=True)
    recent = query("SELECT * FROM vw_request_details WHERE customer_id = %s ORDER BY requested_at DESC LIMIT 5", (cid(),))
    return render_template("customer/dashboard.html", stats=stats, recent=recent)


# --------------------------------------------------------------- profile
@bp.route("/profile", methods=["GET", "POST"])
@role_required("customer")
def profile():
    if request.method == "POST":
        f = request.form
        try:
            if f.get("action") == "password":
                user = query("SELECT password_hash FROM customers WHERE customer_id = %s", (cid(),), one=True)
                if not check_password_hash(user["password_hash"], f.get("current", "")):
                    flash("Current password is incorrect.", "danger")
                elif len(f.get("new", "")) < 6 or f.get("new") != f.get("confirm"):
                    flash("New password must be 6+ characters and match the confirmation.", "danger")
                else:
                    execute("UPDATE customers SET password_hash = %s WHERE customer_id = %s",
                            (generate_password_hash(f["new"]), cid()))
                    flash("Password changed.", "success")
            else:
                execute("""UPDATE customers SET full_name = %s, phone = %s, address = %s, city = %s
                           WHERE customer_id = %s""",
                        (f["full_name"].strip(), f["phone"].strip(), f.get("address", "").strip() or None,
                         f.get("city", "").strip() or None, cid()))
                session["name"] = f["full_name"].strip()
                flash("Profile updated.", "success")
        except pymysql.MySQLError as exc:
            flash(db_message(exc), "danger")
        return redirect(url_for("customer.profile"))
    me = query("SELECT * FROM customers WHERE customer_id = %s", (cid(),), one=True)
    return render_template("customer/profile.html", me=me)


# -------------------------------------------------------------- vehicles
@bp.route("/vehicles")
@role_required("customer")
def vehicles():
    rows = query("""SELECT v.*, (SELECT COUNT(*) FROM assistance_requests r WHERE r.vehicle_id = v.vehicle_id) AS requests
                    FROM vehicles v WHERE v.customer_id = %s ORDER BY v.vehicle_id""", (cid(),))
    return render_template("customer/vehicles.html", vehicles=rows)


def _vehicle_values(f):
    return (f["registration_no"].strip().upper(), f["vehicle_type"], f["make"].strip(), f["model"].strip(),
            int(f["manufacture_year"]), f["fuel_type"], f.get("color", "").strip() or None)


@bp.route("/vehicles/add", methods=["GET", "POST"])
@role_required("customer")
def vehicle_add():
    if request.method == "POST":
        try:
            execute("""INSERT INTO vehicles (customer_id, registration_no, vehicle_type, make, model,
                                             manufacture_year, fuel_type, color)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""", (cid(),) + _vehicle_values(request.form))
            flash("Vehicle added.", "success")
            return redirect(url_for("customer.vehicles"))
        except (pymysql.MySQLError, ValueError) as exc:
            flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Please enter a valid year.", "danger")
    return render_template("customer/vehicle_form.html", v=request.form or None,
                           types=VEHICLE_TYPES, fuels=FUEL_TYPES)


@bp.route("/vehicles/<int:vid>/edit", methods=["GET", "POST"])
@role_required("customer")
def vehicle_edit(vid):
    v = query("SELECT * FROM vehicles WHERE vehicle_id = %s AND customer_id = %s", (vid, cid()), one=True)
    if not v:
        flash("Vehicle not found.", "danger")
        return redirect(url_for("customer.vehicles"))
    if request.method == "POST":
        try:
            execute("""UPDATE vehicles SET registration_no = %s, vehicle_type = %s, make = %s, model = %s,
                              manufacture_year = %s, fuel_type = %s, color = %s
                       WHERE vehicle_id = %s AND customer_id = %s""", _vehicle_values(request.form) + (vid, cid()))
            flash("Vehicle updated.", "success")
            return redirect(url_for("customer.vehicles"))
        except (pymysql.MySQLError, ValueError) as exc:
            flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Please enter a valid year.", "danger")
    return render_template("customer/vehicle_form.html", v=v, edit=True, types=VEHICLE_TYPES, fuels=FUEL_TYPES)


@bp.route("/vehicles/<int:vid>/delete", methods=["POST"])
@role_required("customer")
def vehicle_delete(vid):
    try:
        execute("DELETE FROM vehicles WHERE vehicle_id = %s AND customer_id = %s", (vid, cid()))
        flash("Vehicle deleted.", "success")
    except pymysql.MySQLError:
        flash("This vehicle has assistance requests on record, so it cannot be deleted.", "danger")
    return redirect(url_for("customer.vehicles"))


# -------------------------------------------------------------- requests
@bp.route("/request/new", methods=["GET", "POST"])
@role_required("customer")
def request_new():
    my_vehicles = query("SELECT * FROM vehicles WHERE customer_id = %s", (cid(),))
    services = query("SELECT * FROM services WHERE is_active = 1 ORDER BY service_id")
    me = query("SELECT city, address FROM customers WHERE customer_id = %s", (cid(),), one=True)
    if request.method == "POST":
        f = request.form

        def num(key):
            try:
                return float(f[key]) if f.get(key) else None
            except ValueError:
                return None
        try:
            _, out = call_proc("sp_create_request", (
                cid(), int(f["vehicle_id"]), int(f["service_id"]), f["priority"],
                f.get("description", "").strip() or None, f["address"].strip(), f["city"].strip(),
                f.get("pincode", "").strip() or None, f.get("landmark", "").strip() or None,
                num("latitude"), num("longitude")), outs=1)
            rid = out[0]
            _, assigned = call_proc("sp_auto_assign_mechanic", (rid,), outs=1)
            if assigned[0]:
                m = query("SELECT full_name FROM mechanics WHERE mechanic_id = %s", (assigned[0],), one=True)
                flash(f"Request #{rid} created. {m['full_name']} was recommended and assigned automatically.", "success")
            else:
                flash(f"Request #{rid} created. No mechanic is free right now - our admin team will assign one shortly.", "warning")
            return redirect(url_for("customer.request_detail", rid=rid))
        except (pymysql.MySQLError, ValueError, KeyError) as exc:
            flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Please fill in all required fields.", "danger")
    return render_template("customer/request_new.html", vehicles=my_vehicles, services=services,
                           priorities=PRIORITIES, me=me, f=request.form,
                           preset_service=request.args.get("service", type=int))


@bp.route("/requests")
@role_required("customer")
def requests_list():
    status = request.args.get("status", "")
    sql, args = "SELECT * FROM vw_request_details WHERE customer_id = %s", [cid()]
    if status == "active":
        sql += " AND status NOT IN ('COMPLETED','CANCELLED')"
    elif status:
        sql += " AND status = %s"
        args.append(status)
    rows = query(sql + " ORDER BY requested_at DESC", args)
    return render_template("customer/requests.html", rows=rows, status=status)


@bp.route("/requests/<int:rid>")
@role_required("customer")
def request_detail(rid):
    r = query("SELECT * FROM vw_request_details WHERE request_id = %s AND customer_id = %s", (rid, cid()), one=True)
    if not r:
        flash("Request not found.", "danger")
        return redirect(url_for("customer.requests_list"))
    return render_template("customer/request_detail.html", r=r)


@bp.route("/requests/<int:rid>/cancel", methods=["POST"])
@role_required("customer")
def request_cancel(rid):
    try:
        call_proc("sp_cancel_request", (rid, cid()))
        flash(f"Request #{rid} cancelled.", "info")
    except pymysql.MySQLError as exc:
        flash(db_message(exc), "danger")
    return redirect(url_for("customer.request_detail", rid=rid))


# ---------------------------------------------------- billing / payments
@bp.route("/bills")
@role_required("customer")
def bills():
    rows = query("""SELECT * FROM vw_request_details WHERE customer_id = %s AND payment_id IS NOT NULL
                    ORDER BY payment_status = 'PAID', requested_at DESC""", (cid(),))
    return render_template("customer/bills.html", rows=rows)


@bp.route("/requests/<int:rid>/pay", methods=["GET", "POST"])
@role_required("customer")
def pay(rid):
    r = query("SELECT * FROM vw_request_details WHERE request_id = %s AND customer_id = %s", (rid, cid()), one=True)
    if not r or not r["payment_id"]:
        flash("No bill is available for this request yet.", "warning")
        return redirect(url_for("customer.bills"))
    if request.method == "POST":
        method = request.form.get("method")
        if method not in ("CASH", "UPI", "CARD"):
            flash("Choose a payment method.", "danger")
        else:
            try:
                _, out = call_proc("sp_make_payment", (rid, cid(), method), outs=1)
                flash(f"Payment successful. Transaction reference: {out[0]}", "success")
                return redirect(url_for("customer.request_detail", rid=rid))
            except pymysql.MySQLError as exc:
                flash(db_message(exc), "danger")
                return redirect(url_for("customer.bills"))
    return render_template("customer/pay.html", r=r)


# ------------------------------------------------ history and feedback
@bp.route("/history")
@role_required("customer")
def history():
    rows = query("SELECT * FROM vw_service_history_details WHERE customer_id = %s ORDER BY completed_at DESC", (cid(),))
    return render_template("customer/history.html", rows=rows)


@bp.route("/feedback")
@role_required("customer")
def feedback_list():
    pending = query("""SELECT * FROM vw_request_details WHERE customer_id = %s AND status = 'COMPLETED'
                       AND feedback_id IS NULL ORDER BY completed_at DESC""", (cid(),))
    given = query("""SELECT * FROM vw_request_details WHERE customer_id = %s AND feedback_id IS NOT NULL
                     ORDER BY completed_at DESC""", (cid(),))
    return render_template("customer/feedback.html", pending=pending, given=given)


@bp.route("/feedback/<int:rid>", methods=["GET", "POST"])
@role_required("customer")
def feedback_form(rid):
    r = query("SELECT * FROM vw_request_details WHERE request_id = %s AND customer_id = %s", (rid, cid()), one=True)
    if not r or r["status"] != "COMPLETED":
        flash("You can rate a service once it is completed.", "warning")
        return redirect(url_for("customer.feedback_list"))
    if request.method == "POST":
        try:
            call_proc("sp_submit_feedback", (rid, cid(), int(request.form.get("rating", 0)),
                                             request.form.get("comments", "").strip() or None))
            flash("Thank you for your feedback!", "success")
            return redirect(url_for("customer.feedback_list"))
        except (pymysql.MySQLError, ValueError) as exc:
            flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Choose a rating.", "danger")
    return render_template("customer/feedback_form.html", r=r)
