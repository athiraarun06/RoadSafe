-- =====================================================================
--  RoadSafe - Roadside Assistance Management System
--  schema.sql : DDL (database, tables, constraints, indexes)
--  Normal form : 3NF  (see README for the normalisation walk-through)
--  Engine      : InnoDB  (ACID, row-level locking, foreign keys)
-- =====================================================================
DROP DATABASE IF EXISTS roadsafe;
CREATE DATABASE roadsafe CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE roadsafe;

-- ---------------------------------------------------------------- admins
CREATE TABLE admins (
    admin_id       INT AUTO_INCREMENT PRIMARY KEY,
    full_name      VARCHAR(100) NOT NULL,
    email          VARCHAR(120) NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_admin_email UNIQUE (email)
) ENGINE=InnoDB;

-- ------------------------------------------------------------- customers
CREATE TABLE customers (
    customer_id    INT AUTO_INCREMENT PRIMARY KEY,
    full_name      VARCHAR(100) NOT NULL,
    email          VARCHAR(120) NOT NULL,
    phone          VARCHAR(15)  NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,
    address        VARCHAR(255) NULL,
    city           VARCHAR(60)  NULL,
    is_active      TINYINT(1)   NOT NULL DEFAULT 1,
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_customer_email UNIQUE (email),
    CONSTRAINT uq_customer_phone UNIQUE (phone),
    CONSTRAINT chk_customer_phone CHECK (CHAR_LENGTH(phone) BETWEEN 7 AND 15),
    CONSTRAINT chk_customer_active CHECK (is_active IN (0,1))
) ENGINE=InnoDB;

-- -------------------------------------------------------------- vehicles
CREATE TABLE vehicles (
    vehicle_id        INT AUTO_INCREMENT PRIMARY KEY,
    customer_id       INT          NOT NULL,
    registration_no   VARCHAR(20)  NOT NULL,
    vehicle_type      ENUM('CAR','SUV','BIKE','AUTO','VAN','TRUCK') NOT NULL,
    make              VARCHAR(50)  NOT NULL,
    model             VARCHAR(50)  NOT NULL,
    manufacture_year  SMALLINT     NOT NULL,
    fuel_type         ENUM('PETROL','DIESEL','CNG','ELECTRIC','HYBRID') NOT NULL,
    color             VARCHAR(30)  NULL,
    CONSTRAINT uq_vehicle_reg   UNIQUE (registration_no),
    -- lets assistance_requests use a composite FK that proves "vehicle belongs to customer"
    CONSTRAINT uq_vehicle_owner UNIQUE (vehicle_id, customer_id),
    CONSTRAINT chk_vehicle_year CHECK (manufacture_year BETWEEN 1980 AND 2100),
    CONSTRAINT fk_vehicle_customer FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id) ON DELETE CASCADE,
    INDEX idx_vehicle_customer (customer_id)
) ENGINE=InnoDB;

-- -------------------------------------------------------------- mechanics
CREATE TABLE mechanics (
    mechanic_id       INT AUTO_INCREMENT PRIMARY KEY,
    full_name         VARCHAR(100) NOT NULL,
    email             VARCHAR(120) NOT NULL,
    phone             VARCHAR(15)  NOT NULL,
    password_hash     VARCHAR(255) NOT NULL,
    city              VARCHAR(60)  NOT NULL,
    experience_years  TINYINT UNSIGNED NOT NULL DEFAULT 0,
    is_available      TINYINT(1)   NOT NULL DEFAULT 1,   -- toggled by the mechanic
    is_active         TINYINT(1)   NOT NULL DEFAULT 1,   -- toggled by the admin
    created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_mechanic_email UNIQUE (email),
    CONSTRAINT uq_mechanic_phone UNIQUE (phone),
    CONSTRAINT chk_mechanic_exp  CHECK (experience_years <= 60),
    CONSTRAINT chk_mechanic_flags CHECK (is_available IN (0,1) AND is_active IN (0,1)),
    INDEX idx_mechanic_city_avail (city, is_available)
) ENGINE=InnoDB;

