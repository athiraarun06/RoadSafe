"""Mechanic portal: availability, assigned jobs, status updates, earnings, ratings."""
import pymysql
from flask import Blueprint, flash, redirect, render_template, request, session, url_for

from auth import role_required
from db import call_proc, db_message, execute, query

bp = Blueprint("mechanic", __name__, url_prefix="/mechanic")

NEXT_STATUS = {"ACCEPTED": ("ON_THE_WAY", "Start driving to customer", "bi-signpost-2"),
               "ON_THE_WAY": ("ARRIVED", "I have arrived", "bi-geo-alt"),
               "ARRIVED": ("IN_PROGRESS", "Start the work", "bi-wrench-adjustable")}


def mid():
    return session["user_id"]


def own_request(rid):
    return query("""SELECT * FROM vw_request_details WHERE request_id = %s AND mechanic_id = %s""",
                 (rid, mid()), one=True)


@bp.route("/dashboard")
@role_required("mechanic")
def dashboard():
    me = query("SELECT * FROM vw_mechanic_performance WHERE mechanic_id = %s", (mid(),), one=True)
    services = query("""SELECT s.service_name, s.icon FROM mechanic_services ms
                        JOIN services s ON s.service_id = ms.service_id WHERE ms.mechanic_id = %s""", (mid(),))
    new_jobs = query("""SELECT * FROM vw_request_details WHERE mechanic_id = %s AND assignment_response = 'PENDING'
                        AND status = 'ASSIGNED' ORDER BY FIELD(priority,'EMERGENCY','HIGH','MEDIUM','LOW')""", (mid(),))
    active = query("""SELECT * FROM vw_request_details WHERE mechanic_id = %s AND assignment_response = 'ACCEPTED'
                      AND status IN ('ACCEPTED','ON_THE_WAY','ARRIVED','IN_PROGRESS') ORDER BY requested_at""", (mid(),))
    reviews = query("""SELECT rating, feedback_comments, customer_name, service_name, completed_at
                       FROM vw_request_details WHERE mechanic_id = %s AND feedback_id IS NOT NULL
                       ORDER BY completed_at DESC LIMIT 3""", (mid(),))
    return render_template("mechanic/dashboard.html", me=me, services=services, new_jobs=new_jobs,
                           active=active, reviews=reviews)


@bp.route("/availability", methods=["POST"])
@role_required("mechanic")
def availability():
    execute("UPDATE mechanics SET is_available = 1 - is_available WHERE mechanic_id = %s", (mid(),))
    row = query("SELECT is_available FROM mechanics WHERE mechanic_id = %s", (mid(),), one=True)
    flash("You are now ONLINE and can receive requests." if row["is_available"]
          else "You are now OFFLINE. No new requests will be assigned.", "info")
    return redirect(request.referrer or url_for("mechanic.dashboard"))


@bp.route("/requests")
@role_required("mechanic")
def requests_list():
    flt = request.args.get("filter", "active")
    sql = "SELECT * FROM vw_request_details WHERE mechanic_id = %s"
    if flt == "active":
        sql += " AND assignment_response IN ('PENDING','ACCEPTED') AND status NOT IN ('COMPLETED','CANCELLED')"
    elif flt != "all":
        sql += " AND assignment_response <> 'REJECTED'"
    rows = query(sql + " ORDER BY requested_at DESC", (mid(),))
    return render_template("mechanic/requests.html", rows=rows, flt=flt)


@bp.route("/requests/<int:rid>")
@role_required("mechanic")
def request_detail(rid):
    r = own_request(rid)
    if not r:
        flash("Request not found or not assigned to you.", "warning")
        return redirect(url_for("mechanic.requests_list"))
    return render_template("mechanic/request_detail.html", r=r, next_status=NEXT_STATUS.get(r["status"]))


@bp.route("/requests/<int:rid>/respond", methods=["POST"])
@role_required("mechanic")
def respond(rid):
    accept = request.form.get("decision") == "accept"
    try:
        call_proc("sp_mechanic_respond", (rid, mid(), 1 if accept else 0,
                                          request.form.get("reason", "").strip() or None))
        if accept:
            flash("Request accepted. The customer has been notified.", "success")
        else:
            # hand the job to the next best mechanic automatically
            _, out = call_proc("sp_auto_assign_mechanic", (rid,), outs=1)
            flash("Request rejected" + (" and re-assigned to another mechanic." if out[0]
                                        else "; it is back in the admin queue."), "info")
            return redirect(url_for("mechanic.requests_list"))
    except pymysql.MySQLError as exc:
        flash(db_message(exc), "danger")
    return redirect(url_for("mechanic.request_detail", rid=rid))


@bp.route("/requests/<int:rid>/status", methods=["POST"])
@role_required("mechanic")
def update_status(rid):
    try:
        call_proc("sp_update_status", (rid, mid(), request.form.get("status", "")))
        flash("Status updated.", "success")
    except pymysql.MySQLError as exc:
        flash(db_message(exc), "danger")
    return redirect(url_for("mechanic.request_detail", rid=rid))


@bp.route("/requests/<int:rid>/complete", methods=["POST"])
@role_required("mechanic")
def complete(rid):
    try:
        parts = float(request.form.get("parts_charge") or 0)
        call_proc("sp_complete_service", (rid, mid(), parts, request.form.get("notes", "").strip() or None))
        flash("Service completed. The bill has been sent to the customer.", "success")
    except (pymysql.MySQLError, ValueError) as exc:
        flash(db_message(exc) if isinstance(exc, pymysql.MySQLError) else "Enter a valid parts amount.", "danger")
    return redirect(url_for("mechanic.request_detail", rid=rid))


@bp.route("/jobs")
@role_required("mechanic")
def jobs():
    rows = query("SELECT * FROM vw_service_history_details WHERE mechanic_id = %s ORDER BY completed_at DESC", (mid(),))
    return render_template("mechanic/jobs.html", rows=rows)


@bp.route("/earnings")
@role_required("mechanic")
def earnings():
    me = query("SELECT * FROM vw_mechanic_performance WHERE mechanic_id = %s", (mid(),), one=True)
    monthly = query("SELECT month, jobs, earned FROM vw_mechanic_monthly_earnings WHERE mechanic_id = %s ORDER BY month",
                    (mid(),))
    pending = query("""SELECT COALESCE(SUM(total_amount), 0) AS amount, COUNT(*) AS n FROM vw_request_details
                       WHERE mechanic_id = %s AND payment_status = 'PENDING'""", (mid(),), one=True)
    rows = query("""SELECT request_id, service_name, customer_name, total_amount, payment_status, payment_method, paid_at
                    FROM vw_request_details WHERE mechanic_id = %s AND payment_id IS NOT NULL
                    ORDER BY requested_at DESC""", (mid(),))
    return render_template("mechanic/earnings.html", me=me, monthly=monthly, pending=pending, rows=rows)


@bp.route("/ratings")
@role_required("mechanic")
def ratings():
    me = query("SELECT * FROM vw_mechanic_performance WHERE mechanic_id = %s", (mid(),), one=True)
    rows = query("""SELECT request_id, rating, feedback_comments, customer_name, service_name, completed_at
                    FROM vw_request_details WHERE mechanic_id = %s AND feedback_id IS NOT NULL
                    ORDER BY completed_at DESC""", (mid(),))
    dist = query("""SELECT rating, COUNT(*) AS n FROM vw_request_details
                    WHERE mechanic_id = %s AND feedback_id IS NOT NULL GROUP BY rating""", (mid(),))
    return render_template("mechanic/ratings.html", me=me, rows=rows, dist={d["rating"]: d["n"] for d in dist})
