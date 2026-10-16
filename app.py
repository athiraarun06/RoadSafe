"""RoadSafe - Roadside Assistance Management System (Flask entry point)."""
from datetime import datetime

from flask import Flask, render_template

from config import Config
from db import close_db


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    app.teardown_appcontext(close_db)

    from routes.main import bp as main_bp
    from routes.customer import bp as customer_bp
    from routes.mechanic import bp as mechanic_bp
    from routes.admin import bp as admin_bp
    for bp in (main_bp, customer_bp, mechanic_bp, admin_bp):
        app.register_blueprint(bp)

    # ---- Jinja filters ------------------------------------------------
    @app.template_filter("money")
    def money(v):
        return "₹{:,.2f}".format(float(v or 0))

    @app.template_filter("dt")
    def dt(v, fmt="%d %b %Y, %I:%M %p"):
        return v.strftime(fmt) if isinstance(v, datetime) else ("-" if v is None else v)

    @app.template_filter("pretty")
    def pretty(v):
        return str(v or "").replace("_", " ").title()

    app.jinja_env.globals["STATUS_FLOW"] = [
        "PENDING", "ASSIGNED", "ACCEPTED", "ON_THE_WAY", "ARRIVED", "IN_PROGRESS", "COMPLETED"]

    @app.errorhandler(404)
    def not_found(_e):
        return render_template("error.html", code=404, message="That page could not be found."), 404

    @app.errorhandler(500)
    def server_error(_e):
        return render_template("error.html", code=500,
                               message="Something went wrong. Check that MySQL is running and the database is initialised."), 500

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=True)