-- --------------------------------------------------------------- services
CREATE TABLE services (
    service_id    INT AUTO_INCREMENT PRIMARY KEY,
    service_name  VARCHAR(60)   NOT NULL,
    description   VARCHAR(255)  NULL,
    base_charge   DECIMAL(10,2) NOT NULL,
    icon          VARCHAR(40)   NOT NULL DEFAULT 'bi-tools',
    is_active     TINYINT(1)    NOT NULL DEFAULT 1,
    CONSTRAINT uq_service_name UNIQUE (service_name),
    CONSTRAINT chk_service_charge CHECK (base_charge >= 0)
) ENGINE=InnoDB;

-- ------------------------------------- mechanic_services  (M:N junction)
CREATE TABLE mechanic_services (
    mechanic_id  INT NOT NULL,
    service_id   INT NOT NULL,
    PRIMARY KEY (mechanic_id, service_id),
    CONSTRAINT fk_ms_mechanic FOREIGN KEY (mechanic_id) REFERENCES mechanics(mechanic_id) ON DELETE CASCADE,
    CONSTRAINT fk_ms_service  FOREIGN KEY (service_id)  REFERENCES services(service_id)   ON DELETE CASCADE,
    INDEX idx_ms_service (service_id)
) ENGINE=InnoDB;

-- -------------------------------------------------------------- locations
CREATE TABLE locations (
    location_id   INT AUTO_INCREMENT PRIMARY KEY,
    address_line  VARCHAR(255) NOT NULL,
    city          VARCHAR(60)  NOT NULL,
    pincode       VARCHAR(10)  NULL,
    landmark      VARCHAR(120) NULL,
    latitude      DECIMAL(9,6) NULL,
    longitude     DECIMAL(9,6) NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_loc_lat CHECK (latitude  IS NULL OR latitude  BETWEEN -90  AND 90),
    CONSTRAINT chk_loc_lng CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
    INDEX idx_location_city (city)
) ENGINE=InnoDB;

-- ----------------------------------------------------- assistance_requests
CREATE TABLE assistance_requests (
    request_id        INT AUTO_INCREMENT PRIMARY KEY,
    customer_id       INT NOT NULL,
    vehicle_id        INT NOT NULL,
    service_id        INT NOT NULL,
    location_id       INT NOT NULL,
    priority          ENUM('LOW','MEDIUM','HIGH','EMERGENCY') NOT NULL DEFAULT 'MEDIUM',
    status            ENUM('PENDING','ASSIGNED','ACCEPTED','ON_THE_WAY','ARRIVED',
                           'IN_PROGRESS','COMPLETED','CANCELLED') NOT NULL DEFAULT 'PENDING',
    description       VARCHAR(500) NULL,
    resolution_notes  VARCHAR(500) NULL,
    requested_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at        DATETIME NULL,
    completed_at      DATETIME NULL,
    CONSTRAINT uq_request_location UNIQUE (location_id),
    CONSTRAINT chk_request_times CHECK (completed_at IS NULL OR completed_at >= requested_at),
    CONSTRAINT fk_req_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_req_service  FOREIGN KEY (service_id)  REFERENCES services(service_id),
    CONSTRAINT fk_req_location FOREIGN KEY (location_id) REFERENCES locations(location_id),
    -- composite FK: the vehicle MUST belong to the same customer
    CONSTRAINT fk_req_vehicle_owner FOREIGN KEY (vehicle_id, customer_id)
        REFERENCES vehicles(vehicle_id, customer_id),
    INDEX idx_req_customer (customer_id),
    INDEX idx_req_vehicle  (vehicle_id),
    INDEX idx_req_service  (service_id),
    INDEX idx_req_status_priority (status, priority),
    INDEX idx_req_requested_at (requested_at)
) ENGINE=InnoDB;

