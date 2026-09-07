-- =====================================================================
-- HOSPITAL MANAGEMENT DATABASE SCHEMA
-- PostgreSQL 14+
-- Includes: core clinical tables, lab tests/results, staff scheduling,
-- insurance claims, and HIPAA-oriented security controls
-- =====================================================================

-- Extensions needed for UUIDs and field-level encryption
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================================
-- SECTION 1: ORGANIZATIONAL STRUCTURE
-- =====================================================================

CREATE TABLE departments (
    department_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(100) NOT NULL,
    floor           VARCHAR(20),
    phone_extension VARCHAR(10),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Roles for RBAC (HIPAA: access limited to minimum necessary per role)
CREATE TABLE roles (
    role_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    role_name   VARCHAR(50) UNIQUE NOT NULL,  -- e.g. 'physician', 'nurse', 'billing_clerk', 'lab_tech', 'admin'
    description TEXT
);

-- Unified staff table: doctors, nurses, technicians, billing staff, admins
CREATE TABLE staff (
    staff_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name       VARCHAR(150) NOT NULL,
    email           VARCHAR(150) UNIQUE NOT NULL,
    phone           VARCHAR(20),
    department_id   UUID REFERENCES departments(department_id),
    role_id         UUID REFERENCES roles(role_id),
    hire_date       DATE,
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE doctors (
    doctor_id       UUID PRIMARY KEY REFERENCES staff(staff_id),
    specialization  VARCHAR(100),
    license_number  VARCHAR(50) UNIQUE NOT NULL,
    npi_number      VARCHAR(20) UNIQUE
);

-- =====================================================================
-- SECTION 2: STAFF SCHEDULING
-- =====================================================================

CREATE TABLE shifts (
    shift_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    staff_id    UUID NOT NULL REFERENCES staff(staff_id),
    ward        VARCHAR(50),
    start_time  TIMESTAMPTZ NOT NULL,
    end_time    TIMESTAMPTZ NOT NULL,
    shift_type  VARCHAR(20) DEFAULT 'regular',  -- regular, on_call, overtime
    CHECK (end_time > start_time)
);

CREATE INDEX idx_shifts_staff_time ON shifts(staff_id, start_time);

-- =====================================================================
-- SECTION 3: PATIENTS (PII fields encrypted at rest — see Section 7)
-- =====================================================================

CREATE TABLE patients (
    patient_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name       VARCHAR(150) NOT NULL,
    dob             DATE NOT NULL,
    phone           VARCHAR(20),
    address         TEXT,
    blood_type      VARCHAR(5),
    ssn_encrypted   BYTEA,              -- encrypted via pgp_sym_encrypt, never stored plaintext
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE rooms (
    room_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ward        VARCHAR(50) NOT NULL,
    room_number VARCHAR(10) NOT NULL,
    status      VARCHAR(20) DEFAULT 'available',  -- available, occupied, maintenance
    UNIQUE(ward, room_number)
);

-- =====================================================================
-- SECTION 4: APPOINTMENTS & ADMISSIONS
-- =====================================================================

CREATE TABLE appointments (
    appointment_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id      UUID NOT NULL REFERENCES patients(patient_id),
    doctor_id       UUID NOT NULL REFERENCES doctors(doctor_id),
    scheduled_at    TIMESTAMPTZ NOT NULL,
    status          VARCHAR(20) DEFAULT 'scheduled',  -- scheduled, completed, cancelled, no_show
    reason          TEXT
);

CREATE INDEX idx_appointments_patient ON appointments(patient_id);
CREATE INDEX idx_appointments_doctor ON appointments(doctor_id, scheduled_at);

CREATE TABLE admissions (
    admission_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patients(patient_id),
    room_id             UUID REFERENCES rooms(room_id),
    attending_doctor_id UUID REFERENCES doctors(doctor_id),
    admitted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    discharged_at       TIMESTAMPTZ,
    admission_reason    TEXT
);

CREATE INDEX idx_admissions_patient ON admissions(patient_id);

-- =====================================================================
-- SECTION 5: CLINICAL RECORDS, PRESCRIPTIONS, LAB TESTS
-- =====================================================================

CREATE TABLE medical_records (
    record_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id    UUID REFERENCES admissions(admission_id),
    patient_id      UUID NOT NULL REFERENCES patients(patient_id),
    diagnosis       TEXT,
    notes           TEXT,
    created_by      UUID REFERENCES staff(staff_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE prescriptions (
    prescription_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id       UUID NOT NULL REFERENCES medical_records(record_id),
    medication      VARCHAR(150) NOT NULL,
    dosage          VARCHAR(50),
    frequency       VARCHAR(50),
    prescribed_by   UUID REFERENCES doctors(doctor_id),
    start_date      DATE,
    end_date        DATE
);

CREATE TABLE lab_tests (
    test_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id      UUID NOT NULL REFERENCES patients(patient_id),
    ordered_by      UUID REFERENCES doctors(doctor_id),
    test_type       VARCHAR(100) NOT NULL,  -- e.g. CBC, Lipid Panel, Urinalysis
    ordered_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    status          VARCHAR(20) DEFAULT 'ordered'  -- ordered, in_progress, completed, cancelled
);

CREATE TABLE lab_results (
    result_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    test_id         UUID NOT NULL REFERENCES lab_tests(test_id),
    result_value    VARCHAR(100),
    unit            VARCHAR(20),
    reference_range VARCHAR(50),
    flag            VARCHAR(20),  -- normal, high, low, critical
    reported_at     TIMESTAMPTZ,
    reviewed_by     UUID REFERENCES staff(staff_id)
);

CREATE INDEX idx_lab_tests_patient ON lab_tests(patient_id);
CREATE INDEX idx_lab_results_test ON lab_results(test_id);

-- =====================================================================
-- SECTION 6: BILLING & INSURANCE CLAIMS
-- =====================================================================

CREATE TABLE insurance_providers (
    provider_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(150) NOT NULL,
    contact_phone   VARCHAR(20),
    contact_email   VARCHAR(150)
);

CREATE TABLE patient_insurance (
    patient_insurance_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id      UUID NOT NULL REFERENCES patients(patient_id),
    provider_id     UUID NOT NULL REFERENCES insurance_providers(provider_id),
    policy_number   VARCHAR(50) NOT NULL,
    group_number    VARCHAR(50),
    valid_from      DATE,
    valid_to        DATE
);

CREATE TABLE billing (
    bill_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id    UUID REFERENCES admissions(admission_id),
    patient_id      UUID NOT NULL REFERENCES patients(patient_id),
    amount          DECIMAL(10,2) NOT NULL,
    payment_status  VARCHAR(20) DEFAULT 'pending',  -- pending, paid, partial, overdue
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE insurance_claims (
    claim_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bill_id             UUID NOT NULL REFERENCES billing(bill_id),
    patient_insurance_id UUID NOT NULL REFERENCES patient_insurance(patient_insurance_id),
    claim_amount        DECIMAL(10,2) NOT NULL,
    approved_amount     DECIMAL(10,2),
    status              VARCHAR(20) DEFAULT 'submitted',  -- submitted, under_review, approved, denied, paid
    submitted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at         TIMESTAMPTZ,
    denial_reason       TEXT
);

CREATE INDEX idx_claims_status ON insurance_claims(status);

-- =====================================================================
-- SECTION 7: HIPAA — AUDIT LOGGING
-- Every access/modification to a patient-linked table must be logged.
-- =====================================================================

CREATE TABLE audit_log (
    audit_id     BIGSERIAL PRIMARY KEY,
    staff_id     UUID REFERENCES staff(staff_id),
    action       VARCHAR(20) NOT NULL,   -- SELECT, INSERT, UPDATE, DELETE
    table_name   VARCHAR(50) NOT NULL,
    record_id    UUID,
    patient_id   UUID,                  -- denormalized for fast "who accessed patient X" queries
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ip_address   INET
);

CREATE INDEX idx_audit_patient ON audit_log(patient_id, occurred_at);
CREATE INDEX idx_audit_staff ON audit_log(staff_id, occurred_at);

-- Generic trigger function: logs every write to a PHI-bearing table.
-- Attach to medical_records, prescriptions, lab_results, admissions, billing.
CREATE OR REPLACE FUNCTION fn_audit_phi_write() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_log(staff_id, action, table_name, record_id, patient_id)
    VALUES (
        current_setting('app.current_staff_id', true)::UUID,
        TG_OP,
        TG_TABLE_NAME,
        COALESCE(NEW.record_id, NEW.test_id, NEW.admission_id, NEW.bill_id, NULL),
        COALESCE(NEW.patient_id, NULL)
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_medical_records
    AFTER INSERT OR UPDATE ON medical_records
    FOR EACH ROW EXECUTE FUNCTION fn_audit_phi_write();

CREATE TRIGGER trg_audit_lab_results
    AFTER INSERT OR UPDATE ON lab_results
    FOR EACH ROW EXECUTE FUNCTION fn_audit_phi_write();

-- =====================================================================
-- SECTION 8: HIPAA — FIELD ENCRYPTION EXAMPLE (pgcrypto)
-- =====================================================================

-- Insert with encryption (app passes the encryption key via env var / secrets manager, never hardcoded)
-- INSERT INTO patients (full_name, dob, ssn_encrypted)
-- VALUES ('Jane Doe', '1980-05-02', pgp_sym_encrypt('123-45-6789', :'app_key'));

-- Read with decryption (only for roles authorized to view SSN)
-- SELECT full_name, pgp_sym_decrypt(ssn_encrypted, :'app_key') AS ssn
-- FROM patients WHERE patient_id = :'id';

-- =====================================================================
-- SECTION 9: HIPAA — ROW-LEVEL SECURITY EXAMPLE
-- Restricts staff to viewing only patients in their department's care.
-- =====================================================================

ALTER TABLE medical_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY medical_records_department_access ON medical_records
    USING (
        created_by IN (
            SELECT staff_id FROM staff
            WHERE department_id = current_setting('app.current_department_id', true)::UUID
        )
        OR current_setting('app.current_role', true) = 'admin'
    );

-- =====================================================================
-- END OF SCHEMA
-- =====================================================================
