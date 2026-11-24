
-- ==========================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
-- ==========================================================
-- DBMS: PostgreSQL
-- Covers parts (a) to (g).
-- Fine rate: K2 per overdue day.
-- ==========================================================


-- ==========================================================
-- (a) DATABASE AND SEED DATA
-- Create the required tables and constraints.
-- ==========================================================

-- Table 1: Stores information about library books.
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

-- Table 2: Stores borrowing and return information.
CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (fine_amount >= 0),

    -- The due date cannot be before the borrowing date.
    CONSTRAINT chk_due_date
        CHECK (due_on >= borrowed_on),

    -- A return cannot occur before borrowing.
    CONSTRAINT chk_return_date
        CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

-- Table 3: Records changes made to loan return dates.
CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Table 4: Stores daily overdue summaries.
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);


-- Insert three sample books.
INSERT INTO books (title)
VALUES
('Introduction to Computer Science'),
('Database Management Systems'),
('Computer Networks');


-- Insert six sample loans.
-- The records include open overdue loans,
-- an on-time return and a returned overdue loan.

INSERT INTO loans (
    book_id, borrower_name, borrowed_on,
    due_on, returned_on, fine_amount
)
VALUES
-- Open overdue loan.
(1, 'John Banda',
 CURRENT_DATE - 20,
 CURRENT_DATE - 10,
 NULL, 0),

-- Open overdue loan.
(2, 'Mary Phiri',
 CURRENT_DATE - 15,
 CURRENT_DATE - 5,
 NULL, 0),

-- Returned on the due date (no fine).
(3, 'Peter Zulu',
 CURRENT_DATE - 12,
 CURRENT_DATE - 5,
 CURRENT_DATE - 5, 0),

-- Returned late.
(1, 'James Chanda',
 CURRENT_DATE - 25,
 CURRENT_DATE - 15,
 CURRENT_DATE - 12, 6),

-- Loan not yet overdue.
(2, 'Sarah Mwila',
 CURRENT_DATE - 3,
 CURRENT_DATE + 4,
 NULL, 0),

-- Returned overdue.
(3, 'David Phiri',
 CURRENT_DATE - 30,
 CURRENT_DATE - 20,
 CURRENT_DATE - 16, 8);


-- ==========================================================
-- (b) FUNCTION
-- Create fn_loan_fine().
-- Calculates K2 for each day overdue.
-- Uses the earlier of p_as_of and returned_on.
-- Returns zero when there are no overdue days.
-- Rejects unknown loans.
-- ==========================================================

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INTEGER;
BEGIN

    -- Reject a NULL calculation date.
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Calculation date cannot be NULL';
    END IF;

    -- Retrieve the loan details.
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    -- Reject an unknown loan.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    -- Use the earlier of the requested date and return date.
    v_effective_date := LEAST(
        p_as_of,
        COALESCE(v_returned_on, p_as_of)
    );

    -- Calculate the number of overdue days.
    v_overdue_days := GREATEST(
        0,
        v_effective_date - v_due_on
    );

    -- Return K2 for each overdue day.
    RETURN v_overdue_days * 2.00;

END;
$$;


-- ==========================================================
-- (c) PROCEDURE
-- Create pr_return_loan().
-- Rejects unknown or already returned loans.
-- Rejects return dates before borrowing.
-- Stores the return date and final fine together.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_current_return DATE;
    v_final_fine NUMERIC(10,2);
BEGIN

    -- Reject a NULL return date.
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL';
    END IF;

    -- Lock the loan row while processing the return.
    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_current_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    -- Reject an unknown loan.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    -- Reject an already returned loan.
    IF v_current_return IS NOT NULL THEN
        RAISE EXCEPTION 'This loan has already been returned';
    END IF;

    -- Return date must not be before borrowing date.
    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date cannot be before borrowing date';
    END IF;

    -- Calculate the final fine using the return date.
    v_final_fine := fn_loan_fine(
        p_loan_id,
        p_returned_on
    );

    -- Store the return date and final fine.
    UPDATE loans
    SET
        returned_on = p_returned_on,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;

END;
$$;


-- ==========================================================
-- (d) TRIGGER
-- Create an AFTER UPDATE trigger on loans.
-- Records actual changes to returned_on.
-- Unchanged dates must not produce audit entries.
-- ==========================================================

-- Trigger function.
CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Check whether the return date actually changed.
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN

        INSERT INTO loan_audit (
            loan_id,
            old_returned_on,
            new_returned_on,
            changed_at
        )
        VALUES (
            NEW.loan_id,
            OLD.returned_on,
            NEW.returned_on,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- Create the AFTER UPDATE trigger.
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_loan_audit();


-- ==========================================================
-- TEST THE RETURN PROCEDURE.
-- Return one of the previously open overdue loans.
-- ==========================================================

CALL pr_return_loan(1, CURRENT_DATE);


-- Display the updated loan.
SELECT * FROM loans;

-- Display the automatically generated audit record.
SELECT * FROM loan_audit;


-- ==========================================================
-- (e) VIEW
-- Create v_overdue_loans.
-- Shows loans that are currently unreturned and overdue.
-- Includes book title, borrower, due date and current fine.
-- ==========================================================

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_amount
FROM loans l
JOIN books b
    ON l.book_id = b.book_id
WHERE l.returned_on IS NULL
AND l.due_on < CURRENT_DATE;


-- Display currently overdue loans.
SELECT * FROM v_overdue_loans;


-- ==========================================================
-- (f) INDEX
-- Create an index for searching unreturned loans
-- belonging to a particular book.
-- ==========================================================

CREATE INDEX idx_loans_unreturned_book
ON loans (book_id)
WHERE returned_on IS NULL;


-- Matching query for the index.
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on
FROM loans
WHERE book_id = 1
AND returned_on IS NULL;


-- Display the execution plan.
EXPLAIN
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on
FROM loans
WHERE book_id = 1
AND returned_on IS NULL;


-- Index justification:
-- This is a partial index because it only stores
-- records where returned_on IS NULL.
-- It improves searches for unreturned loans
-- belonging to a particular book.


-- ==========================================================
-- (g) SCHEDULED JOB
-- Create pr_refresh_overdue().
-- Counts overdue loans and calculates their total fines.
-- Replaces the existing summary for the same date.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject a NULL date.
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Snapshot date cannot be NULL';
    END IF;

    -- Insert or replace the overdue summary.
    INSERT INTO overdue_summary (
        snapshot_date,
        overdue_count,
        total_fine
    )
    SELECT
        p_as_of,
        COUNT(*)::INTEGER,
        COALESCE(
            SUM(fn_loan_fine(loan_id, p_as_of)),
            0
        )
    FROM loans
    WHERE returned_on IS NULL
    AND due_on < p_as_of

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;

END;
$$;


-- Test the overdue summary procedure.
CALL pr_refresh_overdue(CURRENT_DATE);


-- Display the overdue summary.
SELECT * FROM overdue_summary;


-- ==========================================================
-- SCHEDULE THE JOB DAILY AT 00:10.
-- Processes overdue loans as of the current date.
-- Requires pg_cron to be installed and configured.
-- ==========================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-overdue-summary',
    '10 0 * * *',
    'CALL pr_refresh_overdue(CURRENT_DATE);'
);


-- ==========================================================
-- END OF QUESTION 3
-- ==========================================================
