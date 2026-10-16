-- =====================================================================
--  sample_data.sql : fictional demo data (DML)
--  '__HASH__' is replaced by init_db.py with a real password hash of
--  "Password@123".  All demo accounts use that password.
--  History is created through the real triggers / procedures, so the
--  workflow rules are exercised while loading.
-- =====================================================================
USE roadsafe;

INSERT INTO admins (full_name, email, password_hash) VALUES
('RoadSafe Admin', 'admin@roadsafe.in', '__HASH__');

INSERT INTO services (service_name, description, base_charge, icon) VALUES
('Battery Assistance',  'Jump-start or on-site battery replacement',        450.00, 'bi-battery-charging'),
('Flat Tyre',           'Tyre change, puncture repair or inflation',        350.00, 'bi-record-circle'),
('Fuel Delivery',       'Emergency petrol / diesel delivered to you',       300.00, 'bi-fuel-pump'),
('Engine Breakdown',    'Diagnosis and on-road engine repair',              900.00, 'bi-gear-wide-connected'),
('Towing',              'Flatbed or hook towing to the nearest garage',    1500.00, 'bi-truck'),
('Accident Assistance', 'Recovery, first response and documentation help', 2000.00, 'bi-exclamation-triangle'),
('Lockout Assistance',  'Unlock a vehicle when the keys are locked inside',  400.00, 'bi-key'),
('General Breakdown',   'Any other fault that stops you from driving',       500.00, 'bi-tools');

INSERT INTO customers (full_name, email, phone, password_hash, address, city) VALUES
('Aarav Sharma',   'aarav.sharma@example.com',   '9876500001', '__HASH__', '14, Lake View Road, Adyar',        'Chennai'),
('Priya Nair',     'priya.nair@example.com',     '9876500002', '__HASH__', '221, 5th Cross, Indiranagar',      'Bengaluru'),
('Rohan Mehta',    'rohan.mehta@example.com',    '9876500003', '__HASH__', 'B-12, Baner Heights, Baner',       'Pune'),
('Ananya Iyer',    'ananya.iyer@example.com',    '9876500004', '__HASH__', '7, Besant Avenue, Besant Nagar',   'Chennai'),
('Karthik Reddy',  'karthik.reddy@example.com',  '9876500005', '__HASH__', '45, Road No. 36, Jubilee Hills',   'Hyderabad'),
('Sneha Kulkarni', 'sneha.kulkarni@example.com', '9876500006', '__HASH__', '9, Kothrud Garden Society, Kothrud', 'Pune');

INSERT INTO vehicles (customer_id, registration_no, vehicle_type, make, model, manufacture_year, fuel_type, color) VALUES
(1, 'TN09AB1234', 'SUV',   'Hyundai',        'Creta',           2021, 'DIESEL',   'White'),
(1, 'TN09CD5678', 'BIKE',  'Honda',          'Activa 6G',       2022, 'PETROL',   'Grey'),
(2, 'KA01MN4455', 'CAR',   'Maruti Suzuki',  'Swift',           2019, 'PETROL',   'Red'),
(2, 'KA03XY9090', 'CAR',   'Tata',           'Nexon EV',        2023, 'ELECTRIC', 'Blue'),
(3, 'MH12PQ3321', 'SUV',   'Toyota',         'Innova Crysta',   2020, 'DIESEL',   'Silver'),
(4, 'TN10EF7788', 'CAR',   'Maruti Suzuki',  'Baleno',          2021, 'PETROL',   'Black'),
(5, 'TS09GH1122', 'SUV',   'Mahindra',       'Thar',            2022, 'DIESEL',   'Orange'),
(5, 'TS07JK6655', 'BIKE',  'Royal Enfield',  'Classic 350',     2020, 'PETROL',   'Stealth Black'),
(6, 'MH14LM8899', 'TRUCK', 'Tata',           'Ace Gold',        2018, 'DIESEL',   'White'),
(6, 'MH14ZZ0001', 'CAR',   'Honda',          'City',            2022, 'PETROL',   'Pearl White');

