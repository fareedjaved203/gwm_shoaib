-- =====================================================================
-- Global Waste Management (GWM) - complete Oracle database build
-- Run as a DBA (e.g. SYSTEM) connected to the pluggable database:
--   sqlplus system@//host:1521/FREEPDB1 @gwm_database.sql
-- Creates the GWM_OWNER schema (dropping any previous copy), all tables,
-- indexes, triggers, sample data, dashboard views, security objects,
-- dashboard output queries and integrity tests.
-- Change the schema password below before using outside a test system.
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE ON
DEFINE gwm_password = GwmOwner_2026
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Drop previous copy of the schema
BEGIN
    FOR p IN (SELECT DISTINCT policy_name FROM audit_unified_policies
               WHERE policy_name IN ('GWM_PII_ACCESS_POL','GWM_PRIVILEGE_CHANGE_POL')) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'NOAUDIT POLICY ' || p.policy_name;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        EXECUTE IMMEDIATE 'DROP AUDIT POLICY ' || p.policy_name;
    END LOOP;
    FOR u IN (SELECT username FROM dba_users WHERE username = 'GWM_OWNER') LOOP
        EXECUTE IMMEDIATE 'DROP USER gwm_owner CASCADE';
    END LOOP;
END;
/

-- Create Schema Owner
CREATE USER gwm_owner IDENTIFIED BY "&gwm_password" DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CREATE SESSION TO gwm_owner;
SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = gwm_owner;

-- =====================================================================
-- SECTION 1 - TABLES
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF

-- ---------------------------------------------------------------------
-- Create Table for State (locality reference)
-- ---------------------------------------------------------------------
CREATE TABLE state (
    state_code   VARCHAR2(3)   NOT NULL,
    state_name   VARCHAR2(50)  NOT NULL,
    CONSTRAINT pk_state PRIMARY KEY (state_code),
    CONSTRAINT uq_state_name UNIQUE (state_name),
    CONSTRAINT ck_state_code CHECK (state_code IN ('NSW','VIC','QLD','SA','WA','TAS','ACT','NT'))
);

