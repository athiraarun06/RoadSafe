# RoadSafe – Roadside Assistance Management System

A DBMS college project: customers request roadside help, the database recommends the best mechanic, the mechanic
works the job through a status workflow, the customer pays and rates, and the history is archived automatically.

**Stack:** Python Flask · MySQL 8 · HTML/CSS/JS · Bootstrap 5 · Chart.js (no React/Node/ORM – every query is plain SQL).

## 1. Run it

```bash
# 1. MySQL 8 must be running. Then install Python packages
pip install -r requirements.txt

# 2. Tell the app how to reach MySQL (defaults: localhost, user root, empty password)
#    Windows PowerShell:  $env:DB_PASSWORD="yourpassword"
#    Linux / macOS:       export DB_PASSWORD=yourpassword
#    Optional: DB_HOST, DB_PORT, DB_USER, DB_NAME, SECRET_KEY

# 3. Create the database (schema, procedures, views, triggers, sample data)
python database/init_db.py

# 4. Start the website
python app.py            # http://127.0.0.1:5000

# 5. (optional) end-to-end self test – run on a freshly initialised database
python tests/smoke_test.py
```

`init_db.py` drops and recreates the `roadsafe` database every time. Use `--no-data` for an empty system.
You can also load the SQL files manually in this order: `schema.sql → procedures.sql → views.sql → triggers.sql → sample_data.sql`
(sample data contains the placeholder `__HASH__` for password hashes, which `init_db.py` fills in – so use the script).

### Demo accounts (password for all: `Password@123`)
| Role | Login |
|---|---|
| Admin | `admin@roadsafe.in` |
| Customer | `aarav.sharma@example.com` (also priya.nair, rohan.mehta, ananya.iyer, karthik.reddy, sneha.kulkarni `@example.com`) |
| Mechanic | `murugan.selvam@roadsafe.in` (also imran.khan, ravi.kumar, deepak.gowda, sanjay.patil, vikram.joshi, srinivas.rao, farhan.ali `@roadsafe.in`) |

