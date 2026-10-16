-- =====================================================================
--  procedures.sql : stored FUNCTIONS and PROCEDURES
--  Every procedure that changes more than one table runs inside a
--  transaction (START TRANSACTION ... COMMIT) with an EXIT HANDLER that
--  ROLLBACKs on any error  ->  Atomicity + Consistency.
--  Row locks (SELECT ... FOR UPDATE) provide Isolation.
-- =====================================================================
USE roadsafe;

DROP FUNCTION  IF EXISTS fn_estimate_cost;
DROP FUNCTION  IF EXISTS fn_mechanic_rating;
DROP FUNCTION  IF EXISTS fn_active_jobs;
DROP FUNCTION  IF EXISTS fn_mechanic_score;
DROP PROCEDURE IF EXISTS sp_create_request;
DROP PROCEDURE IF EXISTS sp_recommend_mechanics;
DROP PROCEDURE IF EXISTS sp_assign_mechanic;
DROP PROCEDURE IF EXISTS sp_auto_assign_mechanic;
DROP PROCEDURE IF EXISTS sp_mechanic_respond;
DROP PROCEDURE IF EXISTS sp_update_status;
DROP PROCEDURE IF EXISTS sp_complete_service;
DROP PROCEDURE IF EXISTS sp_make_payment;
DROP PROCEDURE IF EXISTS sp_submit_feedback;
DROP PROCEDURE IF EXISTS sp_cancel_request;
DROP PROCEDURE IF EXISTS sp_revenue_report;

DELIMITER $$

-- ------------------------------------------------------------------
-- FUNCTION: service charge adjusted by emergency priority
-- ------------------------------------------------------------------
CREATE FUNCTION fn_estimate_cost(p_service_id INT, p_priority VARCHAR(10))
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_base DECIMAL(10,2);
    SELECT base_charge INTO v_base FROM services WHERE service_id = p_service_id;
    RETURN ROUND(COALESCE(v_base, 0) * CASE p_priority
                                          WHEN 'EMERGENCY' THEN 1.50
                                          WHEN 'HIGH'      THEN 1.25
                                          WHEN 'MEDIUM'    THEN 1.00
                                          ELSE 0.90 END, 2);
END$$

-- ------------------------------------------------------------------
-- FUNCTION: average customer rating of a mechanic (0 if never rated)
-- ------------------------------------------------------------------
CREATE FUNCTION fn_mechanic_rating(p_mechanic_id INT)
RETURNS DECIMAL(3,2)
READS SQL DATA
BEGIN
    DECLARE v_avg DECIMAL(3,2);
    SELECT ROUND(AVG(f.rating), 2) INTO v_avg
    FROM feedback f
    JOIN request_assignments ra ON ra.request_id = f.request_id
    WHERE ra.mechanic_id = p_mechanic_id;
    RETURN COALESCE(v_avg, 0.00);
END$$

