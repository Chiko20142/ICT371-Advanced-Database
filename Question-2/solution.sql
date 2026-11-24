
-- ==========================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 2: UNIVERSITY FEE PAYMENTS
-- ==========================================================
-- DBMS: PostgreSQL
-- Covers parts (a) to (g).
-- ==========================================================


-- ==========================================================
-- (a) DATABASE AND SEED DATA
-- Create the four required tables.
-- ==========================================================

-- Table 1: Stores student information and total fees due.
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

-- Table 2: Stores payments made by students.
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on TIMESTAMP NOT NULL
);

-- Table 3: Records payment audit information.
CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Table 4: Stores daily payment collection summaries.
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Insert three students with different fee balances.
INSERT INTO students (student_number, full_name, fee_due)
VALUES
('STU001', 'John Banda', 5000.00),
('STU002', 'Mary Phiri', 3000.00),
('STU003', 'Peter Zulu', 4500.00);


-- ==========================================================
-- (b) FUNCTION
-- Create fn_fee_balance().
-- Calculates the outstanding fee balance of a student.
-- Returns the full fee when no payments exist.
-- Rejects unknown students.
-- ==========================================================

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN

    -- Calculate fees minus all payments.
    SELECT
        s.fee_due - COALESCE(SUM(p.amount), 0)
    INTO v_balance
    FROM students s
    LEFT JOIN payments p
        ON s.student_id = p.student_id
    WHERE s.student_id = p_student_id
    GROUP BY s.student_id, s.fee_due;

    -- Reject an unknown student.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
        p_student_id;
    END IF;

    RETURN v_balance;

END;
$$;


-- ==========================================================
-- (c) PROCEDURE
-- Create pr_receive_payment().
-- Validates payments and prevents credit balances.
-- Does not modify fee_due.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12,2),
    p_paid_on TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN

    -- Reject NULL, zero and negative amounts.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;

    -- Reject a NULL payment date.
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL';
    END IF;

    -- Lock the student row to prevent simultaneous
    -- payments from exceeding the outstanding balance.
    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    -- Reject an unknown student.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
        p_student_id;
    END IF;

    -- Calculate the outstanding balance.
    v_balance := fn_fee_balance(p_student_id);

    -- Reject payments above the outstanding balance.
    IF p_amount > v_balance THEN
        RAISE EXCEPTION
        'Payment exceeds outstanding balance. Balance: %, Payment: %',
        v_balance, p_amount;
    END IF;

    -- Insert the valid payment.
    -- The trigger automatically creates the audit record.
    INSERT INTO payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );

END;
$$;


-- ==========================================================
-- (d) TRIGGER
-- Create an AFTER INSERT trigger on payments.
-- Automatically records payment details in payment_audit.
-- ==========================================================

-- Trigger function.
CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Automatically record the inserted payment.
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;

END;
$$;

-- Create the AFTER INSERT row trigger.
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();


-- ==========================================================
-- INSERT SIX VALID PAYMENTS THROUGH THE PROCEDURE.
-- Peter Zulu initially has no payments.
-- ==========================================================

CALL pr_receive_payment(1, 1000.00, CURRENT_TIMESTAMP - INTERVAL '2 days');

CALL pr_receive_payment(1, 500.00, CURRENT_TIMESTAMP - INTERVAL '1 day');

CALL pr_receive_payment(1, 750.00, CURRENT_TIMESTAMP);

CALL pr_receive_payment(2, 600.00, CURRENT_TIMESTAMP - INTERVAL '2 days');

CALL pr_receive_payment(2, 400.00, CURRENT_TIMESTAMP - INTERVAL '1 day');

CALL pr_receive_payment(2, 300.00, CURRENT_TIMESTAMP);


-- ==========================================================
-- (e) VIEW
-- Create v_fee_balances.
-- Displays students who still owe university fees.
-- Fully settled students are excluded.
-- ==========================================================

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0)
        AS outstanding_balance
FROM students s
LEFT JOIN payments p
    ON s.student_id = p.student_id
GROUP BY
    s.student_id,
    s.student_number,
    s.full_name,
    s.fee_due
HAVING
    s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- Display outstanding fee balances.
SELECT * FROM v_fee_balances;


-- ==========================================================
-- (f) INDEX
-- Create a composite index for searching payments
-- using student_id and a paid_on date range.
-- ==========================================================

CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);

-- Matching query for the index.
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
AND paid_on >= CURRENT_DATE - INTERVAL '7 days'
AND paid_on < CURRENT_DATE + INTERVAL '1 day'
ORDER BY paid_on;

-- Display the execution plan.
EXPLAIN
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
AND paid_on >= CURRENT_DATE - INTERVAL '7 days'
AND paid_on < CURRENT_DATE + INTERVAL '1 day';

-- Index justification:
-- The composite index contains student_id and paid_on.
-- It improves searches for a particular student's
-- payments within a specified date range.


-- ==========================================================
-- (g) SCHEDULED JOB
-- Create pr_refresh_collections().
-- Calculates payment count and total amount for a date.
-- ON CONFLICT replaces existing summary values.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject a NULL date.
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Collection date cannot be NULL';
    END IF;

    -- Insert or replace the daily collection summary.
    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on >= p_day::TIMESTAMP
    AND paid_on < (p_day + 1)::TIMESTAMP

    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;

END;
$$;


-- Test the daily collections procedure.
CALL pr_refresh_collections(CURRENT_DATE);

-- Display the daily collection summary.
SELECT * FROM daily_collections;


-- ==========================================================
-- SCHEDULE THE JOB DAILY AT 01:00.
-- Processes payments from the previous day.
-- Requires pg_cron to be installed and configured.
-- ==========================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-collections',
    '0 1 * * *',
    'CALL pr_refresh_collections(CURRENT_DATE - 1);'
);


-- ==========================================================
-- END OF QUESTION 2
-- ==========================================================