Sample data already contains: 18 completed jobs (17 paid), 1 unpaid bill, 1 cancelled request, one request waiting for a mechanic to
accept (Murugan), one emergency job in progress (Sanjay) and one unassigned request in the admin queue (#22).

## 2. Workflow

```
Customer registers → adds vehicle → requests help (service, location, priority)
   → system scores mechanics and auto-assigns the best one          [sp_create_request, sp_auto_assign_mechanic]
   → mechanic ACCEPTS (or rejects → next best mechanic is assigned) [sp_mechanic_respond]
   → ON_THE_WAY → ARRIVED → IN_PROGRESS                             [sp_update_status + status trigger]
   → mechanic completes: bill is created, status COMPLETED          [sp_complete_service]  ← one transaction
   → trigger writes service_history automatically
   → customer pays by Cash / UPI / Card (simulated)                 [sp_make_payment]
   → customer rates 1–5 and comments                                [sp_submit_feedback]
```
Statuses: `PENDING, ASSIGNED, ACCEPTED, ON_THE_WAY, ARRIVED, IN_PROGRESS, COMPLETED, CANCELLED`.
Priorities: `LOW (−10%), MEDIUM, HIGH (+25%), EMERGENCY (+50%)` on the service charge (`fn_estimate_cost`).

**Mechanic recommendation** (`vw_mechanic_candidates`, `fn_mechanic_score`): only mechanics who are *online*, *active*, offer the
requested service, have < 3 active jobs and did not reject this request are eligible. Score = `rating × 20` (unrated = 3.5)
`+ 30` if same city `+ experience (max 10) − 15 × active jobs`.

## 3. Project structure

```
roadsafe/
├── app.py                 Flask app factory, filters, error pages
├── config.py              DB settings (env variables)
├── db.py                  PyMySQL helpers: query(), execute(), call_proc()
├── auth.py                role_required decorator
├── routes/                main.py · customer.py · mechanic.py · admin.py (blueprints)
├── templates/             base layout, shared macros, customer/ mechanic/ admin/ pages
├── static/                css/style.css · js/app.js
├── database/
│   ├── schema.sql         DDL – 12 tables, PK/FK/UNIQUE/NOT NULL/CHECK, indexes
│   ├── procedures.sql     4 stored functions + 11 stored procedures
│   ├── views.sql          8 views
│   ├── triggers.sql       10 triggers
│   ├── sample_data.sql    fictional demo data (DML)
│   ├── queries.sql        19 documented queries: joins, subqueries, GROUP BY/HAVING, window, transactions
│   └── init_db.py         builds the whole database
├── tests/smoke_test.py    end-to-end test of every page and the full workflow
├── requirements.txt
└── README.md
```

## 4. Database design

### Relationships
| Relationship | Implemented by |
|---|---|
| Customer 1:N Vehicles | `vehicles.customer_id` FK |
| Customer 1:N Requests, Vehicle 1:N Requests | `assistance_requests.customer_id`, `vehicle_id` + **composite FK `(vehicle_id, customer_id)`** so a vehicle must belong to the requesting customer |
| Mechanic M:N Services | junction table `mechanic_services` (composite PK) |
| Request 1:1 Location | `assistance_requests.location_id` (UNIQUE) |
| Request 1:1 Assignment / Payment / Feedback / Service history | `request_id` UNIQUE FK in each child table |
| Mechanic 1:N Assignments / History | `mechanic_id` FK |

### Why it is in 3NF
* **1NF** – every column is atomic; no repeating groups (a mechanic's services are rows in `mechanic_services`, not a comma list).
* **2NF** – tables with composite keys (`mechanic_services`) have no non-key attributes, so no partial dependencies.
* **3NF** – no transitive dependencies: customer data lives only in `customers`, vehicle data in `vehicles`, price in `services`,
  address in `locations`. `feedback` has no customer/mechanic columns (both are derived through `request → assignment`).
  The average rating, active-job count and bill estimate are **not stored**; they are computed by functions/views.
  `payments.total_amount` is a `GENERATED ... STORED` column (database-maintained, can never disagree with its parts).
* `service_history.duration_minutes` and `total_cost` are *deliberate audit snapshots* written once by a trigger so the archive
  cannot change when later data changes.

### DBMS concepts – where to find them
| Concept | Where |
|---|---|
| DDL | `schema.sql` (CREATE, constraints, indexes) |
| DML | `sample_data.sql`, `queries.sql` Q15, every route that inserts/updates |
| DQL / joins | `vw_request_details` (8-table join), `queries.sql` Q1–Q3 |
| Subqueries | Q4–Q7, `vw_mechanic_candidates` (NOT IN), triggers (EXISTS) |
| Aggregates, GROUP BY, HAVING | Q8–Q11, `sp_revenue_report`, Admin → Reports |
| Window function / ROLLUP | Q12, Q10 |
| Views | `views.sql` (8 views used by the Flask pages) |
| Stored functions | `fn_estimate_cost`, `fn_mechanic_rating`, `fn_active_jobs`, `fn_mechanic_score` |
| Stored procedures | `procedures.sql` – create, recommend, assign, respond, status, complete, pay, feedback, cancel, report |
| Triggers | status state-machine, auto service history, assignment validation, request/status sync, payment immutability, feedback rules |
| Transactions / ACID | procedures use `START TRANSACTION … COMMIT` with an `EXIT HANDLER` that `ROLLBACK`s; `FOR UPDATE` row locks; `queries.sql` Q16–Q18; admin “add mechanic + services” is one transaction in Python |
| Indexes | `schema.sql` (status/priority, city/availability, FK columns); `EXPLAIN` in Q19 |
| Constraints | PK, FK (incl. composite), UNIQUE, NOT NULL, CHECK (rating 1–5, year, charges, coordinates, time order) |

### Triggers
| Trigger | Rule |
|---|---|
| `trg_req_before_insert` | one open request per vehicle; only active services |
| `trg_req_before_update` | status state machine (e.g. `PENDING → COMPLETED` is rejected) + auto `started_at` / `completed_at` |
| `trg_req_after_update` | on `COMPLETED` → insert `service_history` automatically |
| `trg_assign_before_insert/update` | mechanic must offer the service and be active |
| `trg_assign_after_insert/update` | assignment events move the request to ASSIGNED / ACCEPTED / PENDING |
| `trg_payment_before_insert` | bill only for in-progress/completed work |
| `trg_payment_before_update` | paid payments are immutable |
| `trg_feedback_before_insert` | feedback only for completed services |

## 5. Pages
Landing · Login/Register · **Customer:** dashboard, profile, vehicles (add/edit/delete), request assistance (live price estimate,
geolocation), tracking with progress bar and auto-refresh, bills, simulated payment, service history, feedback ·
**Mechanic:** dashboard with online/offline switch, assigned requests, accept/reject, status updates, completion form,
completed jobs, earnings chart, ratings · **Admin:** dashboard with 3 charts and unassigned queue, customers, mechanics (add/edit services),
services, requests (filter, recommend/assign/reassign/auto-assign/cancel), payments, feedback, reports with date range.

## 6. Notes
* Passwords are hashed with Werkzeug (PBKDF2). Change `SECRET_KEY` for any real deployment.
* Payment is a simulation: only method + generated reference are stored; card/UPI inputs are never sent to the database.
* Bootstrap, Bootstrap Icons, Chart.js and Google Fonts load from CDNs, so the browser needs internet access.
* Deleting vehicles with requests, and blocking users, are handled by FK constraints / `is_active` flags rather than deleting history.