-- ------------------------------------------------------------------
-- FUNCTION: number of jobs a mechanic is currently handling
-- ------------------------------------------------------------------
CREATE FUNCTION fn_active_jobs(p_mechanic_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_cnt INT;
    SELECT COUNT(*) INTO v_cnt
    FROM request_assignments ra
    JOIN assistance_requests r ON r.request_id = ra.request_id
    WHERE ra.mechanic_id = p_mechanic_id
      AND ra.response IN ('PENDING', 'ACCEPTED')
      AND r.status IN ('ASSIGNED','ACCEPTED','ON_THE_WAY','ARRIVED','IN_PROGRESS');
    RETURN v_cnt;
END$$

-- ------------------------------------------------------------------
-- FUNCTION: recommendation score (higher = better match)
--   rating (0-5 -> 0-100, unrated mechanics get a neutral 3.5)
--   + 30 bonus when mechanic is in the same city as the breakdown
--   + experience (max 10 points)  - 15 points per active job
-- ------------------------------------------------------------------
CREATE FUNCTION fn_mechanic_score(p_mechanic_id INT, p_city VARCHAR(60))
RETURNS DECIMAL(6,2)
READS SQL DATA
BEGIN
    DECLARE v_avg   DECIMAL(4,2);
    DECLARE v_cnt   INT;
    DECLARE v_exp   INT;
    DECLARE v_city  VARCHAR(60);
    SELECT AVG(f.rating), COUNT(f.feedback_id) INTO v_avg, v_cnt
    FROM feedback f JOIN request_assignments ra ON ra.request_id = f.request_id
    WHERE ra.mechanic_id = p_mechanic_id;
    IF v_cnt = 0 THEN SET v_avg = 3.5; END IF;
    SELECT experience_years, city INTO v_exp, v_city FROM mechanics WHERE mechanic_id = p_mechanic_id;
    RETURN ROUND(v_avg * 20
                 + IF(v_city = p_city, 30, 0)
                 + LEAST(v_exp, 10)
                 - fn_active_jobs(p_mechanic_id) * 15, 2);
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: create location + request atomically
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_create_request(
    IN p_customer_id INT, IN p_vehicle_id INT, IN p_service_id INT,
    IN p_priority VARCHAR(10), IN p_description VARCHAR(500),
    IN p_address VARCHAR(255), IN p_city VARCHAR(60), IN p_pincode VARCHAR(10),
    IN p_landmark VARCHAR(120), IN p_lat DECIMAL(9,6), IN p_lng DECIMAL(9,6),
    OUT p_request_id INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        INSERT INTO locations (address_line, city, pincode, landmark, latitude, longitude)
        VALUES (p_address, p_city, p_pincode, p_landmark, p_lat, p_lng);
        INSERT INTO assistance_requests (customer_id, vehicle_id, service_id, location_id, priority, description)
        VALUES (p_customer_id, p_vehicle_id, p_service_id, LAST_INSERT_ID(), p_priority, p_description);
        SET p_request_id = LAST_INSERT_ID();
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: top 5 recommended mechanics for a request
-- (candidates view already filters: available, active, supports the service,
--  fewer than 3 active jobs, has not rejected this request)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_recommend_mechanics(IN p_request_id INT)
BEGIN
    SELECT *
    FROM vw_mechanic_candidates
    WHERE request_id = p_request_id
    ORDER BY score DESC, avg_rating DESC, active_jobs ASC
    LIMIT 5;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: assign (or re-assign) a request to a mechanic
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_assign_mechanic(IN p_request_id INT, IN p_mechanic_id INT, IN p_assigned_by VARCHAR(10))
BEGIN
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        SELECT status INTO v_status FROM assistance_requests WHERE request_id = p_request_id FOR UPDATE;
        IF v_status IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found';
        END IF;
        IF v_status NOT IN ('PENDING','ASSIGNED','ACCEPTED') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A request that is already under way or closed cannot be (re)assigned';
        END IF;
        -- insert, or re-assign when the request already has an assignment row
        INSERT INTO request_assignments (request_id, mechanic_id, assigned_by)
        VALUES (p_request_id, p_mechanic_id, p_assigned_by)
        ON DUPLICATE KEY UPDATE mechanic_id = VALUES(mechanic_id), assigned_by = VALUES(assigned_by),
                                response = 'PENDING', assigned_at = NOW(),
                                responded_at = NULL, rejection_reason = NULL;
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: pick the best-scoring mechanic and assign automatically
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_auto_assign_mechanic(IN p_request_id INT, OUT p_mechanic_id INT)
BEGIN
    SET p_mechanic_id = NULL;
    SELECT mechanic_id INTO p_mechanic_id
    FROM vw_mechanic_candidates
    WHERE request_id = p_request_id
    ORDER BY score DESC, avg_rating DESC, active_jobs ASC
    LIMIT 1;
    IF p_mechanic_id IS NOT NULL THEN
        CALL sp_assign_mechanic(p_request_id, p_mechanic_id, 'SYSTEM');
    END IF;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: mechanic accepts or rejects an assignment
--   (trigger trg_assign_after_update then moves the request status)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_mechanic_respond(IN p_request_id INT, IN p_mechanic_id INT,
                                     IN p_accept TINYINT, IN p_reason VARCHAR(255))
BEGIN
    DECLARE v_resp VARCHAR(10) DEFAULT NULL;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        SELECT response INTO v_resp FROM request_assignments
        WHERE request_id = p_request_id AND mechanic_id = p_mechanic_id FOR UPDATE;
        IF v_resp IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This request is not assigned to you';
        END IF;
        IF v_resp <> 'PENDING' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You have already responded to this request';
        END IF;
        UPDATE request_assignments
        SET response         = IF(p_accept = 1, 'ACCEPTED', 'REJECTED'),
            responded_at     = NOW(),
            rejection_reason = IF(p_accept = 1, NULL, p_reason)
        WHERE request_id = p_request_id AND mechanic_id = p_mechanic_id;
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: mechanic moves the job ON_THE_WAY -> ARRIVED -> IN_PROGRESS
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_update_status(IN p_request_id INT, IN p_mechanic_id INT, IN p_new_status VARCHAR(20))
BEGIN
    DECLARE v_resp VARCHAR(10) DEFAULT NULL;
    IF p_new_status NOT IN ('ON_THE_WAY','ARRIVED','IN_PROGRESS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mechanics can only set ON_THE_WAY, ARRIVED or IN_PROGRESS here';
    END IF;
    SELECT response INTO v_resp FROM request_assignments
    WHERE request_id = p_request_id AND mechanic_id = p_mechanic_id;
    IF v_resp IS NULL OR v_resp <> 'ACCEPTED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Accept the request before updating its status';
    END IF;
    UPDATE assistance_requests
    SET status = p_new_status
    WHERE request_id = p_request_id;   -- trigger validates the transition
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: complete a job -> bill + COMPLETED status in ONE transaction
--   (trigger trg_req_after_update writes service_history)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_complete_service(IN p_request_id INT, IN p_mechanic_id INT,
                                     IN p_parts_charge DECIMAL(10,2), IN p_notes VARCHAR(500))
BEGIN
    DECLARE v_status   VARCHAR(20) DEFAULT NULL;
    DECLARE v_service  INT;
    DECLARE v_priority VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        SELECT r.status, r.service_id, r.priority INTO v_status, v_service, v_priority
        FROM assistance_requests r
        JOIN request_assignments ra ON ra.request_id = r.request_id
        WHERE r.request_id = p_request_id AND ra.mechanic_id = p_mechanic_id AND ra.response = 'ACCEPTED'
        FOR UPDATE;
        IF v_status IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found or not accepted by you';
        END IF;
        IF v_status <> 'IN_PROGRESS' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Start the work (IN_PROGRESS) before completing the service';
        END IF;
        INSERT INTO payments (request_id, service_charge, parts_charge)
        VALUES (p_request_id, fn_estimate_cost(v_service, v_priority), COALESCE(p_parts_charge, 0));
        UPDATE assistance_requests
        SET status = 'COMPLETED', completed_at = NOW(), resolution_notes = p_notes
        WHERE request_id = p_request_id;
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: simulated payment (Cash / UPI / Card)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_make_payment(IN p_request_id INT, IN p_customer_id INT,
                                 IN p_method VARCHAR(10), OUT p_txn_ref VARCHAR(40))
BEGIN
    DECLARE v_status VARCHAR(10) DEFAULT NULL;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        SELECT p.payment_status INTO v_status
        FROM payments p JOIN assistance_requests r ON r.request_id = p.request_id
        WHERE p.request_id = p_request_id AND r.customer_id = p_customer_id
        FOR UPDATE;
        IF v_status IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No bill found for this request';
        END IF;
        IF v_status = 'PAID' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This bill is already paid';
        END IF;
        SET p_txn_ref = CONCAT(UPPER(p_method), DATE_FORMAT(NOW(), '%y%m%d'),
                               LPAD(p_request_id, 5, '0'), LPAD(FLOOR(RAND() * 10000), 4, '0'));
        UPDATE payments
        SET payment_status = 'PAID', payment_method = p_method,
            transaction_ref = p_txn_ref, paid_at = NOW()
        WHERE request_id = p_request_id;
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: customer feedback (one per completed request)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_submit_feedback(IN p_request_id INT, IN p_customer_id INT,
                                    IN p_rating TINYINT, IN p_comments VARCHAR(500))
BEGIN
    IF NOT EXISTS (SELECT 1 FROM assistance_requests
                   WHERE request_id = p_request_id AND customer_id = p_customer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found';
    END IF;
    IF EXISTS (SELECT 1 FROM feedback WHERE request_id = p_request_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Feedback was already submitted for this request';
    END IF;
    INSERT INTO feedback (request_id, rating, comments) VALUES (p_request_id, p_rating, p_comments);
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: cancel a request that has not started yet
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_cancel_request(IN p_request_id INT, IN p_customer_id INT)
BEGIN
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    START TRANSACTION;
        SELECT status INTO v_status FROM assistance_requests
        WHERE request_id = p_request_id AND customer_id = p_customer_id FOR UPDATE;
        IF v_status IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found';
        END IF;
        IF v_status NOT IN ('PENDING','ASSIGNED','ACCEPTED') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only requests that have not started can be cancelled';
        END IF;
        UPDATE assistance_requests SET status = 'CANCELLED' WHERE request_id = p_request_id;
    COMMIT;
END$$

-- ------------------------------------------------------------------
-- PROCEDURE: revenue report per service for a date range
--   (JOIN + GROUP BY + HAVING + aggregate functions)
-- ------------------------------------------------------------------
CREATE PROCEDURE sp_revenue_report(IN p_from DATE, IN p_to DATE)
BEGIN
    SELECT s.service_name,
           COUNT(r.request_id)               AS total_requests,
           SUM(r.status = 'COMPLETED')       AS completed,
           COALESCE(SUM(p.total_amount), 0)  AS revenue,
           ROUND(AVG(p.total_amount), 2)     AS avg_bill
    FROM services s
    JOIN assistance_requests r ON r.service_id = s.service_id
    LEFT JOIN payments p ON p.request_id = r.request_id AND p.payment_status = 'PAID'
    WHERE DATE(r.requested_at) BETWEEN p_from AND p_to
    GROUP BY s.service_id, s.service_name
    HAVING COUNT(r.request_id) > 0
    ORDER BY revenue DESC;
END$$

DELIMITER ;
