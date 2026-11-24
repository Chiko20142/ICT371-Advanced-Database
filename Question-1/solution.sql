
-- =====================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 1: PHARMACY STOCK AND DAILY SALES
-- =====================================================

-- PART (a): DATABASE AND SEED DATA
-- Create the four required tables.

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on TIMESTAMP NOT NULL
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Insert three sample medicines.
INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
('Paracetamol', 15.00, 100),
('Amoxicillin', 35.00, 80),
('Ibuprofen', 20.00, 60);


-- PART (b): FUNCTION
-- Calculate the value of a medicine sale.
-- Reject unknown medicines and invalid quantities.

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine ID';
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


-- PART (c): PROCEDURE
-- Record a sale, check stock and deduct the quantity.
-- FOR UPDATE prevents concurrent overselling.

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock INTEGER;
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid sale quantity';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    SELECT stock_qty, unit_price
    INTO v_stock, v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;

    -- Use the function to validate and calculate sale value.
    PERFORM fn_sale_value(p_medicine_id, p_quantity);

    -- Insert the sale using the current medicine price.
    INSERT INTO sales (
        medicine_id, quantity, unit_price, sold_on
    )
    VALUES (
        p_medicine_id, p_quantity, v_price, p_sold_on
    );

    -- Deduct stock exactly once.
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;


-- PART (d): TRIGGER
-- Record old and new stock quantities after an update.

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (
            medicine_id, old_qty, new_qty, changed_at
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_stock_audit();


-- Insert six valid sales through the procedure.

CALL pr_record_sale(1, 5, CURRENT_TIMESTAMP - INTERVAL '2 days');
CALL pr_record_sale(1, 3, CURRENT_TIMESTAMP - INTERVAL '1 day');
CALL pr_record_sale(2, 4, CURRENT_TIMESTAMP - INTERVAL '2 days');
CALL pr_record_sale(2, 2, CURRENT_TIMESTAMP - INTERVAL '1 day');
CALL pr_record_sale(3, 4, CURRENT_TIMESTAMP - INTERVAL '2 days');
CALL pr_record_sale(3, 1, CURRENT_TIMESTAMP - INTERVAL '1 day');


-- PART (e): VIEW
-- Display medicines with stock below 10 units.

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10;

-- Query the view after recording sales.
SELECT * FROM v_low_stock;


-- PART (f): INDEX
-- Support medicine sales searches within a date range.

CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

-- Matching query.
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on >= CURRENT_DATE - INTERVAL '7 days'
AND sold_on < CURRENT_DATE + INTERVAL '1 day'
ORDER BY sold_on;

-- Display the execution plan.
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on >= CURRENT_DATE - INTERVAL '7 days'
AND sold_on < CURRENT_DATE + INTERVAL '1 day';

-- Justification:
-- The composite index improves searches by medicine ID
-- and the sold_on date range.


-- PART (g): SCHEDULED JOB
-- Refresh daily sales totals without double-counting.

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Date cannot be NULL';
    END IF;

    INSERT INTO daily_sales (
        sales_date, total_qty, total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0)::INTEGER,
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on >= p_day::TIMESTAMP
    AND sold_on < (p_day + 1)::TIMESTAMP

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Test the daily sales procedure.
CALL pr_refresh_sales(CURRENT_DATE - 1);

-- Display the daily sales summary.
SELECT * FROM daily_sales;


-- Schedule the procedure daily at 00:15.
-- Requires pg_cron to be installed and configured.

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-sales',
    '15 0 * * *',
    'CALL pr_refresh_sales(CURRENT_DATE - 1);'
);

-- =====================================================
-- END OF QUESTION 1
-- =====================================================
