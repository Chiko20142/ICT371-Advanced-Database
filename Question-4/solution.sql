
-- ==========================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 4: CLINIC APPOINTMENT SCHEDULING
-- ==========================================================
-- DBMS: PostgreSQL
-- Covers parts (a) to (g).
-- Available appointment slots: 09:00, 10:00, 11:00, 12:00
-- ==========================================================


-- ==========================================================
-- (a) DATABASE AND SEED DATA
-- Create the required tables and constraints.
-- ==========================================================

-- Table 1: Stores patient information.
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Table 2: Stores doctor information.
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Table 3: Stores clinic appointments.
CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'BOOKED',

    -- Only the four supported appointment slots are allowed.
    CONSTRAINT chk_appointment_slot
    CHECK (slot_time IN (
        '09:00:00',
        '10:00:00',
        '11:00:00',
        '12:00:00'
    )),

    -- Only the three specified statuses are allowed.
    CONSTRAINT chk_appointment_status
    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Table 4: Stores daily clinic appointment summaries.
CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL DEFAULT 0,
    attended_count INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);


-- Insert three sample patients.
INSERT INTO patients (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');


-- Insert three sample doctors.
INSERT INTO doctors (full_name)
VALUES
('Dr. James Mwansa'),
('Dr. Sarah Phiri'),
('Dr. David Banda');


-- Insert six appointments without violating the slot rule.
INSERT INTO appointments (
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
)
VALUES
(1, 1, CURRENT_DATE, '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE, '10:00', 'ATTENDED'),
(2, 2, CURRENT_DATE, '09:00', 'BOOKED'),
(3, 2, CURRENT_DATE, '11:00', 'CANCELLED'),
(1, 3, CURRENT_DATE, '10:00', 'BOOKED'),
(3, 3, CURRENT_DATE, '12:00', 'ATTENDED');


-- ==========================================================
-- (b) FUNCTION
-- Create fn_daily_load().
-- Returns the number of non-cancelled appointments
-- for a particular doctor on a specified date.
-- Rejects an unknown doctor.
-- Returns zero when there are no bookings.
-- ==========================================================

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Reject a NULL appointment date.
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Appointment date cannot be NULL';
    END IF;

    -- Check whether the doctor exists.
    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor ID % does not exist',
        p_doctor_id;
    END IF;

    -- Count appointments that are not cancelled.
    SELECT COUNT(*)::INTEGER
    INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
    AND appointment_day = p_day
    AND status <> 'CANCELLED';

    RETURN v_count;

END;
$$;


-- ==========================================================
-- (c) PROCEDURE
-- Create pr_book_appointment().
-- Validates patient and doctor IDs.
-- Rejects past dates and unsupported slots.
-- Inserts a new BOOKED appointment.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id INTEGER,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject a NULL appointment date.
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Appointment date cannot be NULL';
    END IF;

    -- Reject past appointment dates.
    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book an appointment in the past';
    END IF;

    -- Validate the appointment slot.
    IF p_slot IS NULL OR p_slot NOT IN (
        '09:00:00',
        '10:00:00',
        '11:00:00',
        '12:00:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;

    -- Check whether the patient exists.
    PERFORM 1
    FROM patients
    WHERE patient_id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient ID % does not exist',
        p_patient_id;
    END IF;

    -- Check whether the doctor exists.
    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor ID % does not exist',
        p_doctor_id;
    END IF;

    -- Insert a new BOOKED appointment.
    -- The trigger will check for appointment clashes.
    INSERT INTO appointments (
        patient_id,
        doctor_id,
        appointment_day,
        slot_time,
        status
    )
    VALUES (
        p_patient_id,
        p_doctor_id,
        p_day,
        p_slot,
        'BOOKED'
    );

END;
$$;


-- ==========================================================
-- (d) TRIGGER
-- Create a BEFORE INSERT OR UPDATE row trigger.
-- Prevents two non-cancelled appointments from occupying
-- the same doctor, date and time slot.
-- On UPDATE, excludes the appointment being changed.
-- ==========================================================

-- Trigger function.
CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Cancelled appointments do not occupy a slot.
    IF NEW.status <> 'CANCELLED' THEN

        -- Serialize bookings for the same doctor and date.
        -- This helps prevent concurrent booking clashes.
        PERFORM pg_advisory_xact_lock(
            hashtextextended(
                NEW.doctor_id::TEXT || ':' ||
                NEW.appointment_day::TEXT,
                0
            )
        );

        -- Check for another non-cancelled appointment
        -- using the same doctor, date and time slot.
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
            AND a.appointment_day = NEW.appointment_day
            AND a.slot_time = NEW.slot_time
            AND a.status <> 'CANCELLED'
            AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN

            RAISE EXCEPTION
            'Appointment clash: Doctor %, date % and slot % are already booked',
            NEW.doctor_id,
            NEW.appointment_day,
            NEW.slot_time;

        END IF;

    END IF;

    RETURN NEW;

END;
$$;


-- Create the BEFORE INSERT OR UPDATE trigger.
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();


-- ==========================================================
-- TEST THE BOOKING PROCEDURE.
-- This booking uses a free slot.
-- ==========================================================

CALL pr_book_appointment(
    2,
    1,
    CURRENT_DATE + 1,
    '11:00'
);


-- Display all appointments.
SELECT * FROM appointments;


-- ==========================================================
-- (e) VIEW
-- Create v_today_appointments.
-- Shows today's BOOKED appointments only.
-- Includes patient name, doctor name and appointment slot.
-- ==========================================================

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    a.appointment_id,
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p
    ON a.patient_id = p.patient_id
JOIN doctors d
    ON a.doctor_id = d.doctor_id
WHERE a.appointment_day = CURRENT_DATE
AND a.status = 'BOOKED';


-- Display today's booked appointments.
SELECT * FROM v_today_appointments;


-- ==========================================================
-- (f) INDEX
-- Create a non-unique index for appointments searched
-- using appointment_day and doctor_id.
-- ==========================================================

CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);


-- Matching query for the index.
SELECT
    appointment_id,
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
FROM appointments
WHERE appointment_day = CURRENT_DATE
AND doctor_id = 1;


-- Display the execution plan.
EXPLAIN
SELECT
    appointment_id,
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
FROM appointments
WHERE appointment_day = CURRENT_DATE
AND doctor_id = 1;


-- Index justification:
-- The non-unique composite index contains appointment_day
-- and doctor_id.
-- It improves searches for a doctor's appointments
-- on a particular date.


-- ==========================================================
-- (g) SCHEDULED JOB
-- Create pr_refresh_clinic_summary().
-- Counts BOOKED, ATTENDED and CANCELLED appointments.
-- Replaces existing summary values when rerun.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject a NULL date.
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Summary date cannot be NULL';
    END IF;

    -- Insert or replace the daily clinic summary.
    INSERT INTO clinic_summary (
        summary_date,
        booked_count,
        attended_count,
        cancelled_count
    )
    SELECT
        p_day,
        COUNT(*) FILTER (
            WHERE status = 'BOOKED'
        )::INTEGER,
        COUNT(*) FILTER (
            WHERE status = 'ATTENDED'
        )::INTEGER,
        COUNT(*) FILTER (
            WHERE status = 'CANCELLED'
        )::INTEGER
    FROM appointments
    WHERE appointment_day = p_day

    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;

END;
$$;


-- Test the clinic summary procedure.
CALL pr_refresh_clinic_summary(CURRENT_DATE);


-- Display the daily clinic summary.
SELECT * FROM clinic_summary;


-- ==========================================================
-- SCHEDULE THE JOB DAILY AT 01:00.
-- Processes appointments from the previous day.
-- Requires pg_cron to be installed and configured.
-- ==========================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-clinic-summary',
    '0 1 * * *',
    'CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);'
);


-- ==========================================================
-- END OF QUESTION 4
-- ==========================================================
