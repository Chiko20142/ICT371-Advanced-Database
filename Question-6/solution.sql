
-- ==========================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 6: MONTHLY PAYROLL PROCESSING
-- ==========================================================
-- DBMS: PostgreSQL
-- Covers parts (a) to (g).
-- Gross Pay = Basic Salary + Allowance
-- Net Pay = Gross Pay - Deduction
-- ==========================================================


-- ==========================================================
-- (a) DATABASE AND SEED DATA
-- Create the required tables and constraints.
-- ==========================================================

-- Table 1: Stores employee salary information.
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL
        CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL
        CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL
        CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);


-- Table 2: Stores monthly payroll records.
CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL,
    gross_pay NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),

    -- Each employee can have only one payroll record per month.
    CONSTRAINT uq_employee_pay_month
    UNIQUE (employee_id, pay_month),

    -- The payroll month must be the first day of the month.
    CONSTRAINT chk_pay_month
    CHECK (EXTRACT(DAY FROM pay_month) = 1)
);


-- Table 3: Records changes to employee basic salaries.
CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- Insert three employees.
-- Two active employees and one inactive employee.

INSERT INTO employees (
    full_name,
    basic_salary,
    allowance,
    deduction,
    active
)
VALUES
('John Banda', 5000.00, 1000.00, 500.00, TRUE),
('Mary Phiri', 6500.00, 1500.00, 700.00, TRUE),
('Peter Zulu', 4000.00, 800.00, 300.00, FALSE);


-- ==========================================================
-- (b) FUNCTION
-- Create fn_net_pay().
-- Calculates net pay using current employee salary details.
-- Rejects unknown employees and negative net pay.
-- ==========================================================

CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_net_pay NUMERIC(12,2);
BEGIN

    -- Calculate gross pay minus the fixed deduction.
    SELECT
        basic_salary + allowance - deduction
    INTO v_net_pay
    FROM employees
    WHERE employee_id = p_employee_id;

    -- Reject an unknown employee.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee ID % does not exist',
        p_employee_id;
    END IF;

    -- Reject negative computed net pay.
    IF v_net_pay < 0 THEN
        RAISE EXCEPTION
        'Employee % has a negative computed net pay',
        p_employee_id;
    END IF;

    RETURN v_net_pay;

END;
$$;


-- ==========================================================
-- (c) PROCEDURE
-- Create pr_process_payroll().
-- Uses a query FOR loop over active employees.
-- Inserts missing employee payroll records.
-- Existing payroll records remain unchanged.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    emp RECORD;
    v_gross_pay NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN

    -- Reject a NULL payroll month.
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'Payroll month cannot be NULL';
    END IF;

    -- Require the first day of a month.
    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION
        'Pay month must be the first day of a month';
    END IF;

    -- Loop through all active employees.
    FOR emp IN
        SELECT
            employee_id,
            basic_salary,
            allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP

        -- Calculate gross pay.
        v_gross_pay := emp.basic_salary + emp.allowance;

        -- Calculate net pay using the function.
        v_net_pay := fn_net_pay(emp.employee_id);

        -- Insert a payroll record only if it does not exist.
        -- ON CONFLICT DO NOTHING preserves existing records.
        INSERT INTO payroll (
            employee_id,
            pay_month,
            gross_pay,
            net_pay
        )
        VALUES (
            emp.employee_id,
            p_month,
            v_gross_pay,
            v_net_pay
        )
        ON CONFLICT (employee_id, pay_month)
        DO NOTHING;

    END LOOP;

END;
$$;


-- ==========================================================
-- (d) TRIGGER
-- Create an AFTER UPDATE trigger on employees.
-- Records actual changes to basic_salary.
-- Unchanged salaries must not create audit entries.
-- ==========================================================

-- Trigger function.
CREATE OR REPLACE FUNCTION fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Check whether basic salary actually changed.
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN

        INSERT INTO salary_audit (
            employee_id,
            old_salary,
            new_salary,
            changed_at
        )
        VALUES (
            NEW.employee_id,
            OLD.basic_salary,
            NEW.basic_salary,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- Create the AFTER UPDATE trigger.
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_salary_audit();


-- ==========================================================
-- SEED PAYROLL DATA FOR AT LEAST TWO MONTHS.
-- Process the previous two complete months for active staff.
-- ==========================================================

-- Process the previous month.
CALL pr_process_payroll(
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE
);

-- Process two months ago.
CALL pr_process_payroll(
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE
);


-- Add historical payroll records for the inactive employee.
-- These records demonstrate that historical payroll
-- can be retained even when an employee becomes inactive.

INSERT INTO payroll (
    employee_id,
    pay_month,
    gross_pay,
    net_pay
)
VALUES
(
    3,
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,
    4800.00,
    4500.00
),
(
    3,
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE,
    4800.00,
    4500.00
)
ON CONFLICT (employee_id, pay_month)
DO NOTHING;


-- ==========================================================
-- (e) VIEW
-- Create v_payroll_report.
-- Joins employee names to payroll information.
-- Includes historical records for inactive employees.
-- ==========================================================

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    p.payroll_id,
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e
    ON p.employee_id = e.employee_id;


-- Display the payroll report.
SELECT * FROM v_payroll_report
ORDER BY pay_month, full_name;


-- ==========================================================
-- (f) INDEX
-- Create an index for reports filtered by pay_month.
-- Avoid duplicating the employee_id and pay_month
-- unique index already created in the payroll table.
-- ==========================================================

CREATE INDEX idx_payroll_pay_month
ON payroll (pay_month);


-- Matching query for the index.
SELECT
    payroll_id,
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month =
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;


-- Display the execution plan.
EXPLAIN
SELECT
    payroll_id,
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month =
    (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;


-- Index justification:
-- The index on pay_month improves monthly payroll reports
-- that search across all employees.
-- It is separate from the existing unique index on
-- employee_id and pay_month.


-- ==========================================================
-- (g) SCHEDULED JOB
-- Schedule payroll processing for 02:00 on the first day
-- of every month.
-- The job processes the previous month's payroll.
-- ==========================================================

-- Requires pg_cron to be installed and configured.
CREATE EXTENSION IF NOT EXISTS pg_cron;


-- Schedule the monthly payroll processing job.
SELECT cron.schedule(
    'monthly-payroll-processing',
    '0 2 1 * *',
    'CALL pr_process_payroll(
        (DATE_TRUNC(''month'', CURRENT_DATE)
        - INTERVAL ''1 month'')::DATE
    );'
);


-- Inspect the scheduled job.
SELECT
    jobid,
    schedule,
    command,
    active
FROM cron.job
WHERE jobname = 'monthly-payroll-processing';


-- Inspect the job execution history.
SELECT
    jobid,
    runid,
    status,
    return_message,
    start_time,
    end_time
FROM cron.job_run_details
WHERE jobid = (
    SELECT jobid
    FROM cron.job
    WHERE jobname = 'monthly-payroll-processing'
)
ORDER BY start_time DESC;


-- ==========================================================
-- END OF QUESTION 6
-- ==========================================================
