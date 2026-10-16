"""End-to-end smoke test: run AFTER `python database/init_db.py`.
Usage:  python tests/smoke_test.py
It logs in as every role, opens every page and drives the complete workflow
(register -> vehicle -> request -> accept -> status updates -> complete -> pay -> rate).
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app import app  # noqa: E402

PW = "Password@123"
failures = []


def check(label, cond, extra=""):
    print(("  PASS " if cond else "  FAIL ") + label + (f"  {extra}" if not cond else ""))
    if not cond:
        failures.append(label)


def client():
    return app.test_client()


def login(c, role, email, pw=PW):
    return c.post("/login", data={"role": role, "email": email, "password": pw}, follow_redirects=True)


def page(c, url, expect=200):
    r = c.get(url, follow_redirects=True)
    ok = r.status_code == expect and b"Traceback" not in r.data and b"Something went wrong" not in r.data
    check(f"GET {url}", ok, f"-> {r.status_code}")
    return r


def text(r):
    return r.get_data(as_text=True)


print("== public pages")
c = client()
for u in ["/", "/login", "/register"]:
    page(c, u)
check("bad login rejected", b"Invalid email or password" in login(c, "customer", "aarav.sharma@example.com", "wrong").data)
check("protected page redirects", client().get("/admin/dashboard").status_code == 302)

print("== customer pages")
c = client()
check("customer login", b"Welcome back" in login(c, "customer", "aarav.sharma@example.com").data)
for u in ["/customer/dashboard", "/customer/profile", "/customer/vehicles", "/customer/vehicles/add", "/customer/vehicles/1/edit",
          "/customer/request/new", "/customer/requests", "/customer/requests?status=active", "/customer/requests/20",
          "/customer/requests/1", "/customer/bills", "/customer/history", "/customer/feedback"]:
    page(c, u)
check("customer cannot open admin", client().get("/admin/dashboard").status_code == 302)

print("== mechanic pages")
m = client()
check("mechanic login", b"Welcome back" in login(m, "mechanic", "murugan.selvam@roadsafe.in").data)
for u in ["/mechanic/dashboard", "/mechanic/requests", "/mechanic/requests?filter=all", "/mechanic/requests/20",
          "/mechanic/jobs", "/mechanic/earnings", "/mechanic/ratings"]:
    page(m, u)

print("== admin pages")
a = client()
check("admin login", b"Welcome back" in login(a, "admin", "admin@roadsafe.in").data)
for u in ["/admin/dashboard", "/admin/customers", "/admin/mechanics", "/admin/mechanics/new", "/admin/mechanics/1/edit",
          "/admin/services", "/admin/services/new", "/admin/services/1/edit", "/admin/requests", "/admin/requests?status=PENDING&priority=LOW",
          "/admin/requests/22", "/admin/requests/1", "/admin/payments", "/admin/payments?status=PENDING", "/admin/feedback",
          "/admin/feedback?rating=5", "/admin/reports", "/admin/reports?from=2026-01-01&to=2026-12-31"]:
    page(a, u)

print("== full workflow")
stamp = str(int(time.time()))[-7:]
w = client()
r = w.post("/register", data={"full_name": "Test Driver", "email": f"t{stamp}@example.com", "phone": f"90{stamp}",
                              "password": "secret1", "confirm": "secret1", "city": "Chennai"}, follow_redirects=True)
check("register", b"Account created" in r.data)
r = w.post("/register", data={"full_name": "Dup", "email": f"t{stamp}@example.com", "phone": "9999999999",
                              "password": "secret1", "confirm": "secret1"}, follow_redirects=True)
check("duplicate email rejected by UNIQUE", b"already exists" in r.data)
check("new customer login", b"Welcome back" in login(w, "customer", f"t{stamp}@example.com", "secret1").data)
r = w.post("/customer/vehicles/add", data={"registration_no": f"TN{stamp}", "vehicle_type": "CAR", "make": "Tata", "model": "Punch",
                                           "manufacture_year": "2023", "fuel_type": "PETROL", "color": "Green"}, follow_redirects=True)
check("add vehicle", b"Vehicle added" in r.data)
r = w.post("/customer/vehicles/add", data={"registration_no": f"TN{stamp}", "vehicle_type": "CAR", "make": "X", "model": "Y",
                                           "manufacture_year": "1900", "fuel_type": "PETROL"}, follow_redirects=True)
check("bad vehicle rejected (duplicate / CHECK)", b"Vehicle added" not in r.data)
vid = int(re.search(r"/customer/vehicles/(\d+)/edit", text(w.get("/customer/vehicles"))).group(1))
check("edit vehicle", b"Vehicle updated" in w.post(f"/customer/vehicles/{vid}/edit", data={
    "registration_no": f"TN{stamp}", "vehicle_type": "CAR", "make": "Tata", "model": "Punch EV", "manufacture_year": "2023",
    "fuel_type": "ELECTRIC", "color": "Green"}, follow_redirects=True).data)
req = {"vehicle_id": vid, "service_id": 1, "priority": "HIGH", "description": "Battery dead", "address": "Anna Salai",
       "city": "Chennai", "pincode": "600002", "landmark": "Spencer", "latitude": "13.06", "longitude": "80.27"}
r = w.post("/customer/request/new", data=req, follow_redirects=True)
check("request created + auto-assigned", b"assigned automatically" in r.data, text(r)[:0])
rid = int(re.search(r"Request #(\d+)", text(r)).group(1))
r = w.post("/customer/request/new", data=req, follow_redirects=True)
check("second open request for same vehicle blocked by trigger", b"already has an open" in r.data)
mech_name = re.search(r"<h5 class=\"mb-0\">([^<]+)</h5>", text(w.get(f"/customer/requests/{rid}"))).group(1)
email = mech_name.lower().replace(" ", ".") + "@roadsafe.in"
mm = client()
check(f"assigned mechanic logs in ({mech_name})", b"Welcome back" in login(mm, "mechanic", email).data)
check("mechanic accepts", b"Request accepted" in mm.post(f"/mechanic/requests/{rid}/respond", data={"decision": "accept"}, follow_redirects=True).data)
check("skipping a status is blocked", b"Invalid status change" in mm.post(f"/mechanic/requests/{rid}/status", data={"status": "IN_PROGRESS"}, follow_redirects=True).data)
for s in ["ON_THE_WAY", "ARRIVED", "IN_PROGRESS"]:
    check(f"status -> {s}", b"Status updated" in mm.post(f"/mechanic/requests/{rid}/status", data={"status": s}, follow_redirects=True).data)
check("cancel after start is refused", b"have not started can be cancelled" in w.post(f"/customer/requests/{rid}/cancel", follow_redirects=True).data)
check("complete service", b"Service completed" in mm.post(f"/mechanic/requests/{rid}/complete", data={"parts_charge": "250", "notes": "Replaced battery"}, follow_redirects=True).data)
r = w.get(f"/customer/requests/{rid}")
check("bill shows 562.50 + 250", "₹812.50" in text(r), re.findall(r"₹[\d,\.]+", text(r))[:5])
page(w, f"/customer/requests/{rid}/pay")
check("pay by UPI", b"Payment successful" in w.post(f"/customer/requests/{rid}/pay", data={"method": "UPI"}, follow_redirects=True).data)
check("double payment refused", b"already paid" in w.post(f"/customer/requests/{rid}/pay", data={"method": "CASH"}, follow_redirects=True).data)
check("feedback saved", b"Thank you for your feedback" in w.post(f"/customer/feedback/{rid}", data={"rating": "5", "comments": "Great"}, follow_redirects=True).data)
check("duplicate feedback refused", b"already submitted" in w.post(f"/customer/feedback/{rid}", data={"rating": "4"}, follow_redirects=True).data)
check("service history written by trigger", b"Replaced battery" in w.get("/customer/history").data)
check("mechanic earnings page", b"Earnings" in mm.get("/mechanic/earnings").data)

print("== reject -> auto reassign, admin manual assign, cancel")
w2 = client(); login(w2, "customer", "karthik.reddy@example.com")
r = a.post("/admin/requests/22/assign", data={"mode": "auto"}, follow_redirects=True)
check("admin auto-assign", b"assigned automatically" in r.data)
r = a.post("/admin/requests/22/assign", data={"mechanic_id": "1"}, follow_redirects=True)   # Murugan is in Chennai but supports tyre
check("admin manual reassign", b"Mechanic assigned" in r.data)
r = a.post("/admin/requests/22/assign", data={"mechanic_id": "99"}, follow_redirects=True)
check("assigning unknown mechanic fails cleanly", b"Mechanic assigned" not in r.data)
r = a.post("/admin/requests/22/cancel", follow_redirects=True)
check("admin cancel", b"Request cancelled" in r.data)

r = m.post("/mechanic/requests/20/respond", data={"decision": "reject", "reason": "Too far"}, follow_redirects=True)
check("mechanic rejects -> auto re-assigned to next mechanic", b"re-assigned to another mechanic" in r.data)
check("rejected request now belongs to someone else", b"Imran Khan" in a.get("/admin/requests/20").data)

print("== admin management")
check("toggle service", b"changed" in a.post("/admin/services/8/toggle", follow_redirects=True).data)
a.post("/admin/services/8/toggle")
r = a.post("/admin/mechanics/new", data={"full_name": "Test Mech", "email": f"m{stamp}@roadsafe.in", "phone": f"91{stamp}", "city": "Chennai",
                                        "experience_years": "3", "password": "secret1", "services": ["1", "2"]}, follow_redirects=True)
check("add mechanic + services (transaction)", b"Mechanic saved" in r.data)
check("add service", b"Service saved" in a.post("/admin/services/new", data={"service_name": f"Test svc {stamp}", "base_charge": "123", "icon": "bi-tools"}, follow_redirects=True).data)

print()
print("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}")
sys.exit(1 if failures else 0)
