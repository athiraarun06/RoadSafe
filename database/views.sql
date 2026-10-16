-- =====================================================================
--  views.sql : reusable read models used by the Flask app
-- =====================================================================
USE roadsafe;

-- Everything about a request in one row (JOINs across 8 tables)
CREATE OR REPLACE VIEW vw_request_details AS
SELECT r.request_id, r.status, r.priority, r.description, r.resolution_notes,
       r.requested_at, r.started_at, r.completed_at,
       c.customer_id, c.full_name AS customer_name, c.phone AS customer_phone,
       v.vehicle_id, v.registration_no, CONCAT(v.make, ' ', v.model) AS vehicle_name, v.vehicle_type,
       s.service_id, s.service_name, s.icon AS service_icon,
       fn_estimate_cost(s.service_id, r.priority) AS estimated_cost,
       l.address_line, l.city, l.pincode, l.landmark, l.latitude, l.longitude,
       ra.mechanic_id, m.full_name AS mechanic_name, m.phone AS mechanic_phone,
       ra.response AS assignment_response, ra.assigned_by, ra.assigned_at, ra.rejection_reason,
       IF(ra.mechanic_id IS NULL, NULL, fn_mechanic_rating(ra.mechanic_id)) AS mechanic_rating,
       p.payment_id, p.service_charge, p.parts_charge, p.total_amount,
       p.payment_status, p.payment_method, p.transaction_ref, p.paid_at,
       f.feedback_id, f.rating, f.comments AS feedback_comments
FROM assistance_requests r
JOIN customers c  ON c.customer_id = r.customer_id
JOIN vehicles  v  ON v.vehicle_id  = r.vehicle_id
JOIN services  s  ON s.service_id  = r.service_id
JOIN locations l  ON l.location_id = r.location_id
LEFT JOIN request_assignments ra ON ra.request_id = r.request_id
LEFT JOIN mechanics m  ON m.mechanic_id = ra.mechanic_id
LEFT JOIN payments  p  ON p.request_id  = r.request_id
LEFT JOIN feedback  f  ON f.request_id  = r.request_id;

-- Eligible mechanics per request (the engine behind auto-recommendation)
CREATE OR REPLACE VIEW vw_mechanic_candidates AS
SELECT r.request_id, m.mechanic_id, m.full_name, m.phone, m.city, m.experience_years,
       fn_mechanic_rating(m.mechanic_id)           AS avg_rating,
       fn_active_jobs(m.mechanic_id)               AS active_jobs,
       (m.city = l.city)                           AS same_city,
       fn_mechanic_score(m.mechanic_id, l.city)    AS score
FROM assistance_requests r
JOIN locations l          ON l.location_id = r.location_id
JOIN mechanic_services ms ON ms.service_id = r.service_id
JOIN mechanics m          ON m.mechanic_id = ms.mechanic_id
WHERE r.status IN ('PENDING','ASSIGNED','ACCEPTED')
  AND m.is_available = 1
  AND m.is_active    = 1
  AND fn_active_jobs(m.mechanic_id) < 3
  AND m.mechanic_id NOT IN (SELECT ra.mechanic_id FROM request_assignments ra
                            WHERE ra.request_id = r.request_id AND ra.response = 'REJECTED');

-- Mechanic scoreboard (LEFT JOIN + GROUP BY + aggregates)
CREATE OR REPLACE VIEW vw_mechanic_performance AS
SELECT m.mechanic_id, m.full_name, m.email, m.phone, m.city, m.experience_years,
       m.is_available, m.is_active,
       fn_mechanic_rating(m.mechanic_id)  AS avg_rating,
       fn_active_jobs(m.mechanic_id)      AS active_jobs,
       COUNT(DISTINCT sh.history_id)      AS completed_jobs,
       COALESCE(SUM(pp.total_amount), 0)  AS total_earnings
FROM mechanics m
LEFT JOIN service_history sh ON sh.mechanic_id = m.mechanic_id
LEFT JOIN payments pp ON pp.request_id = sh.request_id AND pp.payment_status = 'PAID'
GROUP BY m.mechanic_id, m.full_name, m.email, m.phone, m.city, m.experience_years,
         m.is_available, m.is_active;

-- Completed jobs with context (service history page)
CREATE OR REPLACE VIEW vw_service_history_details AS
SELECT sh.history_id, sh.request_id, sh.completed_at, sh.duration_minutes, sh.total_cost, sh.work_summary,
       r.customer_id, c.full_name AS customer_name,
       v.registration_no, CONCAT(v.make, ' ', v.model) AS vehicle_name,
       s.service_name, s.icon AS service_icon, r.priority,
       sh.mechanic_id, m.full_name AS mechanic_name,
       l.city, l.address_line,
       p.payment_status, p.payment_method,
       f.rating, f.comments AS feedback_comments
FROM service_history sh
JOIN assistance_requests r ON r.request_id = sh.request_id
JOIN customers c ON c.customer_id = r.customer_id
JOIN vehicles  v ON v.vehicle_id  = r.vehicle_id
JOIN services  s ON s.service_id  = r.service_id
JOIN locations l ON l.location_id = r.location_id
JOIN mechanics m ON m.mechanic_id = sh.mechanic_id
LEFT JOIN payments p ON p.request_id = sh.request_id
LEFT JOIN feedback f ON f.request_id = sh.request_id;

-- Demand and revenue per service
CREATE OR REPLACE VIEW vw_service_demand AS
SELECT s.service_id, s.service_name,
       COUNT(r.request_id)                         AS total_requests,
       COALESCE(SUM(r.status = 'COMPLETED'), 0)    AS completed_requests,
       COALESCE(SUM(p.total_amount), 0)            AS revenue
FROM services s
LEFT JOIN assistance_requests r ON r.service_id = s.service_id
LEFT JOIN payments p ON p.request_id = r.request_id AND p.payment_status = 'PAID'
GROUP BY s.service_id, s.service_name;

-- Revenue per month (paid bills only)
CREATE OR REPLACE VIEW vw_monthly_revenue AS
SELECT DATE_FORMAT(paid_at, '%Y-%m') AS month,
       COUNT(*)                      AS payments_count,
       SUM(total_amount)             AS revenue
FROM payments
WHERE payment_status = 'PAID'
GROUP BY DATE_FORMAT(paid_at, '%Y-%m');

-- Earnings per mechanic per month
CREATE OR REPLACE VIEW vw_mechanic_monthly_earnings AS
SELECT ra.mechanic_id, DATE_FORMAT(p.paid_at, '%Y-%m') AS month,
       COUNT(*) AS jobs, SUM(p.total_amount) AS earned
FROM payments p
JOIN request_assignments ra ON ra.request_id = p.request_id
WHERE p.payment_status = 'PAID'
GROUP BY ra.mechanic_id, DATE_FORMAT(p.paid_at, '%Y-%m');
