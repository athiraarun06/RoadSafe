-- =====================================================================
--  queries.sql : important DQL / DML / transaction examples
--  Run any block in MySQL Workbench or:  mysql -u root -p roadsafe < database/queries.sql
-- =====================================================================
USE roadsafe;

-- ---------------------------------------------------------------- JOINS
-- Q1  INNER JOIN (5 tables): open requests with customer, vehicle, service and place
SELECT r.request_id, c.full_name AS customer, v.registration_no, s.service_name, l.city, r.priority, r.status
FROM assistance_requests r
JOIN customers c ON c.customer_id = r.customer_id
JOIN vehicles  v ON v.vehicle_id  = r.vehicle_id
JOIN services  s ON s.service_id  = r.service_id
JOIN locations l ON l.location_id = r.location_id
WHERE r.status NOT IN ('COMPLETED','CANCELLED')
ORDER BY FIELD(r.priority,'EMERGENCY','HIGH','MEDIUM','LOW'), r.requested_at;

-- Q2  LEFT JOIN: customers who never requested help (anti-join)
SELECT c.customer_id, c.full_name
FROM customers c
LEFT JOIN assistance_requests r ON r.customer_id = c.customer_id
WHERE r.request_id IS NULL;

-- Q3  Many-to-many: services each mechanic can perform
SELECT m.full_name, GROUP_CONCAT(s.service_name ORDER BY s.service_name SEPARATOR ', ') AS services
FROM mechanics m
JOIN mechanic_services ms ON ms.mechanic_id = m.mechanic_id
JOIN services s ON s.service_id = ms.service_id
GROUP BY m.mechanic_id, m.full_name;

-- ------------------------------------------------------------ SUBQUERIES
-- Q4  Scalar subquery: mechanics rated above the overall average rating
SELECT m.full_name, fn_mechanic_rating(m.mechanic_id) AS rating
FROM mechanics m
WHERE fn_mechanic_rating(m.mechanic_id) > (SELECT AVG(rating) FROM feedback);

-- Q5  IN subquery: customers who had an EMERGENCY request
SELECT full_name, city FROM customers
WHERE customer_id IN (SELECT customer_id FROM assistance_requests WHERE priority = 'EMERGENCY');

-- Q6  Correlated subquery: each customer's most expensive bill
SELECT c.full_name,
       (SELECT MAX(p.total_amount)
        FROM payments p JOIN assistance_requests r ON r.request_id = p.request_id
        WHERE r.customer_id = c.customer_id) AS highest_bill
FROM customers c;

-- Q7  NOT EXISTS: completed jobs that still wait for feedback
SELECT r.request_id, r.completed_at
FROM assistance_requests r
WHERE r.status = 'COMPLETED'
  AND NOT EXISTS (SELECT 1 FROM feedback f WHERE f.request_id = r.request_id);

-- ------------------------------------------ AGGREGATES / GROUP BY / HAVING
-- Q8  Revenue and average ticket per service, only services with revenue above 1000
SELECT s.service_name, COUNT(*) AS paid_jobs, SUM(p.total_amount) AS revenue, ROUND(AVG(p.total_amount),2) AS avg_bill
FROM payments p
JOIN assistance_requests r ON r.request_id = p.request_id
JOIN services s ON s.service_id = r.service_id
WHERE p.payment_status = 'PAID'
GROUP BY s.service_id, s.service_name
HAVING SUM(p.total_amount) > 1000
ORDER BY revenue DESC;

-- Q9  Mechanics with at least 2 completed jobs and rating of 4.5 or better
SELECT m.full_name, COUNT(*) AS jobs, ROUND(AVG(f.rating),2) AS avg_rating
FROM mechanics m
JOIN request_assignments ra ON ra.mechanic_id = m.mechanic_id
JOIN feedback f ON f.request_id = ra.request_id
GROUP BY m.mechanic_id, m.full_name
HAVING COUNT(*) >= 2 AND AVG(f.rating) >= 4.5;