INSERT INTO mechanics (full_name, email, phone, password_hash, city, experience_years, is_available) VALUES
('Murugan Selvam', 'murugan.selvam@roadsafe.in', '9800000001', '__HASH__', 'Chennai',   12, 1),
('Imran Khan',     'imran.khan@roadsafe.in',     '9800000002', '__HASH__', 'Chennai',    7, 1),
('Ravi Kumar',     'ravi.kumar@roadsafe.in',     '9800000003', '__HASH__', 'Bengaluru',  9, 1),
('Deepak Gowda',   'deepak.gowda@roadsafe.in',   '9800000004', '__HASH__', 'Bengaluru',  5, 1),
('Sanjay Patil',   'sanjay.patil@roadsafe.in',   '9800000005', '__HASH__', 'Pune',      10, 1),
('Vikram Joshi',   'vikram.joshi@roadsafe.in',   '9800000006', '__HASH__', 'Pune',       4, 0),
('Srinivas Rao',   'srinivas.rao@roadsafe.in',   '9800000007', '__HASH__', 'Hyderabad', 11, 1),
('Farhan Ali',     'farhan.ali@roadsafe.in',     '9800000008', '__HASH__', 'Hyderabad',  6, 1);

INSERT INTO mechanic_services (mechanic_id, service_id) VALUES
(1,1),(1,2),(1,3),(1,4),(1,5),(1,8),
(2,1),(2,2),(2,3),(2,7),(2,8),
(3,1),(3,2),(3,3),(3,4),(3,5),(3,6),(3,8),
(4,1),(4,2),(4,3),(4,7),(4,8),
(5,1),(5,2),(5,4),(5,5),(5,6),(5,8),
(6,1),(6,2),(6,3),(6,7),(6,8),
(7,1),(7,2),(7,3),(7,4),(7,5),(7,6),(7,7),(7,8),
(8,1),(8,2),(8,3),(8,5),(8,7),(8,8);

-- ---------------------------------------------------------------------
-- Helper used ONLY for loading history: walks a request through the whole
-- workflow (assign -> accept -> on the way -> arrived -> in progress ->
-- bill -> completed -> paid -> feedback) so every trigger fires.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_seed_job;
DELIMITER $$
CREATE PROCEDURE sp_seed_job(
    IN p_cust INT, IN p_veh INT, IN p_svc INT, IN p_pri VARCHAR(10),
    IN p_city VARCHAR(60), IN p_addr VARCHAR(255), IN p_mech INT,
    IN p_days_ago INT, IN p_minutes INT, IN p_parts DECIMAL(10,2),
    IN p_method VARCHAR(10), IN p_rating TINYINT, IN p_comment VARCHAR(500),
    IN p_notes VARCHAR(500))
