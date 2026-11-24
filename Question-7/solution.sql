
-- ============================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 7: WATER METER READINGS AND BILLING
-- ============================================================

-- ============================================================
-- PART (a): DATABASE AND SEED DATA
-- ============================================================

-- 1. Create customers table
CREATE TABLE IF NOT EXISTS customers (
    customer_id INTEGER PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- 2. Create readings table
CREATE TABLE IF NOT EXISTS readings (
    reading_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL,
    current_reading NUMERIC(12,2) NOT NULL,

    CONSTRAINT fk_reading_customer
        FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),

    CONSTRAINT uq_customer_month
        UNIQUE (customer_id, reading_month),

    CONSTRAINT chk_previous_reading
        CHECK (previous_reading >= 0),

    CONSTRAINT chk_current_reading
        CHECK (current_reading >= 0),

    CONSTRAINT chk_month_start
        CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

-- 3. Create bills table
CREATE TABLE IF NOT EXISTS bills (
    bill_id INTEGER PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE,
    charge NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,

    CONSTRAINT fk_bill_reading
        FOREIGN KEY (reading_id)
        REFERENCES readings(reading_id),

    CONSTRAINT chk_charge
        CHECK (charge >= 0),

    CONSTRAINT chk_amount_paid
        CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

-- 4. Create receivable snapshot table
CREATE TABLE IF NOT EXISTS receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
        CHECK (total_due >= 0)
);

-- Insert three customers
INSERT INTO customers (customer_id, full_name)
VALUES
    (1, 'John Banda'),
    (2, 'Mary Phiri'),
    (3, 'Peter Zulu')
ON CONFLICT (customer_id) DO NOTHING;


-- ============================================================
-- PART (d): TRIGGER
-- Install the trigger before inserting readings.
-- It prevents current_reading from being below previous_reading.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Current meter reading cannot be below previous reading';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();


-- Insert six readings.
-- These cover zero consumption, exactly 10 units and above 10.

INSERT INTO readings
    (reading_id, customer_id, reading_month,
     previous_reading, current_reading)
VALUES
    (1, 1, DATE_TRUNC('month', CURRENT_DATE)::DATE,
     100, 100),

    (2, 1, (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE,
     100, 110),

    (3, 2, DATE_TRUNC('month', CURRENT_DATE)::DATE,
     200, 215),

    (4, 2, (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE,
     215, 225),

    (5, 3, DATE_TRUNC('month', CURRENT_DATE)::DATE,
     300, 305),

    (6, 3, (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE,
     305, 325)

ON CONFLICT (reading_id) DO NOTHING;


-- ============================================================
-- PART (b): FUNCTION - fn_water_charge
-- First 10 units cost K5 each.
-- Units above 10 cost K8 each.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION
            'Consumption cannot be NULL or negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := 50 + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;


-- Test the function
SELECT fn_water_charge(0) AS zero_units;
SELECT fn_water_charge(10) AS ten_units;
SELECT fn_water_charge(15) AS fifteen_units;


-- ============================================================
-- PART (c): PROCEDURE - pr_generate_bill
-- Calculates consumption and generates a bill.
-- Rejects unknown readings and duplicate bills.
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous NUMERIC(12,2);
    v_current NUMERIC(12,2);
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    -- Find the meter reading
    SELECT previous_reading, current_reading
    INTO v_previous, v_current
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Reading ID % does not exist', p_reading_id;
    END IF;

    -- Check whether a bill already exists
    IF EXISTS (
        SELECT 1
        FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION
            'A bill already exists for reading ID %', p_reading_id;
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    -- Calculate water consumption
    v_units := v_current - v_previous;

    -- Calculate the bill using the function
    v_charge := fn_water_charge(v_units);

    -- Insert the bill with zero amount paid
    INSERT INTO bills (
        bill_id,
        reading_id,
        charge,
        amount_paid,
        due_on
    )
    VALUES (
        (SELECT COALESCE(MAX(bill_id), 0) + 1 FROM bills),
        p_reading_id,
        v_charge,
        0,
        p_due_on
    );

    RAISE NOTICE 'Bill generated successfully. Charge: K%', v_charge;
END;
$$;


-- Generate bills for all six readings.
-- Some due dates are in the past to demonstrate overdue bills.

CALL pr_generate_bill(1, CURRENT_DATE - 10);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 3);
CALL pr_generate_bill(4, CURRENT_DATE + 15);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE - 2);


-- ============================================================
-- PART (e): VIEW - v_overdue_bills
-- Shows customers who have unpaid overdue bills.
-- ============================================================

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
WHERE
    b.due_on < CURRENT_DATE
    AND b.amount_paid < b.charge;


-- Query the overdue bills view
SELECT * FROM v_overdue_bills;


-- ============================================================
-- PART (f): INDEX FOR OVERDUE BILL SEARCHES
-- A partial index stores only bills that are not fully paid.
-- This supports searches by due date.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_bills_unpaid_due_date
ON bills(due_on)
WHERE amount_paid < charge;


-- Matching query
SELECT
    bill_id,
    reading_id,
    due_on,
    charge,
    amount_paid,
    (charge - amount_paid) AS outstanding_amount
FROM bills
WHERE
    due_on < CURRENT_DATE
    AND amount_paid < charge
ORDER BY due_on;


-- Display the query execution plan
EXPLAIN
SELECT
    bill_id,
    reading_id,
    due_on,
    charge,
    amount_paid
FROM bills
WHERE
    due_on < CURRENT_DATE
    AND amount_paid < charge
ORDER BY due_on;


-- ============================================================
-- PART (g): DAILY RECEIVABLE SNAPSHOT
-- Stores the total unpaid bill balances for the current date.
-- ON CONFLICT replaces the existing date's total.
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(14,2);
BEGIN
    -- Calculate all outstanding bill balances
    SELECT COALESCE(
        SUM(charge - amount_paid), 0
    )
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    -- Insert or replace today's snapshot
    INSERT INTO receivable_snapshot (
        snapshot_date,
        total_due
    )
    VALUES (
        CURRENT_DATE,
        v_total_due
    )
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;

    RAISE NOTICE
        'Receivable snapshot refreshed. Total due: K%',
        v_total_due;
END;
$$;


-- Test the snapshot procedure
CALL pr_refresh_receivables();

-- View the stored snapshot
SELECT * FROM receivable_snapshot;


-- ============================================================
-- SCHEDULED JOB
-- Run every day at 00:30.
-- Requires the pg_cron extension to be installed and configured.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-receivables-daily',
    '30 0 * * *',
    'CALL pr_refresh_receivables();'
);


-- Inspect the scheduled job
SELECT *
FROM cron.job
WHERE jobname = 'refresh-receivables-daily';


-- Inspect the job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;


-- ============================================================
-- END OF QUESTION 7
-- ============================================================