-- Q10 Requests per city and priority (two-level grouping with ROLLUP)
SELECT l.city, r.priority, COUNT(*) AS requests
FROM assistance_requests r JOIN locations l ON l.location_id = r.location_id
GROUP BY l.city, r.priority WITH ROLLUP;

-- Q11 Average response time (request -> mechanic accepted) in minutes, per mechanic
SELECT m.full_name, ROUND(AVG(TIMESTAMPDIFF(MINUTE, r.requested_at, ra.responded_at)),1) AS avg_minutes_to_accept
FROM request_assignments ra
JOIN assistance_requests r ON r.request_id = ra.request_id
JOIN mechanics m ON m.mechanic_id = ra.mechanic_id
WHERE ra.responded_at IS NOT NULL
GROUP BY m.mechanic_id, m.full_name;

-- Q12 Window function: rank mechanics by earnings inside each city
SELECT city, full_name, total_earnings,
       RANK() OVER (PARTITION BY city ORDER BY total_earnings DESC) AS city_rank
FROM vw_mechanic_performance;

-- ---------------------------------------------- VIEWS / FUNCTIONS / PROCS
-- Q13 Use the views
SELECT * FROM vw_service_demand ORDER BY revenue DESC;
SELECT * FROM vw_monthly_revenue ORDER BY month;
SELECT * FROM vw_mechanic_performance ORDER BY avg_rating DESC, completed_jobs DESC;

-- Q14 Stored function and procedures
SELECT fn_estimate_cost(5, 'EMERGENCY') AS towing_emergency_price;
CALL sp_recommend_mechanics(22);                       -- ranked mechanics for a pending request
CALL sp_revenue_report(CURDATE() - INTERVAL 90 DAY, CURDATE());

-- ------------------------------------------------------- DML EXAMPLES
-- Q15 INSERT / UPDATE / DELETE (DML)
INSERT INTO locations (address_line, city) VALUES ('Demo Street 1', 'Chennai');
UPDATE locations SET landmark = 'Near the demo bus stop' WHERE address_line = 'Demo Street 1';
DELETE FROM locations WHERE address_line = 'Demo Street 1';

-- ---------------------------------------------------- TRANSACTIONS (ACID)
-- Q16 Atomicity: either BOTH statements persist or NEITHER does
START TRANSACTION;
    UPDATE mechanics SET is_available = 0 WHERE mechanic_id = 8;
    SAVEPOINT after_availability;
    UPDATE mechanics SET experience_years = 255 WHERE mechanic_id = 8;   -- fails CHECK/range -> error
ROLLBACK;                                                               -- undo everything
SELECT mechanic_id, is_available FROM mechanics WHERE mechanic_id = 8;  -- unchanged (Atomicity)

-- Q17 Consistency: constraints and triggers reject invalid data
-- (each statement below is EXPECTED to fail)
-- INSERT INTO feedback (request_id, rating) VALUES (22, 6);                   -- CHECK rating 1..5
-- INSERT INTO feedback (request_id, rating) VALUES (22, 5);                   -- trigger: request not completed
-- UPDATE assistance_requests SET status = 'COMPLETED' WHERE request_id = 22;  -- trigger: invalid transition
-- UPDATE payments SET parts_charge = 0 WHERE payment_status = 'PAID';         -- trigger: paid is immutable

-- Q18 Isolation: lock a row so concurrent sessions queue up (open two sessions to try)
-- START TRANSACTION;
-- SELECT * FROM payments WHERE request_id = 20 FOR UPDATE;
-- UPDATE payments SET payment_status = 'PAID', payment_method = 'UPI' WHERE request_id = 20;
-- COMMIT;                                                                      -- Durability: persisted by InnoDB redo log

-- ---------------------------------------------------------- INDEX CHECK
-- Q19 Show that the status/priority index is used
EXPLAIN SELECT request_id FROM assistance_requests WHERE status = 'PENDING' AND priority = 'EMERGENCY';
SHOW INDEX FROM assistance_requests;