BEGIN
    DECLARE v_req INT;
    DECLARE v_loc INT;
    DECLARE v_ts  DATETIME;
    DECLARE v_end DATETIME;
    SET v_ts  = DATE_SUB(NOW(), INTERVAL p_days_ago DAY);
    SET v_end = DATE_ADD(v_ts, INTERVAL p_minutes MINUTE);
    INSERT INTO locations (address_line, city) VALUES (p_addr, p_city);
    SET v_loc = LAST_INSERT_ID();
    INSERT INTO assistance_requests (customer_id, vehicle_id, service_id, location_id, priority, description, requested_at)
    VALUES (p_cust, p_veh, p_svc, v_loc, p_pri, 'Vehicle stopped on the road, need help', v_ts);
    SET v_req = LAST_INSERT_ID();
    INSERT INTO request_assignments (request_id, mechanic_id, assigned_by, assigned_at)
    VALUES (v_req, p_mech, 'SYSTEM', DATE_ADD(v_ts, INTERVAL 2 MINUTE));
    UPDATE request_assignments SET response = 'ACCEPTED', responded_at = DATE_ADD(v_ts, INTERVAL 4 MINUTE)
    WHERE request_id = v_req;
    UPDATE assistance_requests SET status = 'ON_THE_WAY' WHERE request_id = v_req;
    UPDATE assistance_requests SET status = 'ARRIVED'    WHERE request_id = v_req;
    UPDATE assistance_requests SET status = 'IN_PROGRESS', started_at = DATE_ADD(v_ts, INTERVAL (p_minutes DIV 2) MINUTE)
    WHERE request_id = v_req;
    INSERT INTO payments (request_id, service_charge, parts_charge, created_at)
    VALUES (v_req, fn_estimate_cost(p_svc, p_pri), p_parts, v_end);
    UPDATE assistance_requests SET status = 'COMPLETED', completed_at = v_end, resolution_notes = p_notes
    WHERE request_id = v_req;
    IF p_method IS NOT NULL THEN
        UPDATE payments SET payment_status = 'PAID', payment_method = p_method,
               transaction_ref = CONCAT(p_method, DATE_FORMAT(v_end, '%y%m%d'), LPAD(v_req, 5, '0'), '0000'),
               paid_at = DATE_ADD(v_end, INTERVAL 15 MINUTE)
        WHERE request_id = v_req;
    END IF;
    IF p_rating IS NOT NULL THEN
        INSERT INTO feedback (request_id, rating, comments, created_at)
        VALUES (v_req, p_rating, p_comment, DATE_ADD(v_end, INTERVAL 1 HOUR));
    END IF;
END$$
DELIMITER ;

--          cust veh svc priority     city         address                                  mech days min  parts   method  rate comment                                              notes
CALL sp_seed_job(1, 1, 4, 'HIGH',      'Chennai',   'Anna Salai, near Spencer Plaza',        1, 85, 95, 1200.00, 'UPI',  5, 'Diagnosed the fault in minutes. Very professional.',  'Replaced fuel filter and cleaned injector line');
CALL sp_seed_job(2, 3, 1, 'MEDIUM',    'Bengaluru', 'MG Road Metro Station exit 2',          3, 78, 40,    0.00, 'CASH', 4, 'Quick jump-start, polite behaviour.',                 'Jump-started, battery tested OK');
CALL sp_seed_job(3, 5, 2, 'LOW',       'Pune',      'Baner Road near Balewadi Phata',        5, 70, 35,    0.00, 'CARD', 4, 'Changed the tyre neatly.',                            'Spare wheel fitted, damaged tyre stowed');
CALL sp_seed_job(4, 6, 3, 'MEDIUM',    'Chennai',   'OMR, Perungudi toll plaza',             2, 64, 30,  150.00, 'UPI',  5, 'Fuel arrived in 25 minutes. Great service.',          '5 litres petrol delivered');
CALL sp_seed_job(5, 7, 5, 'HIGH',      'Hyderabad', 'ORR Exit 5, Gachibowli',                7, 58,120,    0.00, 'CARD', 5, 'Towed safely to the service centre.',                 'Flatbed towing to authorised garage');
CALL sp_seed_job(6, 9, 7, 'LOW',       'Pune',      'Koregaon Park Lane 5',                  6, 52, 25,    0.00, 'CASH', 3, 'Took a while to arrive but solved it.',               'Door unlocked without damage');
CALL sp_seed_job(1, 2, 2, 'MEDIUM',    'Chennai',   'Adyar Signal',                          2, 47, 30,  100.00, 'UPI',  4, 'Puncture repaired on the spot.',                      'Tubeless puncture plug applied');
CALL sp_seed_job(2, 4, 8, 'LOW',       'Bengaluru', 'Indiranagar 100 Feet Road',             4, 41, 45,    0.00, 'CASH', NULL, NULL,                                               'Loose terminal tightened, error cleared');
CALL sp_seed_job(3, 5, 4, 'EMERGENCY', 'Pune',      'Mumbai-Pune Expressway, KM 82',         5, 35,150, 2500.00, 'CARD', 5, 'Saved our trip. Reached fast despite the highway.',   'Replaced coolant hose and refilled coolant');
CALL sp_seed_job(5, 8, 1, 'MEDIUM',    'Hyderabad', 'Jubilee Hills Check Post',              8, 30, 35,  600.00, 'UPI',  4, 'New battery fitted on site.',                         'Replaced 12V battery');
CALL sp_seed_job(4, 6, 5, 'HIGH',      'Chennai',   'ECR, Muttukadu boat house',             1, 26,110,    0.00, 'UPI',  5, 'Careful with the car. Highly recommended.',           'Towed to dealership');
CALL sp_seed_job(2, 3, 3, 'MEDIUM',    'Bengaluru', 'Whitefield, ITPL main road',            4, 21, 28,  120.00, 'UPI',  4, 'On time and helpful.',                                '4 litres petrol delivered');
CALL sp_seed_job(6,10, 6, 'EMERGENCY', 'Pune',      'Pashan-Sus Road',                       5, 17,180, 3000.00, 'CARD', 5, 'Handled the whole situation calmly.',                 'Vehicle recovery and accident report support');
CALL sp_seed_job(5, 7, 8, 'LOW',       'Hyderabad', 'HITEC City, Cyber Towers',              7, 12, 50,    0.00, 'CASH', 4, 'Fixed the AC belt noise problem.',                    'Replaced slipping accessory belt');
CALL sp_seed_job(1, 1, 1, 'HIGH',      'Chennai',   'T Nagar, Pondy Bazaar',                 2,  8, 38,    0.00, 'UPI',  5, 'Instant jump-start. Superb.',                         'Jump-started and alternator checked');
CALL sp_seed_job(3, 5, 2, 'MEDIUM',    'Pune',      'Hinjewadi Phase 2',                     6,  5, 33,    0.00, 'UPI',  4, 'Good work.',                                          'Tyre replaced with spare');
CALL sp_seed_job(2, 4, 7, 'HIGH',      'Bengaluru', 'Koramangala 5th Block',                 4,  3, 22,    0.00, 'CASH', 5, 'Opened the car in minutes.',                          'Smart-key lockout resolved');
-- completed but NOT yet paid and not yet rated (demo for bills + feedback pages)
CALL sp_seed_job(6, 9, 1, 'MEDIUM',    'Pune',      'Kothrud Depot Road',                    5,  1, 40,  300.00, NULL,   NULL, NULL,                                               'Battery terminals cleaned, booster charge');