-- ---------------------------------------------------------------------
-- Create Table for Council (local government administration)
-- ---------------------------------------------------------------------
CREATE TABLE council (
    council_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    state_code     VARCHAR2(3)    NOT NULL,
    council_name   VARCHAR2(120)  NOT NULL,
    contact_email  VARCHAR2(150),
    contact_phone  VARCHAR2(20),
    waste_levy_per_tonne NUMBER(10,2) DEFAULT 0 NOT NULL,
    CONSTRAINT pk_council PRIMARY KEY (council_id),
    CONSTRAINT fk_council_state FOREIGN KEY (state_code) REFERENCES state (state_code),
    CONSTRAINT uq_council_name UNIQUE (state_code, council_name),
    CONSTRAINT uq_council_id_state UNIQUE (council_id, state_code),
    CONSTRAINT ck_council_levy CHECK (waste_levy_per_tonne >= 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Address (shared by billing, delivery, depot, staff, facility)
-- ---------------------------------------------------------------------
CREATE TABLE address (
    address_id    NUMBER GENERATED ALWAYS AS IDENTITY,
    street_line1  VARCHAR2(150) NOT NULL,
    street_line2  VARCHAR2(150),
    suburb        VARCHAR2(80)  NOT NULL,
    state_code    VARCHAR2(3)   NOT NULL,
    postcode      VARCHAR2(4)   NOT NULL,
    council_id    NUMBER        NOT NULL,
    latitude      NUMBER(9,6),
    longitude     NUMBER(9,6),
    CONSTRAINT pk_address PRIMARY KEY (address_id),
    CONSTRAINT fk_address_state   FOREIGN KEY (state_code) REFERENCES state (state_code),
    CONSTRAINT fk_address_council FOREIGN KEY (council_id, state_code) REFERENCES council (council_id, state_code),
    CONSTRAINT ck_address_postcode CHECK (REGEXP_LIKE(postcode, '^[0-9]{4}$')),
    CONSTRAINT ck_address_lat CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_address_lon CHECK (longitude BETWEEN -180 AND 180)
);

-- ---------------------------------------------------------------------
-- Create Table for Waste Category
-- ---------------------------------------------------------------------
CREATE TABLE waste_category (
    category_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    category_code   VARCHAR2(10)  NOT NULL,
    category_name   VARCHAR2(60)  NOT NULL,
    weight_class    VARCHAR2(5)   NOT NULL,
    description     VARCHAR2(300),
    CONSTRAINT pk_waste_category PRIMARY KEY (category_id),
    CONSTRAINT uq_waste_category_code UNIQUE (category_code),
    CONSTRAINT ck_waste_category_code CHECK (category_code IN ('MIXED','BUILDING','CONCRETE','DIRT')),
    CONSTRAINT ck_waste_category_class CHECK (weight_class IN ('LIGHT','HEAVY'))
);

-- ---------------------------------------------------------------------
-- Create Table for Council Facility (dump or recycling centre)
-- ---------------------------------------------------------------------
CREATE TABLE council_facility (
    facility_id        NUMBER GENERATED ALWAYS AS IDENTITY,
    council_id         NUMBER        NOT NULL,
    address_id         NUMBER        NOT NULL,
    facility_name      VARCHAR2(120) NOT NULL,
    facility_type      VARCHAR2(10)  NOT NULL,
    gate_fee_per_tonne NUMBER(10,2)  DEFAULT 0 NOT NULL,
    operating_hours    VARCHAR2(100),
    is_active          NUMBER(1)     DEFAULT 1 NOT NULL,
    CONSTRAINT pk_council_facility PRIMARY KEY (facility_id),
    CONSTRAINT fk_facility_council FOREIGN KEY (council_id) REFERENCES council (council_id),
    CONSTRAINT fk_facility_address FOREIGN KEY (address_id) REFERENCES address (address_id),
    CONSTRAINT uq_facility_name UNIQUE (council_id, facility_name),
    CONSTRAINT ck_facility_type CHECK (facility_type IN ('DUMP','RECYCLING')),
    CONSTRAINT ck_facility_fee CHECK (gate_fee_per_tonne >= 0),
    CONSTRAINT ck_facility_active CHECK (is_active IN (0,1))
);

-- ---------------------------------------------------------------------
-- Create Table for Facility Accepted Category (resolves M:N)
-- ---------------------------------------------------------------------
CREATE TABLE facility_accepted_category (
    facility_id  NUMBER NOT NULL,
    category_id  NUMBER NOT NULL,
    CONSTRAINT pk_facility_accepted_category PRIMARY KEY (facility_id, category_id),
    CONSTRAINT fk_fac_acc_facility FOREIGN KEY (facility_id) REFERENCES council_facility (facility_id),
    CONSTRAINT fk_fac_acc_category FOREIGN KEY (category_id) REFERENCES waste_category (category_id)
);

-- ---------------------------------------------------------------------
-- Create Table for Tin Size
-- ---------------------------------------------------------------------
CREATE TABLE tin_size (
    tin_size_id   NUMBER GENERATED ALWAYS AS IDENTITY,
    size_code     VARCHAR2(10)  NOT NULL,
    volume_m3     NUMBER(4,1)   NOT NULL,
    max_load_kg   NUMBER(8)     NOT NULL,
    description   VARCHAR2(200),
    CONSTRAINT pk_tin_size PRIMARY KEY (tin_size_id),
    CONSTRAINT uq_tin_size_code UNIQUE (size_code),
    CONSTRAINT uq_tin_size_volume UNIQUE (volume_m3),
    CONSTRAINT ck_tin_size_volume CHECK (volume_m3 > 0),
    CONSTRAINT ck_tin_size_load CHECK (max_load_kg > 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Category Tin Size (which sizes may carry which waste; resolves M:N)
-- ---------------------------------------------------------------------
CREATE TABLE category_tin_size (
    category_id  NUMBER NOT NULL,
    tin_size_id  NUMBER NOT NULL,
    CONSTRAINT pk_category_tin_size PRIMARY KEY (category_id, tin_size_id),
    CONSTRAINT fk_cts_category FOREIGN KEY (category_id) REFERENCES waste_category (category_id),
    CONSTRAINT fk_cts_size     FOREIGN KEY (tin_size_id) REFERENCES tin_size (tin_size_id)
);

-- ---------------------------------------------------------------------
-- Create Table for Tin Price (price per permitted category/size/state/date)
-- ---------------------------------------------------------------------
CREATE TABLE tin_price (
    tin_price_id   NUMBER GENERATED ALWAYS AS IDENTITY,
    category_id    NUMBER       NOT NULL,
    tin_size_id    NUMBER       NOT NULL,
    state_code     VARCHAR2(3)  NOT NULL,
    hire_price     NUMBER(10,2) NOT NULL,
    effective_from DATE         NOT NULL,
    CONSTRAINT pk_tin_price PRIMARY KEY (tin_price_id),
    CONSTRAINT fk_tin_price_combo    FOREIGN KEY (category_id, tin_size_id)
                                     REFERENCES category_tin_size (category_id, tin_size_id),
    CONSTRAINT fk_tin_price_state    FOREIGN KEY (state_code)  REFERENCES state (state_code),
    CONSTRAINT uq_tin_price UNIQUE (category_id, tin_size_id, state_code, effective_from),
    CONSTRAINT ck_tin_price_amount CHECK (hire_price > 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Depot
-- ---------------------------------------------------------------------
CREATE TABLE depot (
    depot_id    NUMBER GENERATED ALWAYS AS IDENTITY,
    address_id  NUMBER        NOT NULL,
    depot_name  VARCHAR2(100) NOT NULL,
    phone       VARCHAR2(20),
    CONSTRAINT pk_depot PRIMARY KEY (depot_id),
    CONSTRAINT fk_depot_address FOREIGN KEY (address_id) REFERENCES address (address_id),
    CONSTRAINT uq_depot_name UNIQUE (depot_name),
    CONSTRAINT uq_depot_address UNIQUE (address_id)
);

-- ---------------------------------------------------------------------
-- Create Table for Outsource Supplier (external vehicles and staff)
-- ---------------------------------------------------------------------
CREATE TABLE outsource_supplier (
    supplier_id          NUMBER GENERATED ALWAYS AS IDENTITY,
    supplier_name        VARCHAR2(120) NOT NULL,
    abn                  VARCHAR2(11)  NOT NULL,
    contact_name         VARCHAR2(100),
    contact_email        VARCHAR2(150),
    contact_phone        VARCHAR2(20),
    daily_vehicle_rate   NUMBER(10,2)  NOT NULL,
    hourly_staff_rate    NUMBER(10,2)  NOT NULL,
    contract_start       DATE          NOT NULL,
    contract_end         DATE,
    supplier_status      VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_outsource_supplier PRIMARY KEY (supplier_id),
    CONSTRAINT uq_supplier_abn UNIQUE (abn),
    CONSTRAINT ck_supplier_abn CHECK (REGEXP_LIKE(abn, '^[0-9]{11}$')),
    CONSTRAINT ck_supplier_rates CHECK (daily_vehicle_rate >= 0 AND hourly_staff_rate >= 0),
    CONSTRAINT ck_supplier_dates CHECK (contract_end IS NULL OR contract_end >= contract_start),
    CONSTRAINT ck_supplier_status CHECK (supplier_status IN ('ACTIVE','SUSPENDED','ENDED'))
);

-- ---------------------------------------------------------------------
-- Create Table for Vehicle (company-owned and outsourced)
-- ---------------------------------------------------------------------
CREATE TABLE vehicle (
    vehicle_id        NUMBER GENERATED ALWAYS AS IDENTITY,
    registration_no   VARCHAR2(10)  NOT NULL,
    vehicle_type      VARCHAR2(15)  NOT NULL,
    make              VARCHAR2(50)  NOT NULL,
    model             VARCHAR2(50)  NOT NULL,
    year_built        NUMBER(4)     NOT NULL,
    capacity_tonnes   NUMBER(5,2)   NOT NULL,
    ownership         VARCHAR2(10)  NOT NULL,
    depot_id          NUMBER,
    supplier_id       NUMBER,
    vehicle_status    VARCHAR2(15)  DEFAULT 'AVAILABLE' NOT NULL,
    next_service_due  DATE,
    CONSTRAINT pk_vehicle PRIMARY KEY (vehicle_id),
    CONSTRAINT uq_vehicle_rego UNIQUE (registration_no),
    CONSTRAINT fk_vehicle_depot    FOREIGN KEY (depot_id)    REFERENCES depot (depot_id),
    CONSTRAINT fk_vehicle_supplier FOREIGN KEY (supplier_id) REFERENCES outsource_supplier (supplier_id),
    CONSTRAINT ck_vehicle_type CHECK (vehicle_type IN ('SKIP_TRUCK','HOOK_LIFT','TIPPER','VAN')),
    CONSTRAINT ck_vehicle_year CHECK (year_built BETWEEN 1980 AND 2100),
    CONSTRAINT ck_vehicle_capacity CHECK (capacity_tonnes > 0),
    CONSTRAINT ck_vehicle_status CHECK (vehicle_status IN ('AVAILABLE','IN_USE','MAINTENANCE','RETIRED')),
    CONSTRAINT ck_vehicle_ownership CHECK (
        (ownership = 'OWNED'      AND depot_id IS NOT NULL AND supplier_id IS NULL) OR
        (ownership = 'OUTSOURCED' AND supplier_id IS NOT NULL AND depot_id IS NULL)
    )
);

-- ---------------------------------------------------------------------
-- Create Table for Vehicle Maintenance
-- ---------------------------------------------------------------------
CREATE TABLE vehicle_maintenance (
    maintenance_id    NUMBER GENERATED ALWAYS AS IDENTITY,
    vehicle_id        NUMBER        NOT NULL,
    service_date      DATE          NOT NULL,
    maintenance_type  VARCHAR2(15)  NOT NULL,
    odometer_km       NUMBER(8)     NOT NULL,
    cost              NUMBER(10,2)  NOT NULL,
    notes             VARCHAR2(300),
    CONSTRAINT pk_vehicle_maintenance PRIMARY KEY (maintenance_id),
    CONSTRAINT fk_maint_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id),
    CONSTRAINT ck_maint_type CHECK (maintenance_type IN ('SERVICE','REPAIR','INSPECTION','TYRES')),
    CONSTRAINT ck_maint_cost CHECK (cost >= 0),
    CONSTRAINT ck_maint_odo CHECK (odometer_km >= 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Smart Tin (IoT-enabled bin)
-- ---------------------------------------------------------------------
CREATE TABLE smart_tin (
    tin_id            NUMBER GENERATED ALWAYS AS IDENTITY,
    tin_serial        VARCHAR2(20)  NOT NULL,
    tin_size_id       NUMBER        NOT NULL,
    depot_id          NUMBER        NOT NULL,
    device_imei       VARCHAR2(15)  NOT NULL,
    firmware_version  VARCHAR2(20),
    tin_status        VARCHAR2(12)  DEFAULT 'AVAILABLE' NOT NULL,
    purchase_date     DATE          NOT NULL,
    last_seen_at      TIMESTAMP,
    CONSTRAINT pk_smart_tin PRIMARY KEY (tin_id),
    CONSTRAINT uq_smart_tin_serial UNIQUE (tin_serial),
    CONSTRAINT uq_smart_tin_imei   UNIQUE (device_imei),
    CONSTRAINT uq_smart_tin_id_size UNIQUE (tin_id, tin_size_id),
    CONSTRAINT fk_tin_size  FOREIGN KEY (tin_size_id) REFERENCES tin_size (tin_size_id),
    CONSTRAINT fk_tin_depot FOREIGN KEY (depot_id)    REFERENCES depot (depot_id),
    CONSTRAINT ck_tin_imei CHECK (REGEXP_LIKE(device_imei, '^[0-9]{15}$')),
    CONSTRAINT ck_tin_status CHECK (tin_status IN ('AVAILABLE','DEPLOYED','MAINTENANCE','RETIRED'))
);

-- ---------------------------------------------------------------------
-- Create Table for Tin Telemetry (IoT sensor readings)
-- ---------------------------------------------------------------------
CREATE TABLE tin_telemetry (
    telemetry_id   NUMBER GENERATED ALWAYS AS IDENTITY,
    tin_id         NUMBER       NOT NULL,
    recorded_at    TIMESTAMP    NOT NULL,
    fill_level_pct NUMBER(5,2)  NOT NULL,
    weight_kg      NUMBER(8,2)  NOT NULL,
    latitude       NUMBER(9,6),
    longitude      NUMBER(9,6),
    battery_pct    NUMBER(5,2),
    tamper_flag    NUMBER(1)    DEFAULT 0 NOT NULL,
    CONSTRAINT pk_tin_telemetry PRIMARY KEY (telemetry_id),
    CONSTRAINT fk_telemetry_tin FOREIGN KEY (tin_id) REFERENCES smart_tin (tin_id),
    CONSTRAINT uq_telemetry_tin_time UNIQUE (tin_id, recorded_at),
    CONSTRAINT ck_telemetry_fill CHECK (fill_level_pct BETWEEN 0 AND 100),
    CONSTRAINT ck_telemetry_weight CHECK (weight_kg >= 0),
    CONSTRAINT ck_telemetry_battery CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
    CONSTRAINT ck_telemetry_tamper CHECK (tamper_flag IN (0,1))
);

-- ---------------------------------------------------------------------
-- Create Table for Job Position (HR)
-- ---------------------------------------------------------------------
CREATE TABLE job_position (
    position_id         NUMBER GENERATED ALWAYS AS IDENTITY,
    position_title      VARCHAR2(60)  NOT NULL,
    base_hourly_rate    NUMBER(8,2)   NOT NULL,
    requires_licence    NUMBER(1)     DEFAULT 0 NOT NULL,
    CONSTRAINT pk_job_position PRIMARY KEY (position_id),
    CONSTRAINT uq_job_position_title UNIQUE (position_title),
    CONSTRAINT ck_position_rate CHECK (base_hourly_rate > 0),
    CONSTRAINT ck_position_licence CHECK (requires_licence IN (0,1))
);

-- ---------------------------------------------------------------------
-- Create Table for Staff (employees and outsourced contractors)
-- ---------------------------------------------------------------------
CREATE TABLE staff (
    staff_id           NUMBER GENERATED ALWAYS AS IDENTITY,
    employment_type    VARCHAR2(10)  NOT NULL,
    depot_id           NUMBER,
    supplier_id        NUMBER,
    position_id        NUMBER        NOT NULL,
    address_id         NUMBER,
    first_name         VARCHAR2(60)  NOT NULL,
    last_name          VARCHAR2(60)  NOT NULL,
    date_of_birth      DATE          NOT NULL,
    email              VARCHAR2(150) NOT NULL,
    phone              VARCHAR2(20),
    licence_no         VARCHAR2(20),
    licence_class      VARCHAR2(5),
    licence_expiry     DATE,
    hire_date          DATE          NOT NULL,
    termination_date   DATE,
    hourly_rate        NUMBER(8,2)   NOT NULL,
    staff_status       VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_staff PRIMARY KEY (staff_id),
    CONSTRAINT uq_staff_email UNIQUE (email),
    CONSTRAINT uq_staff_licence UNIQUE (licence_no),
    CONSTRAINT fk_staff_depot    FOREIGN KEY (depot_id)    REFERENCES depot (depot_id),
    CONSTRAINT fk_staff_supplier FOREIGN KEY (supplier_id) REFERENCES outsource_supplier (supplier_id),
    CONSTRAINT fk_staff_position FOREIGN KEY (position_id) REFERENCES job_position (position_id),
    CONSTRAINT fk_staff_address  FOREIGN KEY (address_id)  REFERENCES address (address_id),
    CONSTRAINT ck_staff_type CHECK (employment_type IN ('EMPLOYEE','CONTRACTOR')),
    CONSTRAINT ck_staff_status CHECK (staff_status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
    CONSTRAINT ck_staff_rate CHECK (hourly_rate > 0),
    CONSTRAINT ck_staff_term CHECK (termination_date IS NULL OR termination_date >= hire_date),
    CONSTRAINT ck_staff_licence CHECK (
        (licence_no IS NULL AND licence_class IS NULL AND licence_expiry IS NULL) OR
        (licence_no IS NOT NULL AND licence_class IS NOT NULL AND licence_expiry IS NOT NULL)
    ),
    CONSTRAINT ck_staff_employment CHECK (
        (employment_type = 'EMPLOYEE'   AND depot_id IS NOT NULL AND supplier_id IS NULL) OR
        (employment_type = 'CONTRACTOR' AND supplier_id IS NOT NULL AND depot_id IS NULL)
    )
);

-- ---------------------------------------------------------------------
-- Create Table for Roster Shift (rostering management)
-- ---------------------------------------------------------------------
CREATE TABLE roster_shift (
    shift_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    staff_id      NUMBER        NOT NULL,
    vehicle_id    NUMBER,
    shift_start   TIMESTAMP     NOT NULL,
    shift_end     TIMESTAMP     NOT NULL,
    shift_status  VARCHAR2(10)  DEFAULT 'SCHEDULED' NOT NULL,
    CONSTRAINT pk_roster_shift PRIMARY KEY (shift_id),
    CONSTRAINT fk_shift_staff   FOREIGN KEY (staff_id)   REFERENCES staff (staff_id),
    CONSTRAINT fk_shift_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id),
    CONSTRAINT uq_shift_staff_start UNIQUE (staff_id, shift_start),
    CONSTRAINT ck_shift_times CHECK (shift_end > shift_start),
    CONSTRAINT ck_shift_status CHECK (shift_status IN ('SCHEDULED','WORKED','ABSENT','CANCELLED'))
);

-- ---------------------------------------------------------------------
-- Create Table for Leave Request (HR)
-- ---------------------------------------------------------------------
CREATE TABLE leave_request (
    leave_id       NUMBER GENERATED ALWAYS AS IDENTITY,
    staff_id       NUMBER       NOT NULL,
    approver_id    NUMBER,
    leave_type     VARCHAR2(10) NOT NULL,
    start_date     DATE         NOT NULL,
    end_date       DATE         NOT NULL,
    leave_status   VARCHAR2(10) DEFAULT 'PENDING' NOT NULL,
    CONSTRAINT pk_leave_request PRIMARY KEY (leave_id),
    CONSTRAINT fk_leave_staff    FOREIGN KEY (staff_id)    REFERENCES staff (staff_id),
    CONSTRAINT fk_leave_approver FOREIGN KEY (approver_id) REFERENCES staff (staff_id),
    CONSTRAINT ck_leave_type CHECK (leave_type IN ('ANNUAL','SICK','UNPAID','CARER')),
    CONSTRAINT ck_leave_status CHECK (leave_status IN ('PENDING','APPROVED','REJECTED')),
    CONSTRAINT ck_leave_dates CHECK (end_date >= start_date),
    CONSTRAINT ck_leave_self CHECK (approver_id IS NULL OR approver_id <> staff_id)
);

-- ---------------------------------------------------------------------
-- Create Table for Timesheet (hours actually worked, optionally tied to a rostered shift)
-- ---------------------------------------------------------------------
CREATE TABLE timesheet (
    timesheet_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    staff_id          NUMBER        NOT NULL,
    shift_id          NUMBER,
    approver_id       NUMBER,
    work_date         DATE          NOT NULL,
    clock_in          TIMESTAMP     NOT NULL,
    clock_out         TIMESTAMP     NOT NULL,
    break_minutes     NUMBER(3)     DEFAULT 0 NOT NULL,
    regular_hours     NUMBER(5,2)   NOT NULL,
    overtime_hours    NUMBER(5,2)   DEFAULT 0 NOT NULL,
    timesheet_status  VARCHAR2(10)  DEFAULT 'SUBMITTED' NOT NULL,
    CONSTRAINT pk_timesheet PRIMARY KEY (timesheet_id),
    CONSTRAINT uq_timesheet_shift UNIQUE (shift_id),
    CONSTRAINT uq_timesheet_staff_in UNIQUE (staff_id, clock_in),
    CONSTRAINT fk_timesheet_staff    FOREIGN KEY (staff_id)    REFERENCES staff (staff_id),
    CONSTRAINT fk_timesheet_shift    FOREIGN KEY (shift_id)    REFERENCES roster_shift (shift_id),
    CONSTRAINT fk_timesheet_approver FOREIGN KEY (approver_id) REFERENCES staff (staff_id),
    CONSTRAINT ck_timesheet_times CHECK (clock_out > clock_in),
    CONSTRAINT ck_timesheet_break CHECK (break_minutes BETWEEN 0 AND 240),
    CONSTRAINT ck_timesheet_hours CHECK (regular_hours >= 0 AND overtime_hours >= 0),
    CONSTRAINT ck_timesheet_status CHECK (timesheet_status IN ('SUBMITTED','APPROVED','REJECTED')),
    CONSTRAINT ck_timesheet_approval CHECK (timesheet_status <> 'APPROVED' OR approver_id IS NOT NULL),
    CONSTRAINT ck_timesheet_self CHECK (approver_id IS NULL OR approver_id <> staff_id)
);

-- ---------------------------------------------------------------------
-- Create Table for Pay Period (payroll cycle)
-- ---------------------------------------------------------------------
CREATE TABLE pay_period (
    pay_period_id  NUMBER GENERATED ALWAYS AS IDENTITY,
    period_start   DATE         NOT NULL,
    period_end     DATE         NOT NULL,
    pay_date       DATE         NOT NULL,
    period_status  VARCHAR2(10) DEFAULT 'OPEN' NOT NULL,
    CONSTRAINT pk_pay_period PRIMARY KEY (pay_period_id),
    CONSTRAINT uq_pay_period_start UNIQUE (period_start),
    CONSTRAINT ck_pay_period_dates CHECK (period_end >= period_start AND pay_date > period_end),
    CONSTRAINT ck_pay_period_status CHECK (period_status IN ('OPEN','CLOSED','PAID'))
);

-- ---------------------------------------------------------------------
-- Create Table for Payslip (one per employee per pay period)
-- ---------------------------------------------------------------------
CREATE TABLE payslip (
    payslip_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    pay_period_id   NUMBER        NOT NULL,
    staff_id        NUMBER        NOT NULL,
    regular_hours   NUMBER(7,2)   NOT NULL,
    overtime_hours  NUMBER(7,2)   NOT NULL,
    hourly_rate     NUMBER(8,2)   NOT NULL,
    gross_pay       NUMBER(12,2)  NOT NULL,
    tax_withheld    NUMBER(12,2)  NOT NULL,
    super_amount    NUMBER(12,2)  NOT NULL,
    net_pay         NUMBER(12,2)  NOT NULL,
    CONSTRAINT pk_payslip PRIMARY KEY (payslip_id),
    CONSTRAINT uq_payslip_period_staff UNIQUE (pay_period_id, staff_id),
    CONSTRAINT fk_payslip_period FOREIGN KEY (pay_period_id) REFERENCES pay_period (pay_period_id),
    CONSTRAINT fk_payslip_staff  FOREIGN KEY (staff_id)      REFERENCES staff (staff_id),
    CONSTRAINT ck_payslip_hours CHECK (regular_hours >= 0 AND overtime_hours >= 0),
    CONSTRAINT ck_payslip_rate CHECK (hourly_rate > 0),
    CONSTRAINT ck_payslip_amounts CHECK (gross_pay >= 0 AND tax_withheld >= 0 AND super_amount >= 0 AND net_pay >= 0),
    CONSTRAINT ck_payslip_gross CHECK (gross_pay = ROUND(regular_hours * hourly_rate + overtime_hours * hourly_rate * 1.5, 2)),
    CONSTRAINT ck_payslip_net CHECK (net_pay = gross_pay - tax_withheld)
);

-- ---------------------------------------------------------------------
-- Create Table for Customer (billing address held here)
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id         NUMBER GENERATED ALWAYS AS IDENTITY,
    customer_type       VARCHAR2(12)  NOT NULL,
    first_name          VARCHAR2(60),
    last_name           VARCHAR2(60),
    company_name        VARCHAR2(120),
    abn                 VARCHAR2(11),
    email               VARCHAR2(150) NOT NULL,
    phone               VARCHAR2(20)  NOT NULL,
    billing_address_id  NUMBER        NOT NULL,
    credit_limit        NUMBER(12,2)  DEFAULT 0 NOT NULL,
    customer_status     VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL,
    created_at          TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_customer PRIMARY KEY (customer_id),
    CONSTRAINT uq_customer_email UNIQUE (email),
    CONSTRAINT uq_customer_abn UNIQUE (abn),
    CONSTRAINT fk_customer_billing FOREIGN KEY (billing_address_id) REFERENCES address (address_id),
    CONSTRAINT ck_customer_type CHECK (customer_type IN ('RESIDENTIAL','COMMERCIAL','GOVERNMENT')),
    CONSTRAINT ck_customer_status CHECK (customer_status IN ('ACTIVE','SUSPENDED','CLOSED')),
    CONSTRAINT ck_customer_credit CHECK (credit_limit >= 0),
    CONSTRAINT ck_customer_abn CHECK (abn IS NULL OR REGEXP_LIKE(abn, '^[0-9]{11}$')),
    CONSTRAINT ck_customer_identity CHECK (
        (customer_type = 'RESIDENTIAL' AND first_name IS NOT NULL AND last_name IS NOT NULL) OR
        (customer_type IN ('COMMERCIAL','GOVERNMENT') AND company_name IS NOT NULL AND abn IS NOT NULL)
    )
);

-- ---------------------------------------------------------------------
-- Create Table for Customer Order (delivery address kept separate)
-- ---------------------------------------------------------------------
CREATE TABLE customer_order (
    order_id             NUMBER GENERATED ALWAYS AS IDENTITY,
    order_number         VARCHAR2(20)  NOT NULL,
    customer_id          NUMBER        NOT NULL,
    billing_address_id   NUMBER        NOT NULL,
    delivery_address_id  NUMBER        NOT NULL,
    ordered_at           TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    requested_delivery   DATE          NOT NULL,
    requested_pickup     DATE          NOT NULL,
    site_contact_name    VARCHAR2(100),
    site_contact_phone   VARCHAR2(20),
    order_status         VARCHAR2(12)  DEFAULT 'PLACED' NOT NULL,
    notes                VARCHAR2(500),
    CONSTRAINT pk_customer_order PRIMARY KEY (order_id),
    CONSTRAINT uq_order_number UNIQUE (order_number),
    CONSTRAINT fk_order_customer FOREIGN KEY (customer_id)         REFERENCES customer (customer_id),
    CONSTRAINT fk_order_billing  FOREIGN KEY (billing_address_id)  REFERENCES address (address_id),
    CONSTRAINT fk_order_delivery FOREIGN KEY (delivery_address_id) REFERENCES address (address_id),
    CONSTRAINT ck_order_status CHECK (order_status IN ('PLACED','SCHEDULED','DELIVERED','COMPLETED','CANCELLED')),
    CONSTRAINT ck_order_dates CHECK (requested_pickup >= requested_delivery)
);

-- ---------------------------------------------------------------------
-- Create Table for Order Line (one smart tin per line)
-- ---------------------------------------------------------------------
CREATE TABLE order_line (
    order_line_id  NUMBER GENERATED ALWAYS AS IDENTITY,
    order_id       NUMBER       NOT NULL,
    category_id    NUMBER       NOT NULL,
    tin_size_id    NUMBER       NOT NULL,
    tin_id         NUMBER,
    unit_price     NUMBER(10,2) NOT NULL,
    CONSTRAINT pk_order_line PRIMARY KEY (order_line_id),
    CONSTRAINT fk_line_order    FOREIGN KEY (order_id)    REFERENCES customer_order (order_id),
    -- Composite FK: only permitted waste category / tin size combinations can be ordered
    CONSTRAINT fk_line_combo    FOREIGN KEY (category_id, tin_size_id)
                                REFERENCES category_tin_size (category_id, tin_size_id),
    -- Composite FK guarantees the assigned tin has the ordered size
    CONSTRAINT fk_line_tin_size FOREIGN KEY (tin_id, tin_size_id) REFERENCES smart_tin (tin_id, tin_size_id),
    CONSTRAINT ck_line_price CHECK (unit_price > 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Job (delivery / pickup with vehicle assignment)
-- ---------------------------------------------------------------------
CREATE TABLE job (
    job_id           NUMBER GENERATED ALWAYS AS IDENTITY,
    order_id         NUMBER        NOT NULL,
    vehicle_id       NUMBER        NOT NULL,
    job_type         VARCHAR2(10)  NOT NULL,
    scheduled_start  TIMESTAMP     NOT NULL,
    actual_start     TIMESTAMP,
    actual_end       TIMESTAMP,
    job_status       VARCHAR2(12)  DEFAULT 'SCHEDULED' NOT NULL,
    outsource_cost   NUMBER(10,2)  DEFAULT 0 NOT NULL,
    notes            VARCHAR2(300),
    CONSTRAINT pk_job PRIMARY KEY (job_id),
    CONSTRAINT fk_job_order   FOREIGN KEY (order_id)   REFERENCES customer_order (order_id),
    CONSTRAINT fk_job_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id),
    CONSTRAINT ck_job_type CHECK (job_type IN ('DELIVERY','PICKUP','SWAP')),
    CONSTRAINT ck_job_status CHECK (job_status IN ('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED')),
    CONSTRAINT ck_job_times CHECK (actual_end IS NULL OR (actual_start IS NOT NULL AND actual_end >= actual_start)),
    CONSTRAINT ck_job_cost CHECK (outsource_cost >= 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Job Staff (resolves M:N job to personnel)
-- ---------------------------------------------------------------------
CREATE TABLE job_staff (
    job_id    NUMBER       NOT NULL,
    staff_id  NUMBER       NOT NULL,
    job_role  VARCHAR2(10) NOT NULL,
    CONSTRAINT pk_job_staff PRIMARY KEY (job_id, staff_id),
    CONSTRAINT fk_job_staff_job   FOREIGN KEY (job_id)   REFERENCES job (job_id),
    CONSTRAINT fk_job_staff_staff FOREIGN KEY (staff_id) REFERENCES staff (staff_id),
    CONSTRAINT ck_job_staff_role CHECK (job_role IN ('DRIVER','OFFSIDER'))
);

-- ---------------------------------------------------------------------
-- Create Table for Disposal Record (dump / recycling docket)
-- ---------------------------------------------------------------------
CREATE TABLE disposal_record (
    disposal_id         NUMBER GENERATED ALWAYS AS IDENTITY,
    order_line_id       NUMBER        NOT NULL,
    job_id              NUMBER        NOT NULL,
    facility_id         NUMBER        NOT NULL,
    docket_number       VARCHAR2(20)  NOT NULL,
    disposed_at         TIMESTAMP     NOT NULL,
    gross_weight_kg     NUMBER(10,2)  NOT NULL,
    recycled_weight_kg  NUMBER(10,2)  DEFAULT 0 NOT NULL,
    gate_fee            NUMBER(10,2)  NOT NULL,
    CONSTRAINT pk_disposal_record PRIMARY KEY (disposal_id),
    CONSTRAINT uq_disposal_docket UNIQUE (docket_number),
    CONSTRAINT uq_disposal_line_job UNIQUE (order_line_id, job_id),
    CONSTRAINT fk_disposal_line     FOREIGN KEY (order_line_id) REFERENCES order_line (order_line_id),
    CONSTRAINT fk_disposal_job      FOREIGN KEY (job_id)        REFERENCES job (job_id),
    CONSTRAINT fk_disposal_facility FOREIGN KEY (facility_id)   REFERENCES council_facility (facility_id),
    CONSTRAINT ck_disposal_weight CHECK (gross_weight_kg > 0),
    CONSTRAINT ck_disposal_recycled CHECK (recycled_weight_kg >= 0 AND recycled_weight_kg <= gross_weight_kg),
    CONSTRAINT ck_disposal_fee CHECK (gate_fee >= 0)
);

-- ---------------------------------------------------------------------
-- Create Table for Invoice (financial management)
-- ---------------------------------------------------------------------
CREATE TABLE invoice (
    invoice_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    invoice_number  VARCHAR2(20)  NOT NULL,
    order_id        NUMBER        NOT NULL,
    issue_date      DATE          NOT NULL,
    due_date        DATE          NOT NULL,
    subtotal        NUMBER(12,2)  NOT NULL,
    gst_amount      NUMBER(12,2)  NOT NULL,
    total_amount    NUMBER(12,2)  NOT NULL,
    invoice_status  VARCHAR2(10)  DEFAULT 'ISSUED' NOT NULL,
    CONSTRAINT pk_invoice PRIMARY KEY (invoice_id),
    CONSTRAINT uq_invoice_number UNIQUE (invoice_number),
    CONSTRAINT fk_invoice_order FOREIGN KEY (order_id) REFERENCES customer_order (order_id),
    CONSTRAINT ck_invoice_status CHECK (invoice_status IN ('DRAFT','ISSUED','PAID','OVERDUE','VOID')),
    CONSTRAINT ck_invoice_dates CHECK (due_date >= issue_date),
    CONSTRAINT ck_invoice_amounts CHECK (subtotal >= 0 AND gst_amount >= 0),
    CONSTRAINT ck_invoice_total CHECK (total_amount = subtotal + gst_amount)
);

-- ---------------------------------------------------------------------
-- Create Table for Payment
-- ---------------------------------------------------------------------
CREATE TABLE payment (
    payment_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    invoice_id      NUMBER        NOT NULL,
    paid_at         TIMESTAMP     NOT NULL,
    amount          NUMBER(12,2)  NOT NULL,
    payment_method  VARCHAR2(15)  NOT NULL,
    reference_no    VARCHAR2(40),
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT fk_payment_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id),
    CONSTRAINT ck_payment_amount CHECK (amount > 0),
    CONSTRAINT ck_payment_method CHECK (payment_method IN ('CARD','BANK_TRANSFER','CASH','BPAY'))
);

-- ---------------------------------------------------------------------
-- Create Table for Supplier Invoice (accounts payable for outsourced work)
-- ---------------------------------------------------------------------
CREATE TABLE supplier_invoice (
    supplier_invoice_id  NUMBER GENERATED ALWAYS AS IDENTITY,
    supplier_id          NUMBER        NOT NULL,
    supplier_ref         VARCHAR2(30)  NOT NULL,
    period_start         DATE          NOT NULL,
    period_end           DATE          NOT NULL,
    subtotal             NUMBER(12,2)  NOT NULL,
    gst_amount           NUMBER(12,2)  NOT NULL,
    total_amount         NUMBER(12,2)  NOT NULL,
    due_date             DATE          NOT NULL,
    paid_date            DATE,
    invoice_status       VARCHAR2(10)  DEFAULT 'RECEIVED' NOT NULL,
    CONSTRAINT pk_supplier_invoice PRIMARY KEY (supplier_invoice_id),
    CONSTRAINT uq_supplier_invoice_ref UNIQUE (supplier_id, supplier_ref),
    CONSTRAINT fk_supinv_supplier FOREIGN KEY (supplier_id) REFERENCES outsource_supplier (supplier_id),
    CONSTRAINT ck_supinv_period CHECK (period_end >= period_start),
    CONSTRAINT ck_supinv_amounts CHECK (subtotal >= 0 AND gst_amount >= 0 AND total_amount = subtotal + gst_amount),
    CONSTRAINT ck_supinv_status CHECK (invoice_status IN ('RECEIVED','APPROVED','PAID','DISPUTED')),
    CONSTRAINT ck_supinv_paid CHECK ((invoice_status = 'PAID' AND paid_date IS NOT NULL) OR (invoice_status <> 'PAID' AND paid_date IS NULL))
);

-- ---------------------------------------------------------------------
-- Create Table for Cloud Performance Metric
-- ---------------------------------------------------------------------
CREATE TABLE cloud_performance_metric (
    metric_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    service_name  VARCHAR2(40)  NOT NULL,
    cloud_region  VARCHAR2(20)  NOT NULL,
    metric_name   VARCHAR2(30)  NOT NULL,
    metric_value  NUMBER(14,3)  NOT NULL,
    metric_unit   VARCHAR2(15)  NOT NULL,
    recorded_at   TIMESTAMP     NOT NULL,
    CONSTRAINT pk_cloud_metric PRIMARY KEY (metric_id),
    CONSTRAINT uq_cloud_metric UNIQUE (service_name, cloud_region, metric_name, recorded_at),
    CONSTRAINT ck_cloud_metric_name CHECK (metric_name IN ('CPU_PCT','MEMORY_PCT','LATENCY_MS','ERROR_RATE_PCT','REQUESTS_PER_MIN'))
);

-- ---------------------------------------------------------------------
-- Create Table for Audit Log (security and privacy governance)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    table_name   VARCHAR2(30)  NOT NULL,
    record_id    NUMBER        NOT NULL,
    action_type  VARCHAR2(6)   NOT NULL,
    changed_by   VARCHAR2(128) NOT NULL,
    changed_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    change_detail VARCHAR2(1000),
    CONSTRAINT pk_audit_log PRIMARY KEY (audit_id),
    CONSTRAINT ck_audit_action CHECK (action_type IN ('INSERT','UPDATE','DELETE'))
);

-- =====================================================================
-- SECTION 2 - INDEXES AND TRIGGERS
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

-- Create Indexes for Foreign Keys (Oracle does not index FKs automatically)
CREATE INDEX ix_council_state        ON council (state_code);
CREATE INDEX ix_address_state        ON address (state_code);
CREATE INDEX ix_address_council      ON address (council_id);
CREATE INDEX ix_facility_council     ON council_facility (council_id);
CREATE INDEX ix_facility_address     ON council_facility (address_id);
CREATE INDEX ix_fac_acc_category     ON facility_accepted_category (category_id);
CREATE INDEX ix_cts_size             ON category_tin_size (tin_size_id);
CREATE INDEX ix_tin_price_state      ON tin_price (state_code);
CREATE INDEX ix_vehicle_depot        ON vehicle (depot_id);
CREATE INDEX ix_vehicle_supplier     ON vehicle (supplier_id);
CREATE INDEX ix_maint_vehicle        ON vehicle_maintenance (vehicle_id, service_date);
CREATE INDEX ix_tin_size             ON smart_tin (tin_size_id);
CREATE INDEX ix_tin_depot            ON smart_tin (depot_id);
CREATE INDEX ix_telemetry_time       ON tin_telemetry (recorded_at);
CREATE INDEX ix_staff_depot          ON staff (depot_id);
CREATE INDEX ix_staff_supplier       ON staff (supplier_id);
CREATE INDEX ix_staff_position       ON staff (position_id);
CREATE INDEX ix_staff_address        ON staff (address_id);
CREATE INDEX ix_shift_vehicle        ON roster_shift (vehicle_id);
CREATE INDEX ix_shift_start          ON roster_shift (shift_start);
CREATE INDEX ix_leave_staff          ON leave_request (staff_id);
CREATE INDEX ix_leave_approver       ON leave_request (approver_id);
CREATE INDEX ix_timesheet_approver    ON timesheet (approver_id);
CREATE INDEX ix_timesheet_work_date   ON timesheet (work_date);
CREATE INDEX ix_payslip_staff         ON payslip (staff_id);
CREATE INDEX ix_customer_billing     ON customer (billing_address_id);
CREATE INDEX ix_order_customer       ON customer_order (customer_id);
CREATE INDEX ix_order_billing        ON customer_order (billing_address_id);
CREATE INDEX ix_order_delivery       ON customer_order (delivery_address_id);
CREATE INDEX ix_order_ordered_at     ON customer_order (ordered_at);
CREATE INDEX ix_line_order           ON order_line (order_id);
CREATE INDEX ix_line_combo           ON order_line (category_id, tin_size_id);
CREATE INDEX ix_line_tin             ON order_line (tin_id, tin_size_id);
CREATE INDEX ix_job_order            ON job (order_id);
CREATE INDEX ix_job_vehicle          ON job (vehicle_id);
CREATE INDEX ix_job_staff_staff      ON job_staff (staff_id);
CREATE INDEX ix_disposal_job         ON disposal_record (job_id);
CREATE INDEX ix_disposal_facility    ON disposal_record (facility_id);
CREATE INDEX ix_invoice_order        ON invoice (order_id);
CREATE INDEX ix_invoice_status_due   ON invoice (invoice_status, due_date);
CREATE INDEX ix_payment_invoice      ON payment (invoice_id);
CREATE INDEX ix_cloud_metric_time    ON cloud_performance_metric (recorded_at);
CREATE INDEX ix_audit_table_rec      ON audit_log (table_name, record_id);

-- Create Trigger to enforce that a facility accepts the disposed category
CREATE OR REPLACE TRIGGER trg_disposal_category_chk
BEFORE INSERT OR UPDATE OF facility_id, order_line_id ON disposal_record
FOR EACH ROW
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_cnt
      FROM order_line ol
      JOIN facility_accepted_category fac ON fac.category_id = ol.category_id
     WHERE ol.order_line_id = :NEW.order_line_id
       AND fac.facility_id  = :NEW.facility_id;
    IF v_cnt = 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Facility ' || :NEW.facility_id || ' does not accept the waste category of order line ' || :NEW.order_line_id);
    END IF;
END;
/

-- Create Trigger to prevent overlapping roster shifts for one staff member
-- (compound trigger avoids ORA-04091 mutating-table errors)
CREATE OR REPLACE TRIGGER trg_roster_no_overlap
FOR INSERT OR UPDATE OF staff_id, shift_start, shift_end, shift_status ON roster_shift
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    g_ids t_ids;

    AFTER EACH ROW IS
    BEGIN
        g_ids(g_ids.COUNT + 1) := :NEW.shift_id;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_cnt NUMBER;
    BEGIN
        FOR i IN 1 .. g_ids.COUNT LOOP
            SELECT COUNT(*)
              INTO v_cnt
              FROM roster_shift a
              JOIN roster_shift b
                ON b.staff_id = a.staff_id
               AND b.shift_id <> a.shift_id
               AND b.shift_status <> 'CANCELLED'
               AND b.shift_start < a.shift_end
               AND b.shift_end   > a.shift_start
             WHERE a.shift_id = g_ids(i)
               AND a.shift_status <> 'CANCELLED';
            IF v_cnt > 0 THEN
                RAISE_APPLICATION_ERROR(-20002, 'Overlapping shift detected for shift ' || g_ids(i));
            END IF;
        END LOOP;
        g_ids.DELETE;
    END AFTER STATEMENT;
END trg_roster_no_overlap;
/

-- Create Trigger to restrict payslips to employees (contractors are paid via supplier invoices)
CREATE OR REPLACE TRIGGER trg_payslip_employee_only
BEFORE INSERT OR UPDATE OF staff_id ON payslip
FOR EACH ROW
DECLARE
    v_type staff.employment_type%TYPE;
BEGIN
    SELECT employment_type INTO v_type FROM staff WHERE staff_id = :NEW.staff_id;
    IF v_type <> 'EMPLOYEE' THEN
        RAISE_APPLICATION_ERROR(-20003, 'Payslips can only be issued to employees, staff ' || :NEW.staff_id || ' is a contractor');
    END IF;
END;
/

-- Create Trigger to stop a smart tin being booked on overlapping orders
CREATE OR REPLACE TRIGGER trg_tin_no_double_booking
FOR INSERT OR UPDATE OF tin_id, order_id ON order_line
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    g_ids t_ids;

    AFTER EACH ROW IS
    BEGIN
        IF :NEW.tin_id IS NOT NULL THEN
            g_ids(g_ids.COUNT + 1) := :NEW.order_line_id;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_cnt NUMBER;
    BEGIN
        FOR i IN 1 .. g_ids.COUNT LOOP
            SELECT COUNT(*)
              INTO v_cnt
              FROM order_line a
              JOIN customer_order oa ON oa.order_id = a.order_id
              JOIN order_line b      ON b.tin_id = a.tin_id AND b.order_line_id <> a.order_line_id
              JOIN customer_order ob ON ob.order_id = b.order_id
             WHERE a.order_line_id = g_ids(i)
               AND oa.order_status <> 'CANCELLED'
               AND ob.order_status <> 'CANCELLED'
               AND ob.requested_delivery <= oa.requested_pickup
               AND ob.requested_pickup   >= oa.requested_delivery;
            IF v_cnt > 0 THEN
                RAISE_APPLICATION_ERROR(-20004, 'Smart tin is already booked on an overlapping order (line ' || g_ids(i) || ')');
            END IF;
        END LOOP;
        g_ids.DELETE;
    END AFTER STATEMENT;
END trg_tin_no_double_booking;
/

-- Create Trigger to audit customer changes (privacy governance)
CREATE OR REPLACE TRIGGER trg_customer_audit
AFTER INSERT OR UPDATE OR DELETE ON customer
FOR EACH ROW
DECLARE
    v_action VARCHAR2(6);
    v_id     NUMBER;
BEGIN
    IF INSERTING THEN v_action := 'INSERT'; v_id := :NEW.customer_id;
    ELSIF UPDATING THEN v_action := 'UPDATE'; v_id := :NEW.customer_id;
    ELSE v_action := 'DELETE'; v_id := :OLD.customer_id;
    END IF;
    INSERT INTO audit_log (table_name, record_id, action_type, changed_by, change_detail)
    VALUES ('CUSTOMER', v_id, v_action, SYS_CONTEXT('USERENV','SESSION_USER'),
            'Customer row action: ' || v_action);
END;
/

-- =====================================================================
-- SECTION 3 - SAMPLE DATA
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON

-- ---------------------------------------------------------------------
-- Insert Reference Data: states, councils, categories, sizes, positions
-- ---------------------------------------------------------------------
INSERT INTO state (state_code, state_name) VALUES ('NSW', 'New South Wales');
INSERT INTO state (state_code, state_name) VALUES ('VIC', 'Victoria');
INSERT INTO state (state_code, state_name) VALUES ('QLD', 'Queensland');

INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('NSW', 'City of Parramatta',       'waste@parramatta.example', '0298065000', 150.00);
INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('NSW', 'Blacktown City Council',   'waste@blacktown.example',  '0298398000', 150.00);
INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('NSW', 'Inner West Council',      'waste@innerwest.example',  '0292660000', 150.00);
INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('VIC', 'City of Melbourne',       'waste@melbourne.example',  '0396585000', 125.00);
INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('VIC', 'City of Casey',           'waste@casey.example',      '0396555000', 125.00);
INSERT INTO council (state_code, council_name, contact_email, contact_phone, waste_levy_per_tonne) VALUES ('QLD', 'Brisbane City Council',   'waste@brisbane.example',   '0734038222', 100.00);

INSERT INTO waste_category (category_code, category_name, weight_class, description) VALUES ('MIXED',    'Mixed Rubbish',     'LIGHT', 'Gardening materials, household items and general light rubbish');
INSERT INTO waste_category (category_code, category_name, weight_class, description) VALUES ('BUILDING', 'Building Materials', 'HEAVY', 'Soil, bricks, tiles and other heavy building materials');
INSERT INTO waste_category (category_code, category_name, weight_class, description) VALUES ('CONCRETE', 'Concrete',          'HEAVY', 'Pure concrete removal only');
INSERT INTO waste_category (category_code, category_name, weight_class, description) VALUES ('DIRT',     'Dirt',              'HEAVY', 'Pure soil removal only');

INSERT INTO tin_size (size_code, volume_m3, max_load_kg, description) VALUES ('S2', 2, 1000, '2 cubic metre skip bin');
INSERT INTO tin_size (size_code, volume_m3, max_load_kg, description) VALUES ('S3', 3, 1500, '3 cubic metre skip bin');
INSERT INTO tin_size (size_code, volume_m3, max_load_kg, description) VALUES ('S4', 4, 2000, '4 cubic metre skip bin');
INSERT INTO tin_size (size_code, volume_m3, max_load_kg, description) VALUES ('S6', 6, 3000, '6 cubic metre skip bin');
INSERT INTO tin_size (size_code, volume_m3, max_load_kg, description) VALUES ('S8', 8, 4000, '8 cubic metre skip bin');

INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Truck Driver',          38.50, 1);
INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Offsider',              32.00, 0);
INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Depot Manager',         55.00, 0);
INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Rostering Coordinator', 42.00, 0);
INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Accountant',            48.00, 0);
INSERT INTO job_position (position_title, base_hourly_rate, requires_licence) VALUES ('Mechanic',              45.00, 0);

-- ---------------------------------------------------------------------
-- Insert Addresses (billing, delivery sites, depots, facilities)
-- ---------------------------------------------------------------------
DECLARE
    PROCEDURE add_addr (p_street VARCHAR2, p_suburb VARCHAR2, p_state VARCHAR2,
                        p_pc VARCHAR2, p_council VARCHAR2) IS
    BEGIN
        INSERT INTO address (street_line1, suburb, state_code, postcode, council_id)
        SELECT p_street, p_suburb, p_state, p_pc, c.council_id
          FROM council c
         WHERE c.council_name = p_council AND c.state_code = p_state;
        IF SQL%ROWCOUNT <> 1 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Council not found: ' || p_council);
        END IF;
    END;
BEGIN
    -- customer billing addresses
    add_addr('12 Station Street',        'Parramatta',    'NSW', '2150', 'City of Parramatta');
    add_addr('45 Main Street',           'Blacktown',     'NSW', '2148', 'Blacktown City Council');
    add_addr('8 Harbour Road',           'Leichhardt',    'NSW', '2040', 'Inner West Council');
    add_addr('101 Southbank Boulevard',  'Southbank',     'VIC', '3006', 'City of Melbourne');
    add_addr('22 Princes Highway',       'Narre Warren',  'VIC', '3805', 'City of Casey');
    add_addr('7 Queen Street',           'Brisbane City', 'QLD', '4000', 'Brisbane City Council');
    add_addr('19 Gardens Point Road',    'Kangaroo Point','QLD', '4169', 'Brisbane City Council');
    add_addr('3 Church Street',          'Parramatta',    'NSW', '2150', 'City of Parramatta');
    -- delivery sites (differ from billing addresses)
    add_addr('56 Smith Street',          'Westmead',      'NSW', '2145', 'City of Parramatta');
    add_addr('14 Oak Avenue',            'Seven Hills',   'NSW', '2147', 'Blacktown City Council');
    add_addr('230 Marion Street',        'Leichhardt',    'NSW', '2040', 'Inner West Council');
    add_addr('77 Collins Street',        'Melbourne',     'VIC', '3000', 'City of Melbourne');
    add_addr('5 Hallam Road',            'Hampton Park',  'VIC', '3976', 'City of Casey');
    add_addr('88 Eagle Street',          'Brisbane City', 'QLD', '4000', 'Brisbane City Council');
    add_addr('31 Wynnum Road',           'Norman Park',   'QLD', '4170', 'Brisbane City Council');
    add_addr('9 George Street',          'Parramatta',    'NSW', '2150', 'City of Parramatta');
    add_addr('64 Flinders Street',       'Melbourne',     'VIC', '3000', 'City of Melbourne');
    add_addr('140 Rawson Street',        'Granville',     'NSW', '2142', 'City of Parramatta');
    -- depots
    add_addr('1 Depot Road',             'Prospect',      'NSW', '2148', 'Blacktown City Council');
    add_addr('200 Dynon Road',           'West Melbourne','VIC', '3003', 'City of Melbourne');
    add_addr('15 Beaudesert Road',       'Acacia Ridge',  'QLD', '4110', 'Brisbane City Council');
    -- council facilities
    add_addr('1 Hassall Street',         'Rydalmere',     'NSW', '2116', 'City of Parramatta');
    add_addr('25 Kurrajong Road',        'Eastern Creek', 'NSW', '2766', 'Blacktown City Council');
    add_addr('10 Bedwin Road',           'St Peters',     'NSW', '2044', 'Inner West Council');
    add_addr('300 Lorimer Street',       'Port Melbourne','VIC', '3207', 'City of Melbourne');
    add_addr('1 Cranbourne Road',        'Cranbourne',    'VIC', '3977', 'City of Casey');
    add_addr('50 Bilsen Road',           'Rochedale',     'QLD', '4123', 'Brisbane City Council');
END;
/

-- ---------------------------------------------------------------------
-- Insert Council Facilities and accepted categories
-- ---------------------------------------------------------------------
INSERT INTO council_facility (council_id, address_id, facility_name, facility_type, gate_fee_per_tonne, operating_hours)
SELECT c.council_id, a.address_id, f.fname, f.ftype, f.fee, '06:00-17:00'
  FROM (SELECT 'Parramatta Resource Recovery' fname, 'DUMP' ftype, 'City of Parramatta' cname, '1 Hassall Street' street, 210.00 fee FROM dual UNION ALL
        SELECT 'Blacktown Recycling Centre',   'RECYCLING', 'Blacktown City Council', '25 Kurrajong Road',  95.00 FROM dual UNION ALL
        SELECT 'Inner West Transfer Station',  'DUMP',      'Inner West Council',     '10 Bedwin Road',    220.00 FROM dual UNION ALL
        SELECT 'Melbourne Recycling Hub',      'RECYCLING', 'City of Melbourne',      '300 Lorimer Street', 85.00 FROM dual UNION ALL
        SELECT 'Casey Landfill',               'DUMP',      'City of Casey',          '1 Cranbourne Road', 190.00 FROM dual UNION ALL
        SELECT 'Brisbane Recycling Centre',    'RECYCLING', 'Brisbane City Council',  '50 Bilsen Road',     80.00 FROM dual) f
  JOIN council c ON c.council_name = f.cname
  JOIN address a ON a.street_line1 = f.street;

INSERT INTO facility_accepted_category (facility_id, category_id)
SELECT f.facility_id, c.category_id
  FROM council_facility f
  JOIN waste_category c
    ON (f.facility_name IN ('Parramatta Resource Recovery','Melbourne Recycling Hub','Brisbane Recycling Centre'))
    OR (f.facility_name = 'Blacktown Recycling Centre'  AND c.category_code IN ('CONCRETE','DIRT','BUILDING'))
    OR (f.facility_name = 'Inner West Transfer Station' AND c.category_code IN ('MIXED','BUILDING'))
    OR (f.facility_name = 'Casey Landfill'              AND c.category_code IN ('MIXED','BUILDING','DIRT'));

-- ---------------------------------------------------------------------
-- Insert Category Tin Size rules (heavy waste only in smaller tins)
-- ---------------------------------------------------------------------
INSERT INTO category_tin_size (category_id, tin_size_id)
SELECT c.category_id, s.tin_size_id
  FROM waste_category c
  JOIN tin_size s
    ON  c.category_code = 'MIXED'
    OR (c.category_code = 'BUILDING' AND s.size_code IN ('S2','S3','S4'))
    OR (c.category_code IN ('CONCRETE','DIRT') AND s.size_code IN ('S2','S3'));

-- ---------------------------------------------------------------------
-- Insert Pricing (NSW base, other states derived with a regional uplift)
-- ---------------------------------------------------------------------
INSERT INTO tin_price (category_id, tin_size_id, state_code, hire_price, effective_from)
SELECT c.category_id, s.tin_size_id, 'NSW', p.price, DATE '2025-01-01'
  FROM (SELECT 'MIXED' cat, 'S2' sz, 290 price FROM dual UNION ALL SELECT 'MIXED','S3',350 FROM dual UNION ALL
        SELECT 'MIXED','S4',420 FROM dual UNION ALL SELECT 'MIXED','S6',560 FROM dual UNION ALL SELECT 'MIXED','S8',690 FROM dual UNION ALL
        SELECT 'BUILDING','S2',390 FROM dual UNION ALL SELECT 'BUILDING','S3',470 FROM dual UNION ALL SELECT 'BUILDING','S4',560 FROM dual UNION ALL
        SELECT 'CONCRETE','S2',320 FROM dual UNION ALL SELECT 'CONCRETE','S3',400 FROM dual UNION ALL
        SELECT 'DIRT','S2',300 FROM dual UNION ALL SELECT 'DIRT','S3',380 FROM dual) p
  JOIN waste_category c ON c.category_code = p.cat
  JOIN tin_size s ON s.size_code = p.sz;

INSERT INTO tin_price (category_id, tin_size_id, state_code, hire_price, effective_from)
SELECT tp.category_id, tp.tin_size_id, st.state_code, ROUND(tp.hire_price * st.uplift, 2), tp.effective_from
  FROM tin_price tp
  JOIN (SELECT 'VIC' state_code, 1.05 uplift FROM dual UNION ALL SELECT 'QLD', 1.03 FROM dual) st ON 1 = 1
 WHERE tp.state_code = 'NSW';

-- ---------------------------------------------------------------------
-- Insert Depots, Suppliers, Vehicles, Maintenance
-- ---------------------------------------------------------------------
INSERT INTO depot (address_id, depot_name, phone)
SELECT a.address_id, d.dname, d.phone
  FROM (SELECT 'Sydney West Depot' dname, '1 Depot Road' street, '0296000001' phone FROM dual UNION ALL
        SELECT 'Melbourne Central Depot', '200 Dynon Road', '0396000002' FROM dual UNION ALL
        SELECT 'Brisbane South Depot', '15 Beaudesert Road', '0736000003' FROM dual) d
  JOIN address a ON a.street_line1 = d.street;

INSERT INTO outsource_supplier (supplier_name, abn, contact_name, contact_email, contact_phone, daily_vehicle_rate, hourly_staff_rate, contract_start, supplier_status)
VALUES ('Metro Haulage Pty Ltd', '51824753556', 'Gary Dunn',  'ops@metrohaulage.example', '0299000010', 780.00, 52.00, DATE '2024-01-01', 'ACTIVE');
INSERT INTO outsource_supplier (supplier_name, abn, contact_name, contact_email, contact_phone, daily_vehicle_rate, hourly_staff_rate, contract_start, supplier_status)
VALUES ('QuickLift Transport', '33102417032', 'Anita Roy',  'ops@quicklift.example',    '0799000020', 720.00, 49.00, DATE '2024-06-01', 'ACTIVE');

INSERT INTO vehicle (registration_no, vehicle_type, make, model, year_built, capacity_tonnes, ownership, depot_id, supplier_id)
SELECT v.rego, v.vtype, v.make, v.model, v.yr, v.cap, v.own,
       (SELECT d.depot_id FROM depot d WHERE d.depot_name = v.depot),
       (SELECT s.supplier_id FROM outsource_supplier s WHERE s.supplier_name = v.supplier)
  FROM (SELECT 'GWM01N' rego, 'SKIP_TRUCK' vtype, 'Isuzu' make, 'FVR 170' model, 2022 yr, 12 cap, 'OWNED' own, 'Sydney West Depot' depot, CAST(NULL AS VARCHAR2(120)) supplier FROM dual UNION ALL
        SELECT 'GWM02N', 'HOOK_LIFT', 'Hino',  '500 FG',    2021, 14, 'OWNED', 'Sydney West Depot',       NULL FROM dual UNION ALL
        SELECT 'GWM03V', 'SKIP_TRUCK','Isuzu', 'FVR 170',   2023, 12, 'OWNED', 'Melbourne Central Depot', NULL FROM dual UNION ALL
        SELECT 'GWM04V', 'HOOK_LIFT', 'Hino',  '500 FG',    2020, 14, 'OWNED', 'Melbourne Central Depot', NULL FROM dual UNION ALL
        SELECT 'GWM05Q', 'SKIP_TRUCK','Fuso',  'Canter 918',2022, 10, 'OWNED', 'Brisbane South Depot',    NULL FROM dual UNION ALL
        SELECT 'GWM06Q', 'HOOK_LIFT', 'Isuzu', 'FYH 2100',  2021, 14, 'OWNED', 'Brisbane South Depot',    NULL FROM dual UNION ALL
        SELECT 'MHT101', 'HOOK_LIFT', 'Mack',  'Granite',   2019, 15, 'OUTSOURCED', NULL, 'Metro Haulage Pty Ltd' FROM dual UNION ALL
        SELECT 'QLT202', 'SKIP_TRUCK','Volvo', 'FE 280',    2020, 12, 'OUTSOURCED', NULL, 'QuickLift Transport'   FROM dual) v;

INSERT INTO vehicle_maintenance (vehicle_id, service_date, maintenance_type, odometer_km, cost, notes)
SELECT v.vehicle_id,
       TRUNC(SYSDATE) - n.n * 90 - MOD(v.vehicle_id * 7, 30),
       CASE n.n WHEN 1 THEN 'SERVICE' ELSE 'INSPECTION' END,
       40000 + v.vehicle_id * 3500 - n.n * 8000,
       450 + v.vehicle_id * 35 + n.n * 120,
       'Scheduled maintenance'
  FROM vehicle v
  CROSS JOIN (SELECT 1 n FROM dual UNION ALL SELECT 2 FROM dual) n
 WHERE v.ownership = 'OWNED';

UPDATE vehicle
   SET next_service_due = TRUNC(SYSDATE) + MOD(vehicle_id * 17, 60) - 10
 WHERE ownership = 'OWNED';

-- ---------------------------------------------------------------------
-- Insert Smart Tins (four units per size, spread across depots)
-- ---------------------------------------------------------------------
DECLARE
    v_n NUMBER := 0;
BEGIN
    FOR s IN (SELECT tin_size_id, size_code FROM tin_size ORDER BY volume_m3) LOOP
        FOR k IN 1 .. 4 LOOP
            v_n := v_n + 1;
            INSERT INTO smart_tin (tin_serial, tin_size_id, depot_id, device_imei, firmware_version, purchase_date)
            SELECT 'GWM-' || s.size_code || '-' || LPAD(k, 3, '0'),
                   s.tin_size_id,
                   d.depot_id,
                   '35' || LPAD(TO_CHAR(v_n), 13, '0'),
                   'v2.3.1',
                   DATE '2024-03-01' + v_n * 3
              FROM (SELECT depot_id, ROW_NUMBER() OVER (ORDER BY depot_id) rn FROM depot) d
             WHERE d.rn = MOD(v_n, 3) + 1;
        END LOOP;
    END LOOP;
END;
/

-- ---------------------------------------------------------------------
-- Insert Staff (employees and outsourced contractors)
-- ---------------------------------------------------------------------
DECLARE
    v_lic NUMBER := 0;
    PROCEDURE add_staff (p_type VARCHAR2, p_org VARCHAR2, p_pos VARCHAR2,
                         p_fn VARCHAR2, p_ln VARCHAR2, p_dob DATE, p_hire DATE) IS
        v_req NUMBER;
        v_licno VARCHAR2(20);
        v_class VARCHAR2(5);
        v_exp DATE;
    BEGIN
        SELECT requires_licence INTO v_req FROM job_position WHERE position_title = p_pos;
        IF v_req = 1 THEN
            v_lic := v_lic + 1;
            v_licno := 'LIC' || LPAD(v_lic, 7, '0');
            v_class := 'HR';
            v_exp := TRUNC(SYSDATE) + 400 + v_lic * 20;
        END IF;
        INSERT INTO staff (employment_type, depot_id, supplier_id, position_id, first_name, last_name,
                           date_of_birth, email, phone, licence_no, licence_class, licence_expiry,
                           hire_date, hourly_rate)
        VALUES (p_type,
                CASE WHEN p_type = 'EMPLOYEE'   THEN (SELECT depot_id    FROM depot WHERE depot_name = p_org) END,
                CASE WHEN p_type = 'CONTRACTOR' THEN (SELECT supplier_id FROM outsource_supplier WHERE supplier_name = p_org) END,
                (SELECT position_id FROM job_position WHERE position_title = p_pos),
                p_fn, p_ln, p_dob,
                LOWER(p_fn || '.' || p_ln) || CASE p_type WHEN 'EMPLOYEE' THEN '@gwm.example' ELSE '@contractor.example' END,
                '04' || LPAD(TO_CHAR(10000000 + v_lic * 137 + LENGTH(p_fn) * 7919 + LENGTH(p_ln) * 104729), 8, '0'),
                v_licno, v_class, v_exp, p_hire,
                CASE p_type
                    WHEN 'EMPLOYEE'   THEN (SELECT base_hourly_rate FROM job_position WHERE position_title = p_pos)
                    ELSE (SELECT hourly_staff_rate FROM outsource_supplier WHERE supplier_name = p_org)
                END);
    END;
BEGIN
    add_staff('EMPLOYEE','Sydney West Depot',       'Truck Driver','Daniel','Moore',   DATE '1985-03-12', DATE '2019-02-01');
    add_staff('EMPLOYEE','Sydney West Depot',       'Truck Driver','Priya','Sharma',   DATE '1990-07-25', DATE '2020-05-11');
    add_staff('EMPLOYEE','Melbourne Central Depot', 'Truck Driver','Tom','Walker',     DATE '1988-11-02', DATE '2021-01-18');
    add_staff('EMPLOYEE','Melbourne Central Depot', 'Truck Driver','Chloe','Evans',    DATE '1992-04-30', DATE '2022-03-07');
    add_staff('EMPLOYEE','Brisbane South Depot',    'Truck Driver','Jack','Hughes',    DATE '1983-09-14', DATE '2021-08-23');
    add_staff('EMPLOYEE','Brisbane South Depot',    'Truck Driver','Mia','Collins',    DATE '1995-01-19', DATE '2023-02-13');
    add_staff('EMPLOYEE','Sydney West Depot',       'Offsider','Ben','Carter',         DATE '1997-06-08', DATE '2022-09-05');
    add_staff('EMPLOYEE','Melbourne Central Depot', 'Offsider','Zara','Khan',          DATE '1998-12-21', DATE '2023-04-17');
    add_staff('EMPLOYEE','Brisbane South Depot',    'Offsider','Noah','Reid',          DATE '1996-10-03', DATE '2022-11-28');
    add_staff('EMPLOYEE','Sydney West Depot',       'Depot Manager','Sarah','Mitchell',DATE '1979-02-27', DATE '2016-07-04');
    add_staff('EMPLOYEE','Sydney West Depot',       'Rostering Coordinator','Kevin','Lee', DATE '1987-05-16', DATE '2018-10-15');
    add_staff('EMPLOYEE','Sydney West Depot',       'Accountant','Rachel','Adams',     DATE '1984-08-09', DATE '2017-03-20');
    add_staff('EMPLOYEE','Sydney West Depot',       'Mechanic','Paul','Singh',         DATE '1981-12-01', DATE '2018-01-29');
    add_staff('CONTRACTOR','Metro Haulage Pty Ltd', 'Truck Driver','Aaron','Boyd',     DATE '1986-03-03', DATE '2024-01-15');
    add_staff('CONTRACTOR','Metro Haulage Pty Ltd', 'Offsider','Lena','Fox',           DATE '1999-09-09', DATE '2024-01-15');
    add_staff('CONTRACTOR','QuickLift Transport',   'Truck Driver','Omar','Haddad',    DATE '1989-07-07', DATE '2024-06-10');
END;
/

-- ---------------------------------------------------------------------
-- Insert Leave Requests
-- ---------------------------------------------------------------------
INSERT INTO leave_request (staff_id, approver_id, leave_type, start_date, end_date, leave_status)
SELECT s.staff_id, m.staff_id, l.ltype, TRUNC(SYSDATE) + l.s_off, TRUNC(SYSDATE) + l.e_off, l.lstatus
  FROM (SELECT 'daniel.moore@gwm.example' em, 'ANNUAL' ltype, 30 s_off, 37 e_off, 'APPROVED' lstatus FROM dual UNION ALL
        SELECT 'tom.walker@gwm.example',        'SICK',   -5,  -4, 'APPROVED' FROM dual UNION ALL
        SELECT 'mia.collins@gwm.example',       'CARER',  10,  11, 'PENDING'  FROM dual) l
  JOIN staff s ON s.email = l.em
  JOIN staff m ON m.email = 'sarah.mitchell@gwm.example';

-- ---------------------------------------------------------------------
-- Insert Customers
-- ---------------------------------------------------------------------
INSERT INTO customer (customer_type, first_name, last_name, company_name, abn, email, phone, billing_address_id, credit_limit)
SELECT c.ctype, c.fn, c.ln, c.company, c.abn, c.email, c.phone, a.address_id, c.credit
  FROM (SELECT 'RESIDENTIAL' ctype, 'Olivia' fn, 'Bennett' ln, CAST(NULL AS VARCHAR2(120)) company, CAST(NULL AS VARCHAR2(11)) abn, 'olivia.bennett@mail.example' email, '0411000001' phone, '12 Station Street' street, 1000 credit FROM dual UNION ALL
        SELECT 'RESIDENTIAL','Liam','Nguyen',NULL,NULL,'liam.nguyen@mail.example','0411000002','45 Main Street',1000 FROM dual UNION ALL
        SELECT 'COMMERCIAL',NULL,NULL,'Harbour Constructions Pty Ltd','11000111222','accounts@harbourcon.example','0292000003','8 Harbour Road',25000 FROM dual UNION ALL
        SELECT 'COMMERCIAL',NULL,NULL,'Southbank Builders Pty Ltd','22000222333','accounts@southbank.example','0392000004','101 Southbank Boulevard',30000 FROM dual UNION ALL
        SELECT 'GOVERNMENT',NULL,NULL,'Casey Community Services','33000333444','finance@caseycs.example','0392000005','22 Princes Highway',50000 FROM dual UNION ALL
        SELECT 'RESIDENTIAL','Ava','Thompson',NULL,NULL,'ava.thompson@mail.example','0411000006','7 Queen Street',1500 FROM dual UNION ALL
        SELECT 'COMMERCIAL',NULL,NULL,'Brisbane Landscaping Co','44000444555','accounts@bnelandscape.example','0732000007','19 Gardens Point Road',15000 FROM dual UNION ALL
        SELECT 'COMMERCIAL',NULL,NULL,'Western Demolition Pty Ltd','55000555666','accounts@westdemo.example','0292000008','3 Church Street',40000 FROM dual) c
  JOIN address a ON a.street_line1 = c.street;

COMMIT;

-- ---------------------------------------------------------------------
-- Insert Orders, Lines, Jobs, Staff assignments, Disposals,
-- Invoices, Payments and Tin Telemetry (66 generated orders)
-- ---------------------------------------------------------------------
DECLARE
    TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_cust    t_num;
    v_deliv   t_num;
    v_cat     t_num;
    v_size    t_num;
    v_allowed t_num;
    v_tincnt  t_num;
    v_today   DATE := TRUNC(SYSDATE);

    v_bill NUMBER;
    v_c NUMBER; v_cat_id NUMBER; v_cat_code VARCHAR2(10); v_sz_id NUMBER; v_addr NUMBER;
    v_state VARCHAR2(3); v_price NUMBER; v_d0 DATE; v_pick DATE; v_status VARCHAR2(12);
    v_order NUMBER; v_line NUMBER; v_tin NUMBER; v_veh NUMBER; v_job NUMBER;
    v_max NUMBER; v_gst NUMBER; v_inv NUMBER; v_inv_status VARCHAR2(10); v_total NUMBER;
    v_issue DATE; v_due DATE; v_ts TIMESTAMP; v_fill NUMBER;
    v_facility NUMBER; v_weight NUMBER; v_rate NUMBER; v_fee NUMBER; v_pref VARCHAR2(10);

    FUNCTION pick_vehicle (p_state VARCHAR2, p_i NUMBER) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        IF MOD(p_i, 6) = 0 THEN
            SELECT vehicle_id INTO v_id
              FROM (SELECT vehicle_id, ROW_NUMBER() OVER (ORDER BY vehicle_id) rn, COUNT(*) OVER () c
                      FROM vehicle WHERE ownership = 'OUTSOURCED')
             WHERE rn = MOD(TRUNC(p_i / 6), c) + 1;
        ELSE
            SELECT vehicle_id INTO v_id
              FROM (SELECT v.vehicle_id, ROW_NUMBER() OVER (ORDER BY v.vehicle_id) rn, COUNT(*) OVER () c
                      FROM vehicle v
                      JOIN depot d   ON d.depot_id = v.depot_id
                      JOIN address a ON a.address_id = d.address_id
                     WHERE v.ownership = 'OWNED' AND a.state_code = p_state)
             WHERE rn = MOD(p_i, c) + 1;
        END IF;
        RETURN v_id;
    END;

    FUNCTION add_job (p_order NUMBER, p_type VARCHAR2, p_veh NUMBER, p_start DATE, p_status VARCHAR2) RETURN NUMBER IS
        v_id   NUMBER;
        v_cost NUMBER;
    BEGIN
        -- one outsourced truck-day is shared across ~6 jobs
        SELECT NVL(s.daily_vehicle_rate, 0) / 6 INTO v_cost
          FROM vehicle v
          LEFT JOIN outsource_supplier s ON s.supplier_id = v.supplier_id
         WHERE v.vehicle_id = p_veh;
        INSERT INTO job (order_id, vehicle_id, job_type, scheduled_start, actual_start, actual_end, job_status, outsource_cost)
        VALUES (p_order, p_veh, p_type, p_start,
                CASE WHEN p_status = 'COMPLETED' THEN p_start END,
                CASE WHEN p_status = 'COMPLETED' THEN p_start + 1.5 / 24 END,
                p_status, ROUND(v_cost, 2))
        RETURNING job_id INTO v_id;
        RETURN v_id;
    END;

    PROCEDURE assign_staff (p_job NUMBER, p_veh NUMBER, p_title VARCHAR2, p_role VARCHAR2, p_i NUMBER) IS
    BEGIN
        INSERT INTO job_staff (job_id, staff_id, job_role)
        SELECT p_job, x.staff_id, p_role
          FROM (SELECT s.staff_id,
                       ROW_NUMBER() OVER (ORDER BY s.staff_id) rn,
                       COUNT(*) OVER () cnt
                  FROM staff s
                  JOIN job_position p ON p.position_id = s.position_id
                  JOIN vehicle v ON v.vehicle_id = p_veh
                                AND (v.depot_id = s.depot_id OR v.supplier_id = s.supplier_id)
                 WHERE p.position_title = p_title) x
         WHERE x.rn = MOD(p_i, x.cnt) + 1;
    END;
BEGIN
    SELECT customer_id BULK COLLECT INTO v_cust FROM customer ORDER BY customer_id;
    SELECT address_id  BULK COLLECT INTO v_deliv
      FROM address
     WHERE street_line1 IN ('56 Smith Street','14 Oak Avenue','230 Marion Street','77 Collins Street',
                            '5 Hallam Road','88 Eagle Street','31 Wynnum Road','9 George Street',
                            '64 Flinders Street','140 Rawson Street')
     ORDER BY address_id;
    SELECT category_id BULK COLLECT INTO v_cat  FROM waste_category ORDER BY category_id;
    SELECT tin_size_id BULK COLLECT INTO v_size FROM tin_size ORDER BY volume_m3;
    -- number of tin sizes orderable per category (MIXED, BUILDING, CONCRETE, DIRT)
    v_allowed(1) := 5; v_allowed(2) := 3; v_allowed(3) := 2; v_allowed(4) := 2;
    FOR k IN 1 .. v_size.COUNT LOOP v_tincnt(v_size(k)) := 0; END LOOP;

    FOR i IN 1 .. 66 LOOP
        v_c      := v_cust(MOD(i, v_cust.COUNT) + 1);
        v_cat_id := v_cat(MOD(i, 4) + 1);
        v_sz_id  := v_size(MOD(TRUNC(i / 4), v_allowed(MOD(i, 4) + 1)) + 1);
        v_addr   := v_deliv(MOD(i * 3, v_deliv.COUNT) + 1);
        v_d0     := v_today - 95 + TRUNC(i * 1.5);
        v_pick   := v_d0 + 3 + MOD(i, 3);

        SELECT state_code INTO v_state FROM address WHERE address_id = v_addr;
        SELECT category_code INTO v_cat_code FROM waste_category WHERE category_id = v_cat_id;
        SELECT max_load_kg INTO v_max FROM tin_size WHERE tin_size_id = v_sz_id;
        SELECT hire_price INTO v_price
          FROM (SELECT hire_price
                  FROM tin_price
                 WHERE category_id = v_cat_id AND tin_size_id = v_sz_id AND state_code = v_state
                   AND effective_from <= v_d0
                 ORDER BY effective_from DESC)
         WHERE ROWNUM = 1;

        IF i = 17 THEN v_status := 'CANCELLED';
        ELSIF v_pick < v_today THEN v_status := 'COMPLETED';
        ELSIF v_d0 <= v_today THEN v_status := 'DELIVERED';
        ELSIF v_d0 > v_today + 2 THEN v_status := 'PLACED';
        ELSE v_status := 'SCHEDULED';
        END IF;

        v_ts := (v_d0 - 2) + 10 / 24;
        SELECT billing_address_id INTO v_bill FROM customer WHERE customer_id = v_c;
        INSERT INTO customer_order (order_number, customer_id, billing_address_id, delivery_address_id,
                                    ordered_at, requested_delivery, requested_pickup,
                                    site_contact_name, site_contact_phone, order_status)
        VALUES ('ORD-' || LPAD(i, 6, '0'), v_c, v_bill, v_addr,
                v_ts, v_d0, v_pick, 'Site Contact ' || i, '0400000' || LPAD(i, 3, '0'), v_status)
        RETURNING order_id INTO v_order;

        -- assign a physical smart tin (round-robin within the size) unless cancelled
        v_tin := NULL;
        IF v_status <> 'CANCELLED' THEN
            SELECT tin_id INTO v_tin
              FROM (SELECT tin_id, ROW_NUMBER() OVER (ORDER BY tin_id) rn
                      FROM smart_tin WHERE tin_size_id = v_sz_id)
             WHERE rn = MOD(v_tincnt(v_sz_id), 4) + 1;
            v_tincnt(v_sz_id) := v_tincnt(v_sz_id) + 1;
        END IF;

        INSERT INTO order_line (order_id, category_id, tin_size_id, tin_id, unit_price)
        VALUES (v_order, v_cat_id, v_sz_id, v_tin, v_price)
        RETURNING order_line_id INTO v_line;

        IF v_status IN ('COMPLETED','DELIVERED','SCHEDULED') THEN
            v_veh := pick_vehicle(v_state, i);

            -- delivery job
            v_job := add_job(v_order, 'DELIVERY', v_veh, v_d0 + 7 / 24,
                             CASE WHEN v_status = 'SCHEDULED' THEN 'SCHEDULED' ELSE 'COMPLETED' END);
            assign_staff(v_job, v_veh, 'Truck Driver', 'DRIVER', i);
            assign_staff(v_job, v_veh, 'Offsider',     'OFFSIDER', i);

            -- pickup job (+ disposal docket when completed)
            IF v_status IN ('COMPLETED','DELIVERED') THEN
                v_job := add_job(v_order, 'PICKUP', v_veh, v_pick + 8 / 24,
                                 CASE WHEN v_status = 'COMPLETED' THEN 'COMPLETED' ELSE 'SCHEDULED' END);
                assign_staff(v_job, v_veh, 'Truck Driver', 'DRIVER', i);
                assign_staff(v_job, v_veh, 'Offsider',     'OFFSIDER', i);

                IF v_status = 'COMPLETED' THEN
                    v_pref := CASE WHEN v_cat_code = 'MIXED' THEN 'DUMP' ELSE 'RECYCLING' END;
                    SELECT facility_id, gate_fee_per_tonne INTO v_facility, v_fee
                      FROM (SELECT f.facility_id, f.gate_fee_per_tonne
                              FROM council_facility f
                              JOIN council c ON c.council_id = f.council_id
                              JOIN facility_accepted_category fac ON fac.facility_id = f.facility_id
                             WHERE c.state_code = v_state AND fac.category_id = v_cat_id
                             ORDER BY CASE WHEN f.facility_type = v_pref THEN 0 ELSE 1 END, f.facility_id)
                     WHERE ROWNUM = 1;
                    v_weight := ROUND(v_max * (0.55 + MOD(i, 4) * 0.1), 2);
                    v_rate := CASE v_cat_code WHEN 'MIXED' THEN 0.25 WHEN 'BUILDING' THEN 0.45
                                              WHEN 'CONCRETE' THEN 0.95 ELSE 0.90 END;
                    INSERT INTO disposal_record (order_line_id, job_id, facility_id, docket_number, disposed_at,
                                                 gross_weight_kg, recycled_weight_kg, gate_fee)
                    VALUES (v_line, v_job, v_facility, 'DKT-' || LPAD(i, 6, '0'), (v_pick + 12 / 24),
                            v_weight, ROUND(v_weight * v_rate, 2), ROUND(v_weight / 1000 * v_fee, 2));
                END IF;
            END IF;
        END IF;

        -- IoT telemetry while the tin is on site
        IF v_status IN ('COMPLETED','DELIVERED') THEN
            FOR k IN 1 .. 3 LOOP
                v_ts := (v_d0 + (k - 0.5));
                IF v_ts <= SYSTIMESTAMP THEN
                    v_fill := CASE k WHEN 1 THEN 8 + MOD(i, 10)
                                     WHEN 2 THEN 40 + MOD(i * 3, 20)
                                     ELSE 70 + MOD(i * 7, 25) END;
                    INSERT INTO tin_telemetry (tin_id, recorded_at, fill_level_pct, weight_kg, battery_pct, tamper_flag)
                    VALUES (v_tin, v_ts, v_fill, ROUND(v_fill / 100 * v_max * 0.9, 2),
                            100 - i * 0.5 - k, CASE WHEN MOD(i, 29) = 0 AND k = 2 THEN 1 ELSE 0 END);
                END IF;
            END LOOP;
            -- after pickup the tin is emptied and reports zero fill
            IF v_status = 'COMPLETED' THEN
                INSERT INTO tin_telemetry (tin_id, recorded_at, fill_level_pct, weight_kg, battery_pct, tamper_flag)
                VALUES (v_tin, v_pick + 14 / 24, 0, 0, 100 - i * 0.5 - 4, 0);
            END IF;
        END IF;

        -- invoice and payments
        IF v_status IN ('COMPLETED','DELIVERED') THEN
            v_gst   := ROUND(v_price * 0.10, 2);
            v_total := v_price + v_gst;
            v_issue := LEAST(v_pick, v_today);
            v_due   := v_issue + 14;
            IF v_status = 'COMPLETED' AND MOD(i, 5) <> 0 THEN
                v_inv_status := 'PAID';
            ELSIF v_due < v_today THEN
                v_inv_status := 'OVERDUE';
            ELSE
                v_inv_status := 'ISSUED';
            END IF;
            INSERT INTO invoice (invoice_number, order_id, issue_date, due_date, subtotal, gst_amount, total_amount, invoice_status)
            VALUES ('INV-' || LPAD(i, 6, '0'), v_order, v_issue, v_due, v_price, v_gst, v_total, v_inv_status)
            RETURNING invoice_id INTO v_inv;

            IF v_inv_status = 'PAID' THEN
                INSERT INTO payment (invoice_id, paid_at, amount, payment_method, reference_no)
                VALUES (v_inv, LEAST(v_issue + MOD(i, 10), v_today) + 14 / 24, v_total,
                        CASE MOD(i, 4) WHEN 0 THEN 'CARD' WHEN 1 THEN 'BANK_TRANSFER' WHEN 2 THEN 'BPAY' ELSE 'CASH' END,
                        'PAY-' || LPAD(i, 6, '0'));
            ELSIF MOD(i, 10) = 5 AND v_status = 'COMPLETED' THEN   -- partial payment
                INSERT INTO payment (invoice_id, paid_at, amount, payment_method, reference_no)
                VALUES (v_inv, LEAST(v_issue + 2, v_today) + 14 / 24, ROUND(v_total / 2, 2), 'BANK_TRANSFER', 'PAY-' || LPAD(i, 6, '0'));
            END IF;
        END IF;
    END LOOP;

    -- tin status follows the order lifecycle
    UPDATE smart_tin t SET tin_status = 'DEPLOYED'
     WHERE EXISTS (SELECT 1 FROM order_line ol JOIN customer_order o ON o.order_id = ol.order_id
                    WHERE ol.tin_id = t.tin_id AND o.order_status = 'DELIVERED');
    UPDATE smart_tin t SET last_seen_at = (SELECT MAX(recorded_at) FROM tin_telemetry x WHERE x.tin_id = t.tin_id);
    UPDATE smart_tin SET tin_status = 'MAINTENANCE' WHERE tin_serial = 'GWM-S8-004' AND tin_status = 'AVAILABLE';
    COMMIT;
END;
/

-- ---------------------------------------------------------------------
-- Insert Roster Shifts (42 days history + 7 days forward)
-- ---------------------------------------------------------------------
INSERT INTO roster_shift (staff_id, vehicle_id, shift_start, shift_end, shift_status)
WITH veh AS (
    SELECT vehicle_id, NVL(depot_id, 0) d, NVL(supplier_id, 0) sp,
           ROW_NUMBER() OVER (PARTITION BY NVL(depot_id, 0), NVL(supplier_id, 0) ORDER BY vehicle_id) rn,
           COUNT(*)     OVER (PARTITION BY NVL(depot_id, 0), NVL(supplier_id, 0)) cnt
      FROM vehicle),
stf AS (
    SELECT s.staff_id, NVL(s.depot_id, 0) d, NVL(s.supplier_id, 0) sp,
           ROW_NUMBER() OVER (PARTITION BY NVL(s.depot_id, 0), NVL(s.supplier_id, 0) ORDER BY s.staff_id) srn
      FROM staff s JOIN job_position p ON p.position_id = s.position_id
     WHERE p.position_title = 'Truck Driver'),
days AS (SELECT LEVEL - 43 n FROM dual CONNECT BY LEVEL <= 50)
SELECT stf.staff_id, veh.vehicle_id,
       CAST(TRUNC(SYSDATE) + days.n + 6 / 24 AS TIMESTAMP),
       CAST(TRUNC(SYSDATE) + days.n + 14.5 / 24 AS TIMESTAMP),
       CASE WHEN days.n >= 0 THEN 'SCHEDULED'
            WHEN MOD(ABS(days.n) * stf.staff_id, 23) = 0 THEN 'ABSENT'
            ELSE 'WORKED' END
  FROM stf
  JOIN veh ON veh.d = stf.d AND veh.sp = stf.sp AND veh.rn = MOD(stf.srn - 1, veh.cnt) + 1
  CROSS JOIN days
 WHERE MOD(MOD(days.n + stf.staff_id, 7) + 7, 7) NOT IN (5, 6);

INSERT INTO roster_shift (staff_id, vehicle_id, shift_start, shift_end, shift_status)
WITH days AS (SELECT LEVEL - 43 n FROM dual CONNECT BY LEVEL <= 50)
SELECT s.staff_id, NULL,
       CAST(TRUNC(SYSDATE) + days.n + 6 / 24 AS TIMESTAMP),
       CAST(TRUNC(SYSDATE) + days.n + 14.5 / 24 AS TIMESTAMP),
       CASE WHEN days.n >= 0 THEN 'SCHEDULED' ELSE 'WORKED' END
  FROM staff s JOIN job_position p ON p.position_id = s.position_id
  CROSS JOIN days
 WHERE p.position_title <> 'Truck Driver' AND MOD(MOD(days.n + s.staff_id, 7) + 7, 7) NOT IN (5, 6);

-- ---------------------------------------------------------------------
-- Insert Cloud Performance Metrics (hourly, last 48 hours)
-- ---------------------------------------------------------------------
INSERT INTO cloud_performance_metric (service_name, cloud_region, metric_name, metric_value, metric_unit, recorded_at)
WITH svc AS (SELECT 'ORDER_API' s_name, 1 s_no FROM dual UNION ALL
             SELECT 'TELEMETRY_INGEST', 2 FROM dual UNION ALL
             SELECT 'BI_DASHBOARD', 3 FROM dual),
     reg AS (SELECT 'ap-southeast-2' r_name, 0 r_no FROM dual UNION ALL
             SELECT 'ap-southeast-4', 1 FROM dual),
     met AS (SELECT 'CPU_PCT' m_name FROM dual UNION ALL SELECT 'MEMORY_PCT' FROM dual UNION ALL
             SELECT 'LATENCY_MS' FROM dual UNION ALL SELECT 'ERROR_RATE_PCT' FROM dual UNION ALL
             SELECT 'REQUESTS_PER_MIN' FROM dual),
     hrs AS (SELECT LEVEL - 1 h FROM dual CONNECT BY LEVEL <= 48)
SELECT svc.s_name, reg.r_name, met.m_name,
       CASE met.m_name
            WHEN 'CPU_PCT'          THEN 30 + MOD(hrs.h * 7  + svc.s_no * 11 + reg.r_no * 5, 40)
            WHEN 'MEMORY_PCT'       THEN 45 + MOD(hrs.h * 3  + svc.s_no * 5  + reg.r_no * 7, 35)
            -- only ORDER_API in ap-southeast-4 is given a wider latency range so the SLA dashboard shows a breach
            WHEN 'LATENCY_MS'       THEN 90 + MOD(hrs.h * 13 + svc.s_no * 17 + reg.r_no * 29,
                                                  CASE WHEN svc.s_no = 1 AND reg.r_no = 1 THEN 220 ELSE 150 END)
            WHEN 'ERROR_RATE_PCT'   THEN ROUND(MOD(hrs.h * 5 + svc.s_no * 3 + reg.r_no * 2, 15) / 10, 3)
            ELSE                         300 + MOD(hrs.h * 37 + svc.s_no * 19 + reg.r_no * 41, 900)
       END,
       CASE met.m_name
            WHEN 'LATENCY_MS' THEN 'ms'
            WHEN 'REQUESTS_PER_MIN' THEN 'req/min'
            ELSE 'percent'
       END,
       CAST(TRUNC(SYSDATE, 'HH24') - hrs.h / 24 AS TIMESTAMP)
  FROM svc CROSS JOIN reg CROSS JOIN met CROSS JOIN hrs;

COMMIT;


-- ---------------------------------------------------------------------
-- Insert Timesheets (one per worked shift, a few with overtime)
-- ---------------------------------------------------------------------
INSERT INTO timesheet (staff_id, shift_id, approver_id, work_date, clock_in, clock_out,
                       break_minutes, regular_hours, overtime_hours, timesheet_status)
SELECT w.staff_id,
       w.shift_id,
       CASE WHEN w.shift_start < TRUNC(SYSDATE) - 14
            THEN CASE WHEN w.staff_id = mgr.staff_id THEN alt.staff_id ELSE mgr.staff_id END
       END,
       TRUNC(CAST(w.shift_start AS DATE)),
       w.shift_start,
       w.shift_end + NUMTODSINTERVAL(CASE WHEN MOD(w.shift_id, 9) = 0 THEN 2 ELSE 0 END, 'HOUR'),
       30,
       8,
       CASE WHEN MOD(w.shift_id, 9) = 0 THEN 2 ELSE 0 END,
       CASE WHEN w.shift_start < TRUNC(SYSDATE) - 14 THEN 'APPROVED' ELSE 'SUBMITTED' END
  FROM roster_shift w
  JOIN staff mgr ON mgr.email = 'sarah.mitchell@gwm.example'
  JOIN staff alt ON alt.email = 'kevin.lee@gwm.example'
 WHERE w.shift_status = 'WORKED';

-- ---------------------------------------------------------------------
-- Insert Pay Periods (fortnightly) and Payslips for closed periods
-- ---------------------------------------------------------------------
INSERT INTO pay_period (period_start, period_end, pay_date, period_status)
SELECT TRUNC(SYSDATE) + p.s, TRUNC(SYSDATE) + p.s + 13, TRUNC(SYSDATE) + p.s + 16, p.st
  FROM (SELECT -42 s, 'PAID' st FROM dual UNION ALL
        SELECT -28, 'PAID' FROM dual UNION ALL
        SELECT -14, 'OPEN' FROM dual) p;

INSERT INTO payslip (pay_period_id, staff_id, regular_hours, overtime_hours, hourly_rate,
                     gross_pay, tax_withheld, super_amount, net_pay)
SELECT x.pay_period_id, x.staff_id, x.reg, x.ot, x.hourly_rate,
       x.gross,
       ROUND(x.gross * 0.20, 2),
       ROUND(x.gross * 0.12, 2),
       x.gross - ROUND(x.gross * 0.20, 2)
  FROM (SELECT pp.pay_period_id, s.staff_id, s.hourly_rate,
               SUM(t.regular_hours)  AS reg,
               SUM(t.overtime_hours) AS ot,
               ROUND(SUM(t.regular_hours) * s.hourly_rate + SUM(t.overtime_hours) * s.hourly_rate * 1.5, 2) AS gross
          FROM pay_period pp
          JOIN timesheet t ON t.work_date BETWEEN pp.period_start AND pp.period_end
                          AND t.timesheet_status = 'APPROVED'
          JOIN staff s     ON s.staff_id = t.staff_id AND s.employment_type = 'EMPLOYEE'
         WHERE pp.period_status = 'PAID'
         GROUP BY pp.pay_period_id, s.staff_id, s.hourly_rate) x;

-- ---------------------------------------------------------------------
-- Insert Supplier Invoices (monthly, from completed outsourced jobs)
-- ---------------------------------------------------------------------
INSERT INTO supplier_invoice (supplier_id, supplier_ref, period_start, period_end, subtotal, gst_amount,
                              total_amount, due_date, paid_date, invoice_status)
SELECT m.supplier_id,
       'SUP-' || m.supplier_id || '-' || TO_CHAR(m.month_start, 'YYYYMM'),
       m.month_start,
       LAST_DAY(m.month_start),
       m.subtotal,
       ROUND(m.subtotal * 0.10, 2),
       m.subtotal + ROUND(m.subtotal * 0.10, 2),
       LAST_DAY(m.month_start) + 30,
       CASE WHEN LAST_DAY(m.month_start) < TRUNC(SYSDATE, 'MM') - 30 THEN LAST_DAY(m.month_start) + 25 END,
       CASE WHEN LAST_DAY(m.month_start) < TRUNC(SYSDATE, 'MM') - 30 THEN 'PAID' ELSE 'RECEIVED' END
  FROM (SELECT v.supplier_id, TRUNC(CAST(j.scheduled_start AS DATE), 'MM') AS month_start,
               SUM(j.outsource_cost) AS subtotal
          FROM job j
          JOIN vehicle v ON v.vehicle_id = j.vehicle_id
         WHERE v.supplier_id IS NOT NULL AND j.job_status = 'COMPLETED'
         GROUP BY v.supplier_id, TRUNC(CAST(j.scheduled_start AS DATE), 'MM')
        HAVING SUM(j.outsource_cost) > 0) m;

COMMIT;

-- =====================================================================
-- SECTION 4 - DASHBOARD AND MASKED VIEWS
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

-- ---------------------------------------------------------------------
-- Create View for Monthly Revenue by State with Month-on-Month growth
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_monthly_revenue AS
WITH monthly AS (
    SELECT TRUNC(o.requested_delivery, 'MM') AS month_start,
           da.state_code,
           COUNT(DISTINCT o.order_id)        AS orders,
           SUM(ol.unit_price)                AS revenue_ex_gst
      FROM customer_order o
      JOIN order_line ol ON ol.order_id = o.order_id
      JOIN address da    ON da.address_id = o.delivery_address_id
     WHERE o.order_status IN ('DELIVERED','COMPLETED')
     GROUP BY TRUNC(o.requested_delivery, 'MM'), da.state_code
)
SELECT month_start,
       state_code,
       orders,
       revenue_ex_gst,
       LAG(revenue_ex_gst) OVER (PARTITION BY state_code ORDER BY month_start) AS prev_month_revenue,
       ROUND(100 * (revenue_ex_gst - LAG(revenue_ex_gst) OVER (PARTITION BY state_code ORDER BY month_start))
             / NULLIF(LAG(revenue_ex_gst) OVER (PARTITION BY state_code ORDER BY month_start), 0), 1) AS mom_growth_pct,
       SUM(revenue_ex_gst) OVER (PARTITION BY state_code ORDER BY month_start) AS running_total
  FROM monthly;

-- ---------------------------------------------------------------------
-- Create View for Waste Category Mix and revenue share
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_category_mix AS
SELECT wc.category_name,
       wc.weight_class,
       COUNT(*)                                   AS tins_hired,
       SUM(ol.unit_price)                         AS revenue_ex_gst,
       ROUND(AVG(ol.unit_price), 2)               AS avg_price,
       ROUND(100 * RATIO_TO_REPORT(SUM(ol.unit_price)) OVER (), 1) AS revenue_share_pct
  FROM order_line ol
  JOIN customer_order o ON o.order_id = ol.order_id
  JOIN waste_category wc ON wc.category_id = ol.category_id
 WHERE o.order_status IN ('DELIVERED','COMPLETED')
 GROUP BY wc.category_name, wc.weight_class;

-- ---------------------------------------------------------------------
-- Create View for Receivables Ageing per Customer
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_receivables_ageing AS
WITH inv AS (
    SELECT i.invoice_id, o.customer_id, i.due_date,
           i.total_amount - NVL(p.paid, 0) AS balance
      FROM invoice i
      JOIN customer_order o ON o.order_id = i.order_id
      LEFT JOIN (SELECT invoice_id, SUM(amount) paid FROM payment GROUP BY invoice_id) p
             ON p.invoice_id = i.invoice_id
     WHERE i.invoice_status NOT IN ('VOID','DRAFT')
)
SELECT c.customer_id,
       COALESCE(c.company_name, c.first_name || ' ' || c.last_name) AS customer_name,
       c.customer_type,
       SUM(CASE WHEN TRUNC(SYSDATE) - inv.due_date <= 0                THEN inv.balance ELSE 0 END) AS not_yet_due,
       SUM(CASE WHEN TRUNC(SYSDATE) - inv.due_date BETWEEN 1 AND 30    THEN inv.balance ELSE 0 END) AS days_1_30,
       SUM(CASE WHEN TRUNC(SYSDATE) - inv.due_date BETWEEN 31 AND 60   THEN inv.balance ELSE 0 END) AS days_31_60,
       SUM(CASE WHEN TRUNC(SYSDATE) - inv.due_date > 60                THEN inv.balance ELSE 0 END) AS days_over_60,
       SUM(inv.balance)                                               AS total_outstanding,
       c.credit_limit,
       CASE WHEN SUM(inv.balance) > c.credit_limit THEN 'OVER LIMIT' ELSE 'OK' END AS credit_status
  FROM inv
  JOIN customer c ON c.customer_id = inv.customer_id
 WHERE inv.balance > 0
 GROUP BY c.customer_id, COALESCE(c.company_name, c.first_name || ' ' || c.last_name), c.customer_type, c.credit_limit;

-- ---------------------------------------------------------------------
-- Create View for Customer Ranking (Pareto analysis)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_customer_ranking AS
WITH spend AS (
    SELECT c.customer_id,
           COALESCE(c.company_name, c.first_name || ' ' || c.last_name) AS customer_name,
           c.customer_type,
           COUNT(DISTINCT o.order_id) AS orders,
           SUM(i.total_amount)        AS total_billed
      FROM customer c
      JOIN customer_order o ON o.customer_id = c.customer_id
      JOIN invoice i        ON i.order_id = o.order_id AND i.invoice_status <> 'VOID'
     GROUP BY c.customer_id, COALESCE(c.company_name, c.first_name || ' ' || c.last_name), c.customer_type
)
SELECT RANK() OVER (ORDER BY total_billed DESC) AS spend_rank,
       customer_name,
       customer_type,
       orders,
       total_billed,
       ROUND(100 * total_billed / SUM(total_billed) OVER (), 1) AS share_pct,
       ROUND(100 * SUM(total_billed) OVER (ORDER BY total_billed DESC
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                 / SUM(total_billed) OVER (), 1) AS cumulative_share_pct
  FROM spend;

-- ---------------------------------------------------------------------
-- Create View for Fleet Performance (owned vs outsourced)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_fleet_performance AS
SELECT v.registration_no,
       v.vehicle_type,
       v.ownership,
       COALESCE(d.depot_name, s.supplier_name)  AS operated_by,
       NVL(j.jobs_completed, 0)                 AS jobs_completed,
       NVL(j.outsource_cost, 0)                 AS outsource_cost,
       NVL(m.maintenance_cost, 0)               AS maintenance_cost,
       v.next_service_due,
       CASE WHEN v.next_service_due IS NULL            THEN 'N/A (supplier managed)'
            WHEN v.next_service_due < TRUNC(SYSDATE)   THEN 'OVERDUE'
            WHEN v.next_service_due < TRUNC(SYSDATE)+14 THEN 'DUE SOON'
            ELSE 'OK' END                       AS service_status
  FROM vehicle v
  LEFT JOIN depot d               ON d.depot_id = v.depot_id
  LEFT JOIN outsource_supplier s  ON s.supplier_id = v.supplier_id
  LEFT JOIN (SELECT vehicle_id, COUNT(*) jobs_completed, SUM(outsource_cost) outsource_cost
               FROM job WHERE job_status = 'COMPLETED' GROUP BY vehicle_id) j ON j.vehicle_id = v.vehicle_id
  LEFT JOIN (SELECT vehicle_id, SUM(cost) maintenance_cost
               FROM vehicle_maintenance GROUP BY vehicle_id) m ON m.vehicle_id = v.vehicle_id;

-- ---------------------------------------------------------------------
-- Create View for Staff Utilisation (last 14 days of rostered work)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_staff_utilisation AS
SELECT s.staff_id,
       s.first_name || ' ' || s.last_name AS staff_name,
       s.employment_type,
       p.position_title,
       COUNT(CASE WHEN r.shift_status = 'WORKED' THEN 1 END) AS shifts_worked,
       COUNT(CASE WHEN r.shift_status = 'ABSENT' THEN 1 END) AS shifts_absent,
       NVL(SUM(CASE WHEN r.shift_status = 'WORKED'
                    THEN (CAST(r.shift_end AS DATE) - CAST(r.shift_start AS DATE)) * 24 END), 0) AS hours_worked,
       ROUND(NVL(SUM(CASE WHEN r.shift_status = 'WORKED'
                    THEN (CAST(r.shift_end AS DATE) - CAST(r.shift_start AS DATE)) * 24 END), 0) * s.hourly_rate, 2) AS labour_cost
  FROM staff s
  JOIN job_position p ON p.position_id = s.position_id
  LEFT JOIN roster_shift r ON r.staff_id = s.staff_id
                          AND r.shift_start >= TRUNC(SYSDATE) - 14
                          AND r.shift_start <  TRUNC(SYSDATE)
 WHERE s.staff_status <> 'TERMINATED'
 GROUP BY s.staff_id, s.first_name, s.last_name, s.employment_type, p.position_title, s.hourly_rate;

-- ---------------------------------------------------------------------
-- Create View for Recycling Diversion by Council Facility
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_recycling_diversion AS
SELECT st.state_code,
       c.council_name,
       f.facility_name,
       f.facility_type,
       COUNT(*)                                          AS dockets,
       ROUND(SUM(dr.gross_weight_kg) / 1000, 2)          AS tonnes_received,
       ROUND(SUM(dr.recycled_weight_kg) / 1000, 2)       AS tonnes_recycled,
       ROUND(100 * SUM(dr.recycled_weight_kg) / SUM(dr.gross_weight_kg), 1) AS diversion_rate_pct,
       SUM(dr.gate_fee)                                  AS gate_fees_paid
  FROM disposal_record dr
  JOIN council_facility f ON f.facility_id = dr.facility_id
  JOIN council c          ON c.council_id = f.council_id
  JOIN state st           ON st.state_code = c.state_code
 GROUP BY st.state_code, c.council_name, f.facility_name, f.facility_type;

-- ---------------------------------------------------------------------
-- Create View for Smart Tin Status (latest IoT reading per tin)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_smart_tin_status AS
WITH latest AS (
    SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.tin_id ORDER BY t.recorded_at DESC) rn
      FROM tin_telemetry t
)
SELECT st.tin_serial,
       sz.size_code,
       st.tin_status,
       l.recorded_at         AS last_reading_at,
       l.fill_level_pct,
       l.weight_kg,
       l.battery_pct,
       CASE WHEN l.tamper_flag = 1         THEN 'TAMPER ALERT'
            WHEN l.battery_pct < 40        THEN 'LOW BATTERY'
            WHEN l.fill_level_pct >= 75 AND st.tin_status = 'DEPLOYED' THEN 'PICKUP DUE'
            WHEN st.tin_status = 'MAINTENANCE' THEN 'IN MAINTENANCE'
            ELSE 'NORMAL' END AS alert
  FROM smart_tin st
  JOIN tin_size sz ON sz.tin_size_id = st.tin_size_id
  LEFT JOIN latest l ON l.tin_id = st.tin_id AND l.rn = 1;

-- ---------------------------------------------------------------------
-- Create View for Order Pipeline by Status and State
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_order_pipeline AS
SELECT o.order_status,
       da.state_code,
       COUNT(DISTINCT o.order_id) AS orders,
       SUM(ol.unit_price)         AS order_value_ex_gst,
       MIN(o.requested_delivery)  AS earliest_delivery,
       MAX(o.requested_pickup)    AS latest_pickup
  FROM customer_order o
  JOIN order_line ol ON ol.order_id = o.order_id
  JOIN address da    ON da.address_id = o.delivery_address_id
 GROUP BY o.order_status, da.state_code;

-- ---------------------------------------------------------------------
-- Create View for Cloud Performance SLA by Service and Region
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_cloud_sla AS
SELECT service_name,
       cloud_region,
       ROUND(AVG(CASE WHEN metric_name = 'CPU_PCT'    THEN metric_value END), 1) AS avg_cpu_pct,
       ROUND(MAX(CASE WHEN metric_name = 'CPU_PCT'    THEN metric_value END), 1) AS peak_cpu_pct,
       ROUND(AVG(CASE WHEN metric_name = 'MEMORY_PCT' THEN metric_value END), 1) AS avg_mem_pct,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CASE WHEN metric_name = 'LATENCY_MS' THEN metric_value END), 1) AS p95_latency_ms,
       COUNT(CASE WHEN metric_name = 'LATENCY_MS' AND metric_value > 250 THEN 1 END) AS hours_latency_breach,
       ROUND(AVG(CASE WHEN metric_name = 'ERROR_RATE_PCT' THEN metric_value END), 3) AS avg_error_rate_pct,
       ROUND(SUM(CASE WHEN metric_name = 'REQUESTS_PER_MIN' THEN metric_value END) * 60) AS total_requests,
       CASE WHEN PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CASE WHEN metric_name = 'LATENCY_MS' THEN metric_value END) > 250
            THEN 'SLA BREACH' ELSE 'WITHIN SLA' END AS sla_status
  FROM cloud_performance_metric
 GROUP BY service_name, cloud_region;

-- ---------------------------------------------------------------------
-- Create View for Executive KPIs (single-row summary)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_executive_kpis AS
SELECT (SELECT NVL(SUM(subtotal), 0) FROM invoice WHERE invoice_status <> 'VOID')                    AS revenue_ex_gst,
       (SELECT NVL(SUM(amount), 0)   FROM payment)                                                   AS cash_collected,
       (SELECT NVL(SUM(total_amount), 0) FROM invoice WHERE invoice_status <> 'VOID')
         - (SELECT NVL(SUM(amount), 0) FROM payment)                                                 AS outstanding_receivables,
       (SELECT COUNT(*) FROM customer_order WHERE order_status IN ('PLACED','SCHEDULED','DELIVERED')) AS open_orders,
       (SELECT COUNT(*) FROM smart_tin WHERE tin_status = 'DEPLOYED')                                AS tins_on_site,
       (SELECT ROUND(100 * SUM(recycled_weight_kg) / SUM(gross_weight_kg), 1) FROM disposal_record)  AS diversion_rate_pct,
       (SELECT NVL(SUM(outsource_cost), 0) FROM job WHERE job_status = 'COMPLETED')                  AS outsource_spend,
       (SELECT COUNT(*) FROM timesheet WHERE timesheet_status = 'SUBMITTED')                         AS timesheets_pending,
       (SELECT NVL(SUM(gross_pay + super_amount), 0) FROM payslip)                                   AS payroll_cost
  FROM dual;

-- ---------------------------------------------------------------------
-- Create View for Payroll Summary per Pay Period
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_payroll_summary AS
SELECT pp.pay_period_id,
       pp.period_start,
       pp.period_end,
       pp.pay_date,
       pp.period_status,
       COUNT(ps.payslip_id)                           AS employees_paid,
       NVL(SUM(ps.regular_hours), 0)                  AS regular_hours,
       NVL(SUM(ps.overtime_hours), 0)                 AS overtime_hours,
       ROUND(100 * NVL(SUM(ps.overtime_hours), 0)
             / NULLIF(NVL(SUM(ps.regular_hours), 0) + NVL(SUM(ps.overtime_hours), 0), 0), 1) AS overtime_pct,
       NVL(SUM(ps.gross_pay), 0)                      AS gross_pay,
       NVL(SUM(ps.tax_withheld), 0)                   AS tax_withheld,
       NVL(SUM(ps.super_amount), 0)                   AS super_amount,
       NVL(SUM(ps.net_pay), 0)                        AS net_pay,
       NVL(SUM(ps.gross_pay + ps.super_amount), 0)    AS employer_cost,
       (SELECT COUNT(*) FROM timesheet t
         WHERE t.work_date BETWEEN pp.period_start AND pp.period_end
           AND t.timesheet_status = 'SUBMITTED')      AS timesheets_awaiting_approval
  FROM pay_period pp
  LEFT JOIN payslip ps ON ps.pay_period_id = pp.pay_period_id
 GROUP BY pp.pay_period_id, pp.period_start, pp.period_end, pp.pay_date, pp.period_status;

-- ---------------------------------------------------------------------
-- Create View for Supplier Payables (outsourced vehicles and staff)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dash_supplier_payables AS
SELECT s.supplier_name,
       COUNT(si.supplier_invoice_id)                                                    AS invoices,
       NVL(SUM(si.total_amount), 0)                                                     AS total_invoiced,
       NVL(SUM(CASE WHEN si.invoice_status = 'PAID' THEN si.total_amount END), 0)       AS total_paid,
       NVL(SUM(CASE WHEN si.invoice_status <> 'PAID' THEN si.total_amount END), 0)      AS outstanding,
       NVL(SUM(CASE WHEN si.invoice_status <> 'PAID' AND si.due_date < TRUNC(SYSDATE)
                    THEN si.total_amount END), 0)                                       AS overdue
  FROM outsource_supplier s
  LEFT JOIN supplier_invoice si ON si.supplier_id = s.supplier_id
 GROUP BY s.supplier_name;

-- ---------------------------------------------------------------------
-- Create Masked Views (privacy: BI users never see raw PII)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_masked AS
SELECT customer_id,
       customer_type,
       COALESCE(company_name, SUBSTR(first_name, 1, 1) || '. ' || last_name) AS display_name,
       SUBSTR(email, 1, 1) || '***' || SUBSTR(email, INSTR(email, '@'))    AS email_masked,
       '******' || SUBSTR(phone, -4)                                        AS phone_masked,
       customer_status
  FROM customer;

CREATE OR REPLACE VIEW v_staff_masked AS
SELECT s.staff_id,
       s.first_name,
       s.last_name,
       s.employment_type,
       p.position_title,
       s.depot_id,
       s.supplier_id,
       s.staff_status
  FROM staff s
  JOIN job_position p ON p.position_id = s.position_id;

-- =====================================================================
-- SECTION 5 - SECURITY
-- =====================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

-- Create Roles (one per business function, least privilege)
DECLARE
    PROCEDURE ensure_role (p_role VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE ROLE ' || p_role;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -1921 THEN RAISE; END IF;
    END;
BEGIN
    ensure_role('GWM_BI_READER');
    ensure_role('GWM_FINANCE');
    ensure_role('GWM_OPERATIONS');
    ensure_role('GWM_HR');
END;
/

-- Grant BI Reader: dashboard and masked views only
GRANT SELECT ON gwm_owner.v_dash_monthly_revenue       TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_category_mix          TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_receivables_ageing    TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_customer_ranking      TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_fleet_performance     TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_staff_utilisation     TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_recycling_diversion   TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_smart_tin_status      TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_order_pipeline        TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_cloud_sla             TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_executive_kpis        TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_payroll_summary       TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_dash_supplier_payables     TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_customer_masked            TO gwm_bi_reader;
GRANT SELECT ON gwm_owner.v_staff_masked               TO gwm_bi_reader;

-- Grant Finance: customers, invoices, payments, supplier payables, payroll read access
GRANT SELECT, INSERT, UPDATE ON gwm_owner.invoice           TO gwm_finance;
GRANT SELECT, INSERT         ON gwm_owner.payment           TO gwm_finance;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.supplier_invoice  TO gwm_finance;
GRANT SELECT ON gwm_owner.customer           TO gwm_finance;
GRANT SELECT ON gwm_owner.customer_order     TO gwm_finance;
GRANT SELECT ON gwm_owner.order_line         TO gwm_finance;
GRANT SELECT ON gwm_owner.outsource_supplier TO gwm_finance;
GRANT SELECT ON gwm_owner.pay_period         TO gwm_finance;
GRANT SELECT ON gwm_owner.payslip            TO gwm_finance;
GRANT SELECT ON gwm_owner.v_dash_receivables_ageing TO gwm_finance;
GRANT SELECT ON gwm_owner.v_dash_payroll_summary    TO gwm_finance;
GRANT SELECT ON gwm_owner.v_dash_supplier_payables  TO gwm_finance;

-- Grant Operations: orders, jobs, tins, vehicles, disposal
GRANT SELECT, INSERT, UPDATE ON gwm_owner.customer_order      TO gwm_operations;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.order_line          TO gwm_operations;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.job                 TO gwm_operations;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.job_staff           TO gwm_operations;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.disposal_record     TO gwm_operations;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.smart_tin           TO gwm_operations;
GRANT SELECT, INSERT         ON gwm_owner.tin_telemetry       TO gwm_operations;
GRANT SELECT, UPDATE         ON gwm_owner.vehicle             TO gwm_operations;
GRANT SELECT, INSERT         ON gwm_owner.vehicle_maintenance TO gwm_operations;
GRANT SELECT ON gwm_owner.v_customer_masked  TO gwm_operations;
GRANT SELECT ON gwm_owner.v_staff_masked     TO gwm_operations;
GRANT SELECT ON gwm_owner.address            TO gwm_operations;
GRANT SELECT ON gwm_owner.council_facility   TO gwm_operations;
GRANT SELECT ON gwm_owner.tin_price          TO gwm_operations;

-- Grant HR: staff, rostering, timesheets, payroll (the only role with raw staff and pay data)
GRANT SELECT, INSERT, UPDATE ON gwm_owner.staff          TO gwm_hr;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.roster_shift   TO gwm_hr;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.leave_request  TO gwm_hr;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.timesheet      TO gwm_hr;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.pay_period     TO gwm_hr;
GRANT SELECT, INSERT, UPDATE ON gwm_owner.payslip        TO gwm_hr;
GRANT SELECT ON gwm_owner.job_position       TO gwm_hr;
GRANT SELECT ON gwm_owner.outsource_supplier TO gwm_hr;

-- Create Unified Audit Policies (dropped first so the script can be rerun)
BEGIN
    FOR p IN (SELECT DISTINCT policy_name FROM audit_unified_policies
               WHERE policy_name IN ('GWM_PII_ACCESS_POL','GWM_PRIVILEGE_CHANGE_POL')) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'NOAUDIT POLICY ' || p.policy_name;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        EXECUTE IMMEDIATE 'DROP AUDIT POLICY ' || p.policy_name;
    END LOOP;
END;
/

CREATE AUDIT POLICY gwm_pii_access_pol
    ACTIONS SELECT ON gwm_owner.customer,
            SELECT ON gwm_owner.staff,
            SELECT ON gwm_owner.payslip,
            UPDATE ON gwm_owner.customer,
            UPDATE ON gwm_owner.staff,
            UPDATE ON gwm_owner.payslip,
            DELETE ON gwm_owner.customer,
            DELETE ON gwm_owner.staff,
            DELETE ON gwm_owner.payslip;
AUDIT POLICY gwm_pii_access_pol;

CREATE AUDIT POLICY gwm_privilege_change_pol
    ACTIONS GRANT, REVOKE, CREATE USER, ALTER USER, DROP USER, CREATE ROLE, DROP ROLE;
AUDIT POLICY gwm_privilege_change_pol;

-- Create Password Profile for application users
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_profiles WHERE profile = 'GWM_APP_PROFILE';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE PROFILE gwm_app_profile LIMIT
            FAILED_LOGIN_ATTEMPTS 5
            PASSWORD_LOCK_TIME    1/24
            PASSWORD_LIFE_TIME    90
            PASSWORD_REUSE_MAX    10
            PASSWORD_GRACE_TIME   7
            IDLE_TIME             30
            SESSIONS_PER_USER     10';
    END IF;
END;
/

-- Application accounts are created per environment with secrets from a vault, for example:
--   CREATE USER bi_service IDENTIFIED BY "<vault-secret>" PROFILE gwm_app_profile;
--   GRANT CREATE SESSION, gwm_bi_reader TO bi_service;

-- =====================================================================
-- SECTION 6 - DASHBOARD OUTPUT QUERIES
-- =====================================================================
SET LINESIZE 160
SET PAGESIZE 100
SET TRIMSPOOL ON
SET FEEDBACK ON
SET TIMING ON
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';
COLUMN kpi FORMAT A34
COLUMN value FORMAT 999,999,990.00
COLUMN customer_name FORMAT A30
COLUMN staff_name FORMAT A18
COLUMN position_title FORMAT A22
COLUMN operated_by FORMAT A24
COLUMN facility_name FORMAT A30
COLUMN service_name FORMAT A18
COLUMN email_masked FORMAT A30
COLUMN display_name FORMAT A34
COLUMN supplier_name FORMAT A24

PROMPT === 1. Executive KPIs ===
SELECT kpi, value
  FROM v_dash_executive_kpis
UNPIVOT (value FOR kpi IN (revenue_ex_gst AS '1 Revenue ex GST', cash_collected AS '2 Cash collected',
                           outstanding_receivables AS '3 Outstanding receivables', open_orders AS '4 Open orders',
                           tins_on_site AS '5 Tins on site', diversion_rate_pct AS '6 Recycling diversion %',
                           outsource_spend AS '7 Outsource spend', timesheets_pending AS '8 Timesheets pending',
                           payroll_cost AS '9 Payroll cost (gross + super)'))
 ORDER BY kpi;

PROMPT === 2. Monthly revenue by state with month-on-month growth ===
SELECT TO_CHAR(month_start, 'YYYY-MM') AS month, state_code AS st, orders,
       revenue_ex_gst AS revenue, prev_month_revenue AS prev_month,
       mom_growth_pct AS mom_pct, running_total
  FROM v_dash_monthly_revenue
 ORDER BY state_code, month_start;

PROMPT === 3. Waste category mix ===
SELECT category_name, weight_class AS wt_class, tins_hired, revenue_ex_gst AS revenue,
       avg_price, revenue_share_pct AS share_pct
  FROM v_dash_category_mix
 ORDER BY revenue_ex_gst DESC;

PROMPT === 4. Receivables ageing ===
SELECT customer_name, not_yet_due, days_1_30 AS d1_30, days_31_60 AS d31_60, days_over_60 AS d60_plus,
       total_outstanding AS total, credit_limit, credit_status AS credit
  FROM v_dash_receivables_ageing
 ORDER BY total_outstanding DESC;

PROMPT === 5. Customer ranking (Pareto) ===
SELECT spend_rank AS rank, customer_name, orders, total_billed, share_pct, cumulative_share_pct AS cum_pct
  FROM v_dash_customer_ranking
 ORDER BY spend_rank;

PROMPT === 6. Fleet performance ===
SELECT registration_no AS rego, ownership, operated_by, jobs_completed AS jobs,
       outsource_cost, maintenance_cost AS maint_cost, next_service_due AS next_service, service_status
  FROM v_dash_fleet_performance
 ORDER BY ownership, registration_no;

PROMPT === 7. Staff utilisation (last 14 days) ===
SELECT staff_name, employment_type AS emp_type, position_title, shifts_worked AS shifts,
       hours_worked AS hours, labour_cost
  FROM v_dash_staff_utilisation
 ORDER BY labour_cost DESC;

PROMPT === 8. Recycling diversion by facility ===
SELECT state_code AS st, facility_name, facility_type AS type, dockets,
       tonnes_received AS t_in, tonnes_recycled AS t_recycled, diversion_rate_pct AS divert_pct, gate_fees_paid AS gate_fees
  FROM v_dash_recycling_diversion
 ORDER BY state_code, diversion_rate_pct DESC;

PROMPT === 9. Smart tin status ===
SELECT tin_serial, size_code AS sz, tin_status, TO_CHAR(last_reading_at, 'YYYY-MM-DD HH24:MI') AS last_reading,
       fill_level_pct AS fill_pct, weight_kg, battery_pct AS batt_pct, alert
  FROM v_dash_smart_tin_status
 ORDER BY alert, tin_serial;

PROMPT === 10. Order pipeline ===
SELECT order_status, state_code AS st, orders, order_value_ex_gst AS value_ex_gst,
       earliest_delivery, latest_pickup
  FROM v_dash_order_pipeline
 ORDER BY order_status, state_code;

PROMPT === 11. Cloud performance SLA ===
SELECT service_name, cloud_region AS region, avg_cpu_pct AS cpu_avg, peak_cpu_pct AS cpu_peak,
       avg_mem_pct AS mem_avg, p95_latency_ms AS p95_ms, hours_latency_breach AS breach_hrs,
       avg_error_rate_pct AS err_pct, sla_status
  FROM v_dash_cloud_sla
 ORDER BY service_name, cloud_region;

PROMPT === 12. Payroll summary ===
SELECT period_start AS start_date, period_end AS end_date, period_status AS status, employees_paid AS emps,
       regular_hours AS reg_hrs, overtime_hours AS ot_hrs, overtime_pct AS ot_pct,
       gross_pay, tax_withheld AS tax, super_amount AS super, net_pay, timesheets_awaiting_approval AS ts_pending
  FROM v_dash_payroll_summary
 ORDER BY period_start;

PROMPT === 13. Supplier payables ===
SELECT * FROM v_dash_supplier_payables ORDER BY supplier_name;

PROMPT === 14. Masked customer view ===
SELECT customer_id AS id, customer_type, display_name, email_masked, phone_masked, customer_status AS status
  FROM v_customer_masked
 ORDER BY customer_id;

-- =====================================================================
-- SECTION 7 - INTEGRITY TESTS
-- =====================================================================
SET TIMING OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

DECLARE
    v_pass NUMBER := 0;
    v_fail NUMBER := 0;

    PROCEDURE expect_error (p_name VARCHAR2, p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        ROLLBACK;
        v_fail := v_fail + 1;
        DBMS_OUTPUT.PUT_LINE('FAIL  ' || RPAD(p_name, 58) || ' statement was accepted');
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            v_pass := v_pass + 1;
            DBMS_OUTPUT.PUT_LINE('PASS  ' || RPAD(p_name, 58) || ' rejected: ' || SUBSTR(SQLERRM, 1, LEAST(INSTR(SQLERRM || ' - ', ' - ') - 1, 100)));
    END;
BEGIN
    expect_error('Concrete cannot be ordered in an 8m3 tin',
        'INSERT INTO order_line (order_id, category_id, tin_size_id, unit_price)
         SELECT (SELECT MIN(order_id) FROM customer_order), c.category_id, s.tin_size_id, 100
           FROM waste_category c, tin_size s WHERE c.category_code = ''CONCRETE'' AND s.size_code = ''S8''');

    expect_error('Assigned tin must match the ordered size',
        'INSERT INTO order_line (order_id, category_id, tin_size_id, tin_id, unit_price)
         SELECT (SELECT MIN(order_id) FROM customer_order), c.category_id, s3.tin_size_id,
                (SELECT MIN(t.tin_id) FROM smart_tin t JOIN tin_size s2 ON s2.tin_size_id = t.tin_size_id AND s2.size_code = ''S2''), 100
           FROM waste_category c, tin_size s3 WHERE c.category_code = ''MIXED'' AND s3.size_code = ''S3''');

    expect_error('Facility must accept the disposed waste category',
        'INSERT INTO disposal_record (order_line_id, job_id, facility_id, docket_number, disposed_at, gross_weight_kg, recycled_weight_kg, gate_fee)
         SELECT ol.order_line_id, j.job_id,
                (SELECT facility_id FROM council_facility WHERE facility_name = ''Inner West Transfer Station''),
                ''TEST-DKT-1'', SYSTIMESTAMP, 500, 0, 10
           FROM order_line ol
           JOIN waste_category c ON c.category_id = ol.category_id AND c.category_code = ''CONCRETE''
           JOIN job j ON j.order_id = ol.order_id AND j.job_type = ''PICKUP''
          FETCH FIRST 1 ROWS ONLY');

    expect_error('Staff cannot have overlapping shifts',
        'INSERT INTO roster_shift (staff_id, shift_start, shift_end)
         SELECT staff_id, shift_start + INTERVAL ''1'' HOUR, shift_end + INTERVAL ''1'' HOUR
           FROM roster_shift WHERE shift_status <> ''CANCELLED'' FETCH FIRST 1 ROWS ONLY');

    expect_error('Owned vehicle must not reference a supplier',
        'INSERT INTO vehicle (registration_no, vehicle_type, make, model, year_built, capacity_tonnes, ownership, supplier_id)
         VALUES (''BAD001'', ''VAN'', ''X'', ''Y'', 2020, 5, ''OWNED'', (SELECT MIN(supplier_id) FROM outsource_supplier))');

    expect_error('Contractor must have a supplier, not a depot',
        'INSERT INTO staff (employment_type, depot_id, position_id, first_name, last_name, date_of_birth, email, hire_date, hourly_rate)
         VALUES (''CONTRACTOR'', (SELECT MIN(depot_id) FROM depot), (SELECT MIN(position_id) FROM job_position),
                 ''A'', ''B'', DATE ''1990-01-01'', ''bad.contractor@example.com'', DATE ''2024-01-01'', 40)');

    expect_error('Residential customer requires first and last name',
        'INSERT INTO customer (customer_type, email, phone, billing_address_id)
         VALUES (''RESIDENTIAL'', ''noname@example.com'', ''0400000000'', (SELECT MIN(address_id) FROM address))');

    expect_error('Invoice total must equal subtotal plus GST',
        'INSERT INTO invoice (invoice_number, order_id, issue_date, due_date, subtotal, gst_amount, total_amount)
         VALUES (''INV-BAD'', (SELECT MIN(order_id) FROM customer_order), SYSDATE, SYSDATE + 14, 100, 10, 999)');

    expect_error('Postcode must be four digits',
        'INSERT INTO address (street_line1, suburb, state_code, postcode, council_id)
         VALUES (''1 Test St'', ''Testville'', ''NSW'', ''20A0'', (SELECT MIN(council_id) FROM council))');

    expect_error('Recycled weight cannot exceed gross weight',
        'UPDATE disposal_record SET recycled_weight_kg = gross_weight_kg + 1 WHERE ROWNUM = 1');

    expect_error('Payment amount must be positive',
        'INSERT INTO payment (invoice_id, paid_at, amount, payment_method)
         VALUES ((SELECT MIN(invoice_id) FROM invoice), SYSTIMESTAMP, -5, ''CASH'')');

    expect_error('Order pickup cannot precede delivery',
        'UPDATE customer_order SET requested_pickup = requested_delivery - 1 WHERE ROWNUM = 1');

    expect_error('Address council must be in the same state',
        'INSERT INTO address (street_line1, suburb, state_code, postcode, council_id)
         VALUES (''1 Test St'', ''Testville'', ''VIC'', ''3000'', (SELECT MIN(council_id) FROM council WHERE state_code = ''NSW''))');

    expect_error('Tin cannot be booked on overlapping orders',
        'INSERT INTO order_line (order_id, category_id, tin_size_id, tin_id, unit_price)
         SELECT order_id, category_id, tin_size_id, tin_id, unit_price
           FROM order_line WHERE tin_id IS NOT NULL FETCH FIRST 1 ROWS ONLY');

    expect_error('Contractors cannot receive payslips',
        'INSERT INTO payslip (pay_period_id, staff_id, regular_hours, overtime_hours, hourly_rate, gross_pay, tax_withheld, super_amount, net_pay)
         SELECT (SELECT MIN(pay_period_id) FROM pay_period), staff_id, 1, 0, 10, 10, 2, 1.2, 8
           FROM staff WHERE employment_type = ''CONTRACTOR'' FETCH FIRST 1 ROWS ONLY');

    expect_error('Payslip net pay must equal gross minus tax',
        'INSERT INTO payslip (pay_period_id, staff_id, regular_hours, overtime_hours, hourly_rate, gross_pay, tax_withheld, super_amount, net_pay)
         SELECT (SELECT MAX(pay_period_id) FROM pay_period), staff_id, 1, 0, 10, 10, 2, 1.2, 9
           FROM staff WHERE employment_type = ''EMPLOYEE'' FETCH FIRST 1 ROWS ONLY');

    expect_error('Approved timesheet needs an approver',
        'UPDATE timesheet SET timesheet_status = ''APPROVED'', approver_id = NULL WHERE timesheet_status = ''SUBMITTED'' AND ROWNUM = 1');

    expect_error('Supplier invoice marked PAID needs a paid date',
        'UPDATE supplier_invoice SET invoice_status = ''PAID'', paid_date = NULL WHERE invoice_status = ''RECEIVED'' AND ROWNUM = 1');

    DBMS_OUTPUT.PUT_LINE('-----');
    DBMS_OUTPUT.PUT_LINE('Passed: ' || v_pass || '   Failed: ' || v_fail);
END;
/

EXIT
