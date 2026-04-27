

DROP DATABASE IF EXISTS BloodBankDB;
CREATE DATABASE BloodBankDB;
USE BloodBankDB;

SET SQL_SAFE_UPDATES    = 0;
SET FOREIGN_KEY_CHECKS  = 0;

-- ══════════════════════════════════════════════════════════════
--  TABLES
-- ══════════════════════════════════════════════════════════════

-- FIX #9: blood_group is now ENUM everywhere — invalid values rejected at DB level
CREATE TABLE IF NOT EXISTS DONOR (
    donor_id           INT AUTO_INCREMENT PRIMARY KEY,
    name               VARCHAR(100) NOT NULL,
    age                INT CHECK (age >= 18),
    blood_group        ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    last_donation_date DATE,
    contact            VARCHAR(15)
);

CREATE TABLE IF NOT EXISTS BLOOD_BANK (
    bank_id  INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    location VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS DONATION (
    donation_id   INT AUTO_INCREMENT PRIMARY KEY,
    donor_id      INT NOT NULL,
    bank_id       INT NOT NULL,
    donation_date DATE NOT NULL,
    FOREIGN KEY (donor_id) REFERENCES DONOR(donor_id),
    FOREIGN KEY (bank_id)  REFERENCES BLOOD_BANK(bank_id)
);

-- FIX #11: blood_group added directly to BLOOD_UNIT — eliminates 3-table join
CREATE TABLE IF NOT EXISTS BLOOD_UNIT (
    unit_id     INT AUTO_INCREMENT PRIMARY KEY,
    donation_id INT NOT NULL,
    blood_group ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    expiry_date DATE NOT NULL,
    status      ENUM('Available','Used','Expired') DEFAULT 'Available',
    bank_id     INT NOT NULL,
    FOREIGN KEY (donation_id) REFERENCES DONATION(donation_id),
    FOREIGN KEY (bank_id)     REFERENCES BLOOD_BANK(bank_id)
);

CREATE TABLE IF NOT EXISTS HOSPITAL (
    hospital_id INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    location    VARCHAR(100)
);

-- FIX #10: status has a DEFAULT so rows created outside triggers are valid
CREATE TABLE IF NOT EXISTS REQUEST (
    request_id     INT AUTO_INCREMENT PRIMARY KEY,
    hospital_id    INT NOT NULL,
    blood_group    ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    units_required INT NOT NULL CHECK (units_required > 0),
    status         ENUM('Completed','Pending') NOT NULL DEFAULT 'Pending',
    request_date   DATE NOT NULL,
    FOREIGN KEY (hospital_id) REFERENCES HOSPITAL(hospital_id)
);

CREATE TABLE IF NOT EXISTS ROLE (
    role_id   INT AUTO_INCREMENT PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL
);

CREATE TABLE IF NOT EXISTS STAFF (
    staff_id INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    role_id  INT,
    bank_id  INT,
    FOREIGN KEY (role_id) REFERENCES ROLE(role_id),
    FOREIGN KEY (bank_id) REFERENCES BLOOD_BANK(bank_id)
);

CREATE TABLE IF NOT EXISTS GEO_LOCATION (
    location_id INT AUTO_INCREMENT PRIMARY KEY,
    latitude    DECIMAL(9,6),
    longitude   DECIMAL(9,6),
    city        VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS DONOR_LOCATION (
    donor_id    INT,
    location_id INT,
    PRIMARY KEY (donor_id, location_id),
    FOREIGN KEY (donor_id)    REFERENCES DONOR(donor_id),
    FOREIGN KEY (location_id) REFERENCES GEO_LOCATION(location_id)
);

CREATE TABLE IF NOT EXISTS NOTIFICATION_LOG (
    log_id     INT AUTO_INCREMENT PRIMARY KEY,
    message    VARCHAR(255),
    created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS DONOR_REWARD (
    donor_id INT PRIMARY KEY,
    points   INT DEFAULT 0,
    FOREIGN KEY (donor_id) REFERENCES DONOR(donor_id)
);

-- FIX #7: COMPATIBILITY now populated — used as source of truth
CREATE TABLE IF NOT EXISTS COMPATIBILITY (
    donor_group     ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    recipient_group ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    PRIMARY KEY (donor_group, recipient_group)
);

CREATE TABLE IF NOT EXISTS TEMPERATURE_LOG (
    log_id      INT AUTO_INCREMENT PRIMARY KEY,
    unit_id     INT NOT NULL,
    temperature DECIMAL(4,2),
    recorded_at DATETIME DEFAULT NOW(),
    FOREIGN KEY (unit_id) REFERENCES BLOOD_UNIT(unit_id)
);

CREATE TABLE IF NOT EXISTS TRANSPORT (
    transport_id INT AUTO_INCREMENT PRIMARY KEY,
    unit_id      INT NOT NULL,
    source_bank  INT NOT NULL,
    destination  VARCHAR(100),
    status       ENUM('In Transit','Delivered','Cancelled') DEFAULT 'In Transit',
    FOREIGN KEY (unit_id)     REFERENCES BLOOD_UNIT(unit_id),
    FOREIGN KEY (source_bank) REFERENCES BLOOD_BANK(bank_id)
);

CREATE TABLE IF NOT EXISTS EMERGENCY_REQUEST (
    req_id         INT AUTO_INCREMENT PRIMARY KEY,
    location_id    INT,
    blood_group    ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-') NOT NULL,
    priority_level ENUM('Low','Medium','High','Critical') DEFAULT 'Medium',
    FOREIGN KEY (location_id) REFERENCES GEO_LOCATION(location_id)
);

SET FOREIGN_KEY_CHECKS = 1;

-- ══════════════════════════════════════════════════════════════
--  COMPATIBILITY DATA (FIX #7)
-- ══════════════════════════════════════════════════════════════
INSERT INTO COMPATIBILITY (donor_group, recipient_group) VALUES
-- O- (universal donor)
('O-','O-'),('O-','O+'),('O-','A-'),('O-','A+'),('O-','B-'),('O-','B+'),('O-','AB-'),('O-','AB+'),
-- O+
('O+','O+'),('O+','A+'),('O+','B+'),('O+','AB+'),
-- A-
('A-','A-'),('A-','A+'),('A-','AB-'),('A-','AB+'),
-- A+
('A+','A+'),('A+','AB+'),
-- B-
('B-','B-'),('B-','B+'),('B-','AB-'),('B-','AB+'),
-- B+
('B+','B+'),('B+','AB+'),
-- AB-
('AB-','AB-'),('AB-','AB+'),
-- AB+ (universal recipient — can only donate to AB+)
('AB+','AB+');

-- ══════════════════════════════════════════════════════════════
--  TRIGGERS
-- ══════════════════════════════════════════════════════════════

DELIMITER $$

-- FIX #11: Pull blood_group from DONOR and store directly in BLOOD_UNIT
CREATE TRIGGER after_donation_insert
AFTER INSERT ON DONATION
FOR EACH ROW
BEGIN
    DECLARE v_blood_group ENUM('A+','A-','B+','B-','O+','O-','AB+','AB-');
    SELECT blood_group INTO v_blood_group FROM DONOR WHERE donor_id = NEW.donor_id;
    INSERT INTO BLOOD_UNIT (donation_id, blood_group, expiry_date, status, bank_id)
    VALUES (
        NEW.donation_id,
        v_blood_group,
        DATE_ADD(NEW.donation_date, INTERVAL 42 DAY),
        'Available',
        NEW.bank_id
    );
END$$

-- FIX #2: Exclude expired units from availability count
CREATE TRIGGER before_request_insert
BEFORE INSERT ON REQUEST
FOR EACH ROW
BEGIN
    DECLARE available_units INT;
    -- Direct query on BLOOD_UNIT.blood_group (no 3-table join needed now)
    -- Expiry check added: only non-expired units count
    SELECT COUNT(*) INTO available_units
    FROM BLOOD_UNIT
    WHERE blood_group = NEW.blood_group
      AND status      = 'Available'
      AND expiry_date >= CURDATE();

    IF available_units >= NEW.units_required THEN
        SET NEW.status = 'Completed';
    ELSE
        SET NEW.status = 'Pending';
    END IF;
END$$

-- FIX #1 & #3: Mark correct NUMBER of units as Used; exclude expired; use loop
CREATE TRIGGER after_request_insert
AFTER INSERT ON REQUEST
FOR EACH ROW
BEGIN
    DECLARE v_unit_id   INT;
    DECLARE v_remaining INT;
    DECLARE done        INT DEFAULT 0;

    IF NEW.status = 'Completed' THEN
        SET v_remaining = NEW.units_required;

        -- Loop: mark exactly units_required units as Used (FIX #1)
        WHILE v_remaining > 0 DO
            SET v_unit_id = NULL;

            -- FIX #3: Only pick non-expired units
            SELECT unit_id INTO v_unit_id
            FROM BLOOD_UNIT
            WHERE blood_group = NEW.blood_group
              AND status      = 'Available'
              AND expiry_date >= CURDATE()
            ORDER BY expiry_date ASC   -- use oldest-first (FEFO policy)
            LIMIT 1;

            IF v_unit_id IS NOT NULL THEN
                UPDATE BLOOD_UNIT SET status = 'Used' WHERE unit_id = v_unit_id;
                SET v_remaining = v_remaining - 1;
            ELSE
                SET v_remaining = 0;  -- no more available — exit loop safely
            END IF;
        END WHILE;
    END IF;
END$$

CREATE TRIGGER emergency_match
AFTER INSERT ON EMERGENCY_REQUEST
FOR EACH ROW
BEGIN
    INSERT INTO NOTIFICATION_LOG (message, created_at)
    VALUES (CONCAT('Emergency request for ', NEW.blood_group, ' [', NEW.priority_level, ']'), NOW());
END$$

DELIMITER ;

-- ══════════════════════════════════════════════════════════════
--  STORED PROCEDURES
-- ══════════════════════════════════════════════════════════════

DELIMITER $$

CREATE PROCEDURE Process_Emergency_Request(
    IN p_location_id    INT,
    IN p_blood_group    VARCHAR(5),
    IN p_priority_level VARCHAR(20)
)
BEGIN
    DECLARE available_units INT DEFAULT 0;
    INSERT INTO EMERGENCY_REQUEST (location_id, blood_group, priority_level)
    VALUES (p_location_id, p_blood_group, p_priority_level);

    SELECT COUNT(*) INTO available_units
    FROM BLOOD_UNIT
    WHERE blood_group = p_blood_group
      AND status      = 'Available'
      AND expiry_date >= CURDATE();

    IF available_units >= 5 THEN
        SELECT 'Emergency request accepted. Sufficient stock available.' AS Message;
    ELSEIF available_units BETWEEN 1 AND 4 THEN
        SELECT 'Emergency request accepted. Low stock — urgent replenishment needed.' AS Message;
    ELSE
        SELECT 'Critical shortage! No units available for requested blood group.' AS Message;
    END IF;
END$$

-- FIX #12: Provenance consistency — transfer logs source donation context
CREATE PROCEDURE Redistribute_Stock_Between_Banks(
    IN p_source_bank      INT,
    IN p_destination_bank INT
)
BEGIN
    DECLARE v_unit_id   INT DEFAULT NULL;
    DECLARE v_src_count INT DEFAULT 0;
    DECLARE v_dst_count INT DEFAULT 0;

    SELECT COUNT(*) INTO v_src_count FROM BLOOD_BANK WHERE bank_id = p_source_bank;
    SELECT COUNT(*) INTO v_dst_count FROM BLOOD_BANK WHERE bank_id = p_destination_bank;

    IF v_src_count = 0 THEN
        SELECT 'Source bank does not exist.' AS Message;
    ELSEIF v_dst_count = 0 THEN
        SELECT 'Destination bank does not exist.' AS Message;
    ELSEIF p_source_bank = p_destination_bank THEN
        SELECT 'Source and destination bank cannot be the same.' AS Message;
    ELSE
        SELECT unit_id INTO v_unit_id
        FROM BLOOD_UNIT
        WHERE bank_id   = p_source_bank
          AND status    = 'Available'
          AND expiry_date >= CURDATE()
        ORDER BY expiry_date ASC
        LIMIT 1;

        IF v_unit_id IS NOT NULL THEN
            -- Update the unit's current holding bank
            UPDATE BLOOD_UNIT SET bank_id = p_destination_bank WHERE unit_id = v_unit_id;

            -- Log transport with clear source/destination; donation_id stays unchanged
            -- so provenance (who donated, original collection bank) remains traceable
            INSERT INTO TRANSPORT (unit_id, source_bank, destination, status)
            VALUES (v_unit_id, p_source_bank,
                    CONCAT('Bank ', p_destination_bank, ' (', 
                           (SELECT name FROM BLOOD_BANK WHERE bank_id = p_destination_bank), ')'),
                    'Delivered');

            INSERT INTO NOTIFICATION_LOG (message, created_at)
            VALUES (CONCAT('Unit ', v_unit_id, ' transferred from Bank ', p_source_bank,
                           ' to Bank ', p_destination_bank), NOW());

            SELECT CONCAT('Blood unit ', v_unit_id, ' transferred successfully.') AS Message;
        ELSE
            SELECT 'No available non-expired blood unit found in source bank.' AS Message;
        END IF;
    END IF;
END$$

-- FIX #8: Uses ROW_COUNT() after UPDATE to avoid COUNT/UPDATE race condition
CREATE PROCEDURE Auto_Remove_Expiring_Units()
BEGIN
    DECLARE v_expired_count INT DEFAULT 0;

    UPDATE BLOOD_UNIT
    SET status = 'Expired'
    WHERE expiry_date < CURDATE()
      AND status <> 'Expired';

    -- ROW_COUNT() is atomic — reflects exactly what this UPDATE changed
    SET v_expired_count = ROW_COUNT();

    IF v_expired_count > 0 THEN
        INSERT INTO NOTIFICATION_LOG (message, created_at)
        VALUES (CONCAT(v_expired_count, ' blood units marked as expired'), NOW());
        SELECT CONCAT(v_expired_count, ' expired blood units updated successfully.') AS Message;
    ELSE
        SELECT 'No expired blood units found.' AS Message;
    END IF;
END$$

-- FIX #(Reward): Points now accumulate — adds increment rather than flat reset
CREATE PROCEDURE Reward_Active_Donor(IN p_donor_id INT)
BEGIN
    DECLARE v_count    INT DEFAULT 0;
    DECLARE v_bonus    INT DEFAULT 0;
    DECLARE v_exists   INT DEFAULT 0;

    SELECT COUNT(*) INTO v_count FROM DONATION WHERE donor_id = p_donor_id;

    -- Bonus points for THIS donation event, not a flat tier reset
    IF v_count BETWEEN 1 AND 2      THEN SET v_bonus = 50;
    ELSEIF v_count BETWEEN 3 AND 5  THEN SET v_bonus = 100;
    ELSEIF v_count > 5              THEN SET v_bonus = 200;
    ELSE                                 SET v_bonus = 0;
    END IF;

    SELECT COUNT(*) INTO v_exists FROM DONOR_REWARD WHERE donor_id = p_donor_id;

    IF v_exists = 0 THEN
        INSERT INTO DONOR_REWARD (donor_id, points) VALUES (p_donor_id, v_bonus);
    ELSE
        -- Accumulate: add bonus to existing balance
        UPDATE DONOR_REWARD SET points = points + v_bonus WHERE donor_id = p_donor_id;
    END IF;

    SELECT CONCAT('Donor awarded +', v_bonus, ' points. Call again to see new total.') AS Message;
END$$

CREATE PROCEDURE Schedule_Donation_Drive(IN p_blood_group VARCHAR(5))
BEGIN
    DECLARE v_units INT DEFAULT 0;

    SELECT COUNT(*) INTO v_units
    FROM BLOOD_UNIT
    WHERE blood_group = p_blood_group
      AND status      = 'Available'
      AND expiry_date >= CURDATE();

    IF v_units < 3 THEN
        INSERT INTO NOTIFICATION_LOG (message, created_at)
        VALUES (CONCAT('Donation drive needed for blood group ', p_blood_group), NOW());
        SELECT CONCAT('Low stock detected for ', p_blood_group, '. Donation drive recommended.') AS Message;
    ELSE
        SELECT CONCAT('Stock sufficient for ', p_blood_group, '. No donation drive needed.') AS Message;
    END IF;
END$$

DELIMITER ;

-- ══════════════════════════════════════════════════════════════
--  STORED FUNCTIONS
-- ══════════════════════════════════════════════════════════════

DELIMITER $$

-- FIX #6: NOT DETERMINISTIC — calls CURDATE()
CREATE FUNCTION fn_Days_To_Expiry(p_unit_id INT)
RETURNS INT
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_days INT DEFAULT NULL;
    SELECT DATEDIFF(expiry_date, CURDATE()) INTO v_days
    FROM BLOOD_UNIT WHERE unit_id = p_unit_id;
    RETURN v_days;
END$$

-- FIX #7: Now queries COMPATIBILITY table instead of duplicating logic
CREATE FUNCTION fn_Is_Compatible(
    p_donor_group     VARCHAR(5),
    p_recipient_group VARCHAR(5)
)
RETURNS VARCHAR(20)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_count INT DEFAULT 0;
    SELECT COUNT(*) INTO v_count
    FROM COMPATIBILITY
    WHERE donor_group = p_donor_group AND recipient_group = p_recipient_group;
    IF v_count > 0 THEN RETURN 'Compatible';
    ELSE RETURN 'Not Compatible';
    END IF;
END$$

-- FIX #5: NOT DETERMINISTIC — calls CURDATE() and reads live BLOOD_UNIT data
CREATE FUNCTION fn_Critical_Stock_Level(p_bank_id INT, p_blood_group VARCHAR(5))
RETURNS VARCHAR(20)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_count  INT DEFAULT 0;
    DECLARE v_status VARCHAR(20);

    SELECT COUNT(*) INTO v_count
    FROM BLOOD_UNIT
    WHERE bank_id   = p_bank_id
      AND blood_group = p_blood_group
      AND status    = 'Available'
      AND expiry_date >= CURDATE();

    IF v_count >= 5     THEN SET v_status = 'SAFE';
    ELSEIF v_count >= 1 THEN SET v_status = 'LOW';
    ELSE                     SET v_status = 'CRITICAL';
    END IF;
    RETURN v_status;
END$$

CREATE FUNCTION fn_Donor_Loyalty_Tier(p_donor_id INT)
RETURNS VARCHAR(30)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_tier  VARCHAR(30);
    SELECT COUNT(*) INTO v_count FROM DONATION WHERE donor_id = p_donor_id;
    IF v_count = 0                  THEN SET v_tier = 'No Donations';
    ELSEIF v_count BETWEEN 1 AND 2  THEN SET v_tier = 'New Donor';
    ELSEIF v_count BETWEEN 3 AND 5  THEN SET v_tier = 'Regular Donor';
    ELSEIF v_count BETWEEN 6 AND 10 THEN SET v_tier = 'Hero Donor';
    ELSE                                 SET v_tier = 'Lifesaver';
    END IF;
    RETURN v_tier;
END$$

CREATE FUNCTION fn_Request_Priority(p_request_id INT)
RETURNS VARCHAR(20)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_qty      INT DEFAULT 0;
    DECLARE v_priority VARCHAR(20);
    SELECT units_required INTO v_qty FROM REQUEST WHERE request_id = p_request_id;
    IF v_qty IS NULL        THEN SET v_priority = 'Unknown';
    ELSEIF v_qty = 1        THEN SET v_priority = 'Normal';
    ELSEIF v_qty BETWEEN 2 AND 4 THEN SET v_priority = 'Urgent';
    ELSEIF v_qty >= 5       THEN SET v_priority = 'Emergency';
    ELSE                         SET v_priority = 'Unknown';
    END IF;
    RETURN v_priority;
END$$

DELIMITER ;

-- ══════════════════════════════════════════════════════════════
--  SAMPLE DATA
-- ══════════════════════════════════════════════════════════════

INSERT INTO BLOOD_BANK (bank_id, name, location) VALUES
(1,'Lifeline Blood Centre','Delhi'),(2,'Aarogya Blood Bank','Mumbai'),(3,'Surya BloodCare','Chennai'),
(4,'Calcutta Haemobank','Kolkata'),(5,'Sahyadri Blood Store','Pune'),(6,'Deccan Blood Services','Hyderabad'),
(7,'Garden City Bloodbank','Bangalore'),(8,'Pink City Blood Centre','Jaipur'),(9,'Gomti Haematology Unit','Lucknow'),(10,'Coastal Blood Hub','Goa');

INSERT INTO ROLE (role_id, role_name) VALUES
(1,'Manager'),(2,'Technician'),(3,'Supervisor'),(4,'Assistant');

-- FIX #13: STAFF sample data
INSERT INTO STAFF (name, role_id, bank_id) VALUES
('Ravi Kumar',1,1),('Priya Sharma',2,1),('Anil Mehta',3,2),
('Sunita Das',4,2),('Raj Patel',1,3),('Meena Iyer',2,3),
('Vikram Singh',3,4),('Neha Gupta',4,4),('Arjun Reddy',1,5),
('Kavya Nair',2,5);

INSERT INTO GEO_LOCATION (location_id, latitude, longitude, city) VALUES
(1,28.6139,77.2090,'Delhi'),
(2,19.0760,72.8777,'Mumbai'),
(3,13.0827,80.2707,'Chennai'),
(4,22.5726,88.3639,'Kolkata'),
(5,18.5204,73.8567,'Pune');

INSERT INTO HOSPITAL (hospital_id, name, location) VALUES
(1,'AIIMS Delhi','Delhi'),(2,'Kokilaben Dhirubhai Ambani Hospital','Mumbai'),(3,'Apollo Hospitals Chennai','Chennai'),
(4,'Fortis Kolkata','Kolkata'),(5,'Ruby Hall Clinic','Pune'),(6,'Yashoda Hospitals','Hyderabad'),
(7,'Manipal Hospital Bangalore','Bangalore'),(8,'SMS Medical College','Jaipur'),(9,'KGMU Lucknow','Lucknow'),(10,'Goa Medical College','Goa');

INSERT INTO DONOR (name, age, blood_group, last_donation_date, contact) VALUES
('Arjun Sharma',22,'A+','2025-01-01','9000000001'),('Priya Mehta',23,'B+','2025-01-02','9000000002'),
('Rohan Verma',24,'O+','2025-01-03','9000000003'),('Sunita Rao',25,'AB+','2025-01-04','9000000004'),
('Vikram Nair',26,'A-','2025-01-05','9000000005'),('Kavya Iyer',27,'B-','2025-01-06','9000000006'),
('Aditya Patel',28,'O-','2025-01-07','9000000007'),('Meera Joshi',29,'AB-','2025-01-08','9000000008'),
('Suresh Kumar',22,'A+','2025-01-09','9000000009'),('Divya Reddy',23,'B+','2025-01-10','9000000010'),
('Karthik Balan',24,'O+','2025-01-11','9000000011'),('Ananya Singh',25,'AB+','2025-01-12','9000000012'),
('Rahul Chowdhury',26,'A-','2025-01-13','9000000013'),('Sneha Das',27,'B-','2025-01-14','9000000014'),
('Manish Tiwari',28,'O-','2025-01-15','9000000015'),('Pooja Malhotra',29,'AB-','2025-01-16','9000000016'),
('Deepak Gupta',22,'A+','2025-01-17','9000000017'),('Rashmi Shetty',23,'B+','2025-01-18','9000000018'),
('Nikhil Kapoor',24,'O+','2025-01-19','9000000019'),('Swathi Pillai',25,'AB+','2025-01-20','9000000020'),
('Ajay Yadav',26,'A-','2025-01-21','9000000021'),('Lakshmi Nair',27,'B-','2025-01-22','9000000022'),
('Sunil Rathore',28,'O-','2025-01-23','9000000023'),('Geeta Bhatt',29,'AB-','2025-01-24','9000000024'),
('Harish Menon',22,'A+','2025-01-25','9000000025'),('Ritu Srivastava',23,'B+','2025-01-26','9000000026'),
('Pranav Jain',24,'O+','2025-01-27','9000000027'),('Nisha Agarwal',25,'AB+','2025-01-28','9000000028'),
('Sanjay Patil',26,'A-','2025-01-29','9000000029'),('Bindiya Choudhary',27,'B-','2025-01-30','9000000030'),
('Rajesh Tripathi',28,'O-','2025-02-01','9000000031'),('Usha Venkat',29,'AB-','2025-02-02','9000000032'),
('Anil Kumar',22,'A+','2025-02-03','9000000033'),('Durga Pandey',23,'B+','2025-02-04','9000000034'),
('Vijay Desai',24,'O+','2025-02-05','9000000035'),('Madhuri Bose',25,'AB+','2025-02-06','9000000036'),
('Tarun Khanna',26,'A-','2025-02-07','9000000037'),('Priyanka Nambiar',27,'B-','2025-02-08','9000000038'),
('Sameer Saxena',28,'O-','2025-02-09','9000000039'),('Leela Krishnan',29,'AB-','2025-02-10','9000000040');

-- FIX #14: DONOR_LOCATION sample data
INSERT INTO DONOR_LOCATION (donor_id, location_id) VALUES
(1,1),(2,2),(3,3),(4,4),(5,5),(6,1),(7,2),(8,3),(9,4),(10,5);

-- Trigger after_donation_insert fires → auto-creates BLOOD_UNIT with blood_group
INSERT INTO DONATION (donor_id, bank_id, donation_date) VALUES
(1,1,CURDATE()),(2,2,CURDATE()),(3,3,CURDATE()),(4,4,CURDATE()),
(5,5,CURDATE()),(6,6,CURDATE()),(7,7,CURDATE()),(8,8,CURDATE()),
(9,9,CURDATE()),(10,10,CURDATE()),
(11,1,CURDATE()),(12,2,CURDATE()),(13,3,CURDATE()),(14,4,CURDATE()),
(15,5,CURDATE()),(16,6,CURDATE()),(17,7,CURDATE()),(18,8,CURDATE()),
(19,9,CURDATE()),(20,10,CURDATE()),
(21,1,CURDATE()),(22,2,CURDATE()),(23,3,CURDATE()),(24,4,CURDATE()),
(25,5,CURDATE()),(26,6,CURDATE()),(27,7,CURDATE()),(28,8,CURDATE()),
(29,9,CURDATE()),(30,10,CURDATE()),
(31,1,CURDATE()),(32,2,CURDATE()),(33,3,CURDATE()),(34,4,CURDATE()),
(35,5,CURDATE()),(36,6,CURDATE()),(37,7,CURDATE()),(38,8,CURDATE()),
(39,9,CURDATE()),(40,10,CURDATE());

-- Trigger before_request_insert sets status; after_request_insert marks units Used
INSERT INTO REQUEST (hospital_id, blood_group, units_required, request_date) VALUES
(1,'A+',1,CURDATE()),(2,'B+',2,CURDATE()),(3,'O+',1,CURDATE()),(4,'AB+',2,CURDATE()),
(5,'A-',1,CURDATE()),(6,'B-',2,CURDATE()),(7,'O-',1,CURDATE()),(8,'AB-',2,CURDATE()),
(9,'A+',1,CURDATE()),(10,'B+',2,CURDATE()),
(1,'O+',1,CURDATE()),(2,'AB+',2,CURDATE()),(3,'A-',1,CURDATE()),(4,'B-',2,CURDATE()),
(5,'O-',1,CURDATE()),(6,'AB-',2,CURDATE()),(7,'A+',1,CURDATE()),(8,'B+',2,CURDATE()),
(9,'O+',1,CURDATE()),(10,'AB+',2,CURDATE());

-- FIX #13: TEMPERATURE_LOG seed data
INSERT INTO TEMPERATURE_LOG (unit_id, temperature, recorded_at) VALUES
(1,4.2,NOW()),(2,3.8,NOW()),(3,4.5,NOW()),(4,4.0,NOW()),(5,3.9,NOW()),
(6,4.1,NOW()),(7,4.3,NOW()),(8,3.7,NOW()),(9,4.4,NOW()),(10,4.0,NOW());

-- ══════════════════════════════════════════════════════════════
--  VERIFICATION
-- ══════════════════════════════════════════════════════════════

SELECT 'DONORS'           AS entity, COUNT(*) AS total FROM DONOR        UNION ALL
SELECT 'BLOOD_UNITS',      COUNT(*) FROM BLOOD_UNIT                       UNION ALL
SELECT 'DONATIONS',        COUNT(*) FROM DONATION                         UNION ALL
SELECT 'REQUESTS',         COUNT(*) FROM REQUEST                          UNION ALL
SELECT 'STAFF',            COUNT(*) FROM STAFF                            UNION ALL
SELECT 'TEMP_LOGS',        COUNT(*) FROM TEMPERATURE_LOG                  UNION ALL
SELECT 'COMPATIBILITY',    COUNT(*) FROM COMPATIBILITY                     UNION ALL
SELECT 'NOTIFICATIONS',    COUNT(*) FROM NOTIFICATION_LOG;

-- Quick sanity: confirm no expired units were counted as available
SELECT 'Units Available (non-expired)' AS check_name,
       COUNT(*) AS count
FROM BLOOD_UNIT
WHERE status = 'Available' AND expiry_date >= CURDATE();

SELECT 'Units Marked Used' AS check_name, COUNT(*) AS count
FROM BLOOD_UNIT WHERE status = 'Used';

SELECT * FROM DONOR;