-- A cancelled request
CALL sp_create_request(4, 6, 2, 'LOW', 'Slow puncture, can wait', 'Besant Nagar 2nd Avenue', 'Chennai', '600090', 'Near Ashtalakshmi Temple', NULL, NULL, @rid);
CALL sp_cancel_request(@rid, 4);

-- Live requests created through the real procedures
-- (1) assigned automatically, waiting for the mechanic to respond
CALL sp_create_request(1, 2, 3, 'HIGH', 'Scooter ran out of petrol', 'Mount Road near LIC Building', 'Chennai', '600002', 'LIC Building', 13.0645, 80.2707, @rid1);
CALL sp_auto_assign_mechanic(@rid1, @mech1);

-- (2) emergency job already in progress
CALL sp_create_request(3, 5, 1, 'EMERGENCY', 'Battery died on the highway, family in the car', 'Pune-Bengaluru Highway, Katraj Tunnel', 'Pune', '411046', 'Before Katraj Tunnel', 18.4575, 73.8590, @rid2);
CALL sp_auto_assign_mechanic(@rid2, @mech2);
CALL sp_mechanic_respond(@rid2, @mech2, 1, NULL);
CALL sp_update_status(@rid2, @mech2, 'ON_THE_WAY');
CALL sp_update_status(@rid2, @mech2, 'ARRIVED');
CALL sp_update_status(@rid2, @mech2, 'IN_PROGRESS');

-- (3) new request nobody has been assigned to yet (admin queue)
CALL sp_create_request(5, 8, 2, 'LOW', 'Rear tyre looks flat', 'Road No. 12, Banjara Hills', 'Hyderabad', '500034', 'Opposite City Centre Mall', NULL, NULL, @rid3);

DROP PROCEDURE IF EXISTS sp_seed_job;