-- ------------------------------------------------------ request_assignments
CREATE TABLE request_assignments (
    assignment_id     INT AUTO_INCREMENT PRIMARY KEY,
    request_id        INT NOT NULL,
    mechanic_id       INT NOT NULL,
    assigned_by       ENUM('SYSTEM','ADMIN') NOT NULL DEFAULT 'SYSTEM',
    response          ENUM('PENDING','ACCEPTED','REJECTED') NOT NULL DEFAULT 'PENDING',
    assigned_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    responded_at      DATETIME NULL,
    rejection_reason  VARCHAR(255) NULL,
    CONSTRAINT uq_assignment_request UNIQUE (request_id),           -- Request -> Assignment (1:1)
    CONSTRAINT fk_assign_request  FOREIGN KEY (request_id)  REFERENCES assistance_requests(request_id) ON DELETE CASCADE,
    CONSTRAINT fk_assign_mechanic FOREIGN KEY (mechanic_id) REFERENCES mechanics(mechanic_id),
    INDEX idx_assign_mechanic (mechanic_id, response)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- payments
CREATE TABLE payments (
    payment_id      INT AUTO_INCREMENT PRIMARY KEY,
    request_id      INT NOT NULL,
    service_charge  DECIMAL(10,2) NOT NULL,
    parts_charge    DECIMAL(10,2) NOT NULL DEFAULT 0,
    total_amount    DECIMAL(10,2) GENERATED ALWAYS AS (service_charge + parts_charge) STORED,
    payment_method  ENUM('CASH','UPI','CARD') NULL,
    payment_status  ENUM('PENDING','PAID','FAILED') NOT NULL DEFAULT 'PENDING',
    transaction_ref VARCHAR(40) NULL,
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    paid_at         DATETIME NULL,
    CONSTRAINT uq_payment_request UNIQUE (request_id),              -- Request -> Payment (1:1)
    CONSTRAINT uq_payment_txn     UNIQUE (transaction_ref),
    CONSTRAINT chk_payment_service CHECK (service_charge >= 0),
    CONSTRAINT chk_payment_parts   CHECK (parts_charge >= 0),
    CONSTRAINT chk_payment_paid    CHECK (payment_status <> 'PAID' OR payment_method IS NOT NULL),
    CONSTRAINT fk_payment_request FOREIGN KEY (request_id) REFERENCES assistance_requests(request_id) ON DELETE CASCADE,
    INDEX idx_payment_status (payment_status, paid_at)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- feedback
CREATE TABLE feedback (
    feedback_id  INT AUTO_INCREMENT PRIMARY KEY,
    request_id   INT NOT NULL,
    rating       TINYINT NOT NULL,
    comments     VARCHAR(500) NULL,
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_feedback_request UNIQUE (request_id),             -- Request -> Feedback (1:1)
    CONSTRAINT chk_feedback_rating CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT fk_feedback_request FOREIGN KEY (request_id) REFERENCES assistance_requests(request_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------- service_history
-- Archive written ONLY by trigger trg_req_after_update when a request is COMPLETED.
-- duration_minutes / total_cost are deliberate audit snapshots (they must not change later).
CREATE TABLE service_history (
    history_id        INT AUTO_INCREMENT PRIMARY KEY,
    request_id        INT NOT NULL,
    mechanic_id       INT NOT NULL,
    completed_at      DATETIME NOT NULL,
    duration_minutes  INT NOT NULL,
    total_cost        DECIMAL(10,2) NOT NULL DEFAULT 0,
    work_summary      VARCHAR(500) NULL,
    CONSTRAINT uq_history_request UNIQUE (request_id),              -- Request -> History (1:1)
    CONSTRAINT chk_history_duration CHECK (duration_minutes >= 0),
    CONSTRAINT fk_history_request  FOREIGN KEY (request_id)  REFERENCES assistance_requests(request_id) ON DELETE CASCADE,
    CONSTRAINT fk_history_mechanic FOREIGN KEY (mechanic_id) REFERENCES mechanics(mechanic_id),
    INDEX idx_history_mechanic (mechanic_id, completed_at)
) ENGINE=InnoDB;
