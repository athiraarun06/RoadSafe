"""Role-based access decorator."""
from functools import wraps
from flask import flash, redirect, session, url_for


def role_required(role):
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if session.get("role") != role:
                flash("Please log in with the correct account to continue.", "warning")
                return redirect(url_for("main.login"))
            return view(*args, **kwargs)
        return wrapper
    return decorator
