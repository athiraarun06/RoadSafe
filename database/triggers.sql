-- =====================================================================
--  triggers.sql : business rules enforced inside the database
--  The database refuses invalid data no matter which client sends it.
-- =====================================================================
USE roadsafe;

DROP TRIGGER IF EXISTS trg_req_before_insert;
DROP TRIGGER IF EXISTS trg_req_before_update;
DROP TRIGGER IF EXISTS trg_req_after_update;
DROP TRIGGER IF EXISTS trg_assign_before_insert;
DROP TRIGGER IF EXISTS trg_assign_before_update;
DROP TRIGGER IF EXISTS trg_assign_after_insert;
DROP TRIGGER IF EXISTS trg_assign_after_update;
DROP TRIGGER IF EXISTS trg_payment_before_insert;
DROP TRIGGER IF EXISTS trg_payment_before_update;
DROP TRIGGER IF EXISTS trg_feedback_before_insert;

DELIMITER $$

-- 1. One open request per vehicle, and only active services can be requested
CREATE TRIGGER trg_req_before_insert BEFORE INSERT ON assistance_requests
FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM assistance_requests
               WHERE vehicle_id = NEW.vehicle_id AND status NOT IN ('COMPLETED','CANCELLED')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This vehicle already has an open assistance request';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM services WHERE service_id = NEW.service_id AND is_active = 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This service is currently not available';
    END IF;
END$$

-- 2. Status workflow state machine + automatic timestamps
CREATE TRIGGER trg_req_before_update BEFORE UPDATE ON assistance_requests
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(100);
    IF NEW.status <> OLD.status THEN
        IF NOT (   (OLD.status = 'PENDING'     AND NEW.status IN ('ASSIGNED','CANCELLED'))
                OR (OLD.status = 'ASSIGNED'    AND NEW.status IN ('PENDING','ACCEPTED','CANCELLED'))
                OR (OLD.status = 'ACCEPTED'    AND NEW.status IN ('ASSIGNED','ON_THE_WAY','CANCELLED'))
                OR (OLD.status = 'ON_THE_WAY'  AND NEW.status IN ('ARRIVED','CANCELLED'))
                OR (OLD.status = 'ARRIVED'     AND NEW.status IN ('IN_PROGRESS','CANCELLED'))
                OR (OLD.status = 'IN_PROGRESS' AND NEW.status = 'COMPLETED')) THEN
            SET v_msg = CONCAT('Invalid status change: ', OLD.status, ' to ', NEW.status);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
        IF NEW.status = 'IN_PROGRESS' AND NEW.started_at IS NULL THEN
            SET NEW.started_at = NOW();
        END IF;
        IF NEW.status = 'COMPLETED' AND NEW.completed_at IS NULL THEN
            SET NEW.completed_at = NOW();
        END IF;
    END IF;
END$$

-- 3. Completed request -> automatic service_history record
CREATE TRIGGER trg_req_after_update AFTER UPDATE ON assistance_requests
FOR EACH ROW
BEGIN
    IF NEW.status = 'COMPLETED' AND OLD.status <> 'COMPLETED' THEN
        INSERT INTO service_history (request_id, mechanic_id, completed_at, duration_minutes, total_cost, work_summary)
        SELECT NEW.request_id, ra.mechanic_id, NEW.completed_at,
               TIMESTAMPDIFF(MINUTE, NEW.requested_at, NEW.completed_at),
               COALESCE(p.total_amount, 0), NEW.resolution_notes
        FROM request_assignments ra
        LEFT JOIN payments p ON p.request_id = ra.request_id
        WHERE ra.request_id = NEW.request_id;
    END IF;
END$$

-- 4/5. A mechanic may only be assigned a service he/she supports (and must be active)
CREATE TRIGGER trg_assign_before_insert BEFORE INSERT ON request_assignments
FOR EACH ROW
BEGIN
    IF NOT EXISTS (SELECT 1 FROM mechanic_services ms
                   JOIN assistance_requests r ON r.service_id = ms.service_id
                   WHERE r.request_id = NEW.request_id AND ms.mechanic_id = NEW.mechanic_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This mechanic does not provide the requested service';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mechanics WHERE mechanic_id = NEW.mechanic_id AND is_active = 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This mechanic account is deactivated';
    END IF;
END$$

CREATE TRIGGER trg_assign_before_update BEFORE UPDATE ON request_assignments
FOR EACH ROW
BEGIN
    IF NEW.mechanic_id <> OLD.mechanic_id THEN
        IF NOT EXISTS (SELECT 1 FROM mechanic_services ms
                       JOIN assistance_requests r ON r.service_id = ms.service_id
                       WHERE r.request_id = NEW.request_id AND ms.mechanic_id = NEW.mechanic_id) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This mechanic does not provide the requested service';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM mechanics WHERE mechanic_id = NEW.mechanic_id AND is_active = 1) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This mechanic account is deactivated';
        END IF;
    END IF;
END$$

-- 6/7. Assignment events keep the request status in sync
CREATE TRIGGER trg_assign_after_insert AFTER INSERT ON request_assignments
FOR EACH ROW
BEGIN
    IF NEW.response = 'PENDING' THEN
        UPDATE assistance_requests SET status = 'ASSIGNED' WHERE request_id = NEW.request_id;
    END IF;
END$$

CREATE TRIGGER trg_assign_after_update AFTER UPDATE ON request_assignments
FOR EACH ROW
BEGIN
    IF NEW.response <> OLD.response OR NEW.mechanic_id <> OLD.mechanic_id THEN
        UPDATE assistance_requests
        SET status = CASE NEW.response WHEN 'ACCEPTED' THEN 'ACCEPTED'
                                       WHEN 'REJECTED' THEN 'PENDING'
                                       ELSE 'ASSIGNED' END
        WHERE request_id = NEW.request_id;
    END IF;
END$$

-- 8. A bill can only be raised for work that is in progress / done
CREATE TRIGGER trg_payment_before_insert BEFORE INSERT ON payments
FOR EACH ROW
BEGIN
    IF (SELECT status FROM assistance_requests WHERE request_id = NEW.request_id)
       NOT IN ('IN_PROGRESS','COMPLETED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A bill can only be created for work that is in progress or completed';
    END IF;
END$$

-- 9. Paid payments are immutable (audit / durability)
CREATE TRIGGER trg_payment_before_update BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    IF OLD.payment_status = 'PAID' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A paid payment cannot be modified';
    END IF;
END$$

-- 10. Feedback only for completed services
CREATE TRIGGER trg_feedback_before_insert BEFORE INSERT ON feedback
FOR EACH ROW
BEGIN
    IF NOT EXISTS (SELECT 1 FROM assistance_requests
                   WHERE request_id = NEW.request_id AND status = 'COMPLETED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Feedback can only be given for completed services';
    END IF;
END$$

DELIMITER ;
