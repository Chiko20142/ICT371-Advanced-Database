
-- ==========================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 5: HOSTEL ROOM ALLOCATION
-- ==========================================================
-- DBMS: PostgreSQL
-- Covers parts (a) to (g).
-- ==========================================================


-- ==========================================================
-- (a) DATABASE AND SEED DATA
-- Create the required tables and constraints.
-- ==========================================================

-- Table 1: Stores student information.
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

-- Table 2: Stores hostel room information.
CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

-- Table 3: Stores room allocation records.
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL,

    -- Only ACTIVE and ENDED statuses are allowed.
    CONSTRAINT chk_allocation_status
    CHECK (status IN ('ACTIVE', 'ENDED')),

    -- ACTIVE allocations must have no release date.
    -- ENDED allocations must have a release date.
    CONSTRAINT chk_allocation_release
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    ),

    -- Release date cannot be before allocation date.
    CONSTRAINT chk_allocation_dates
    CHECK (
        released_on IS NULL
        OR released_on >= allocated_on
    )
);

-- Table 4: Stores daily room occupancy snapshots.
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL DEFAULT 0,
    free_beds INTEGER NOT NULL DEFAULT 0,

    -- One snapshot per room per date.
    PRIMARY KEY (snapshot_date, room_id),

    CHECK (occupied_beds >= 0),
    CHECK (free_beds >= 0)
);


-- Insert four sample students.
INSERT INTO students (student_number, full_name)
VALUES
('STU001', 'John Banda'),
('STU002', 'Mary Phiri'),
('STU003', 'Peter Zulu'),
('STU004', 'James Mwila');


-- Insert three hostel rooms with different capacities.
INSERT INTO rooms (room_number, capacity)
VALUES
('ROOM101', 2),
('ROOM102', 3),
('ROOM103', 1);


-- Insert allocations showing full, partly occupied
-- and empty rooms.
-- Room 101: Two active allocations (FULL).
-- Room 102: One active allocation (PARTLY OCCUPIED).
-- Room 103: No active allocations (EMPTY).

INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES
(1, 1, CURRENT_DATE - 30, NULL, 'ACTIVE'),
(2, 1, CURRENT_DATE - 20, NULL, 'ACTIVE'),
(3, 2, CURRENT_DATE - 10, NULL, 'ACTIVE'),

-- Ended allocation retained as historical information.
(4, 3, CURRENT_DATE - 40, CURRENT_DATE - 10, 'ENDED');


-- ==========================================================
-- (b) FUNCTION
-- Create fn_free_beds().
-- Calculates room capacity minus active allocations.
-- Ended allocations are not counted.
-- Rejects an unknown room.
-- ==========================================================

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN

    -- Retrieve the room capacity.
    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    -- Reject an unknown room.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist',
        p_room_id;
    END IF;

    -- Count only ACTIVE allocations.
    SELECT COUNT(*)::INTEGER
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
    AND status = 'ACTIVE';

    -- Return the number of available beds.
    RETURN v_capacity - v_occupied;

END;
$$;


-- ==========================================================
-- (c) PROCEDURE
-- Create pr_allocate_room().
-- Validates student and room IDs.
-- Prevents multiple active allocations per student.
-- Checks room availability before allocating.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_free_beds INTEGER;
BEGIN

    -- Reject a NULL allocation date.
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    -- Check whether the student exists.
    PERFORM 1
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
        p_student_id;
    END IF;

    -- Check whether the room exists.
    PERFORM 1
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist',
        p_room_id;
    END IF;

    -- Lock the student row to prevent simultaneous
    -- active allocations for the same student.
    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    -- Reject students who already have an active allocation.
    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
        AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
        'Student already has an active room allocation';
    END IF;

    -- Check the available beds.
    v_free_beds := fn_free_beds(p_room_id);

    IF v_free_beds <= 0 THEN
        RAISE EXCEPTION 'The selected room is full';
    END IF;

    -- Create a new active allocation.
    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

END;
$$;


-- ==========================================================
-- (d) TRIGGER
-- Create a BEFORE INSERT OR UPDATE row trigger.
-- Enforces room capacity and one active allocation
-- per student, including direct SQL changes.
-- Excludes the current row when checking UPDATE operations.
-- ==========================================================

-- Trigger function.
CREATE OR REPLACE FUNCTION fn_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
    v_student_count INTEGER;
BEGIN

    -- Ended allocations do not occupy beds.
    IF NEW.status = 'ACTIVE' THEN

        -- Lock the room to serialize allocation changes
        -- involving the same room.
        PERFORM pg_advisory_xact_lock(
            hashtextextended('room:' || NEW.room_id::TEXT, 0)
        );

        -- Lock the student to serialize allocation changes
        -- involving the same student.
        PERFORM pg_advisory_xact_lock(
            hashtextextended('student:' || NEW.student_id::TEXT, 0)
        );

        -- Retrieve the room capacity.
        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Room ID % does not exist',
            NEW.room_id;
        END IF;

        -- Count other active allocations in this room.
        -- Exclude the current row during UPDATE.
        SELECT COUNT(*)::INTEGER
        INTO v_occupied
        FROM allocations
        WHERE room_id = NEW.room_id
        AND status = 'ACTIVE'
        AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        -- Prevent room capacity from being exceeded.
        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room % has reached its capacity',
            NEW.room_id;
        END IF;

        -- Count other active allocations for this student.
        SELECT COUNT(*)::INTEGER
        INTO v_student_count
        FROM allocations
        WHERE student_id = NEW.student_id
        AND status = 'ACTIVE'
        AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        -- A student can only have one active allocation.
        IF v_student_count > 0 THEN
            RAISE EXCEPTION
            'Student % already has an active allocation',
            NEW.student_id;
        END IF;

    END IF;

    RETURN NEW;

END;
$$;


-- Create the BEFORE INSERT OR UPDATE trigger.
CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_allocation();


-- ==========================================================
-- TEST THE ALLOCATION PROCEDURE.
-- Student 4 has no active allocation.
-- Room 102 has available beds.
-- ==========================================================

CALL pr_allocate_room(
    4,
    2,
    CURRENT_DATE
);


-- Display all allocation records.
SELECT * FROM allocations;


-- ==========================================================
-- (e) VIEW
-- Create v_room_occupancy.
-- Displays every room, capacity, occupied beds and free beds.
-- Includes rooms that have no active allocations.
-- ==========================================================

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id)::INTEGER AS occupied_beds,
    r.capacity - COUNT(a.allocation_id)::INTEGER AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON r.room_id = a.room_id
    AND a.status = 'ACTIVE'
GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;


-- Display room occupancy information.
SELECT * FROM v_room_occupancy;


-- ==========================================================
-- (f) INDEX
-- Create a partial index supporting searches for
-- ACTIVE allocations filtered by room_id.
-- ==========================================================

CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';


-- Matching query for the index.
SELECT
    allocation_id,
    student_id,
    room_id,
    allocated_on
FROM allocations
WHERE room_id = 1
AND status = 'ACTIVE';


-- Display the execution plan.
EXPLAIN
SELECT
    allocation_id,
    student_id,
    room_id,
    allocated_on
FROM allocations
WHERE room_id = 1
AND status = 'ACTIVE';


-- Index justification:
-- This partial index stores only ACTIVE allocations.
-- It improves searches for occupied beds in a room
-- without including ENDED allocation records.


-- ==========================================================
-- (g) SCHEDULED JOB
-- Create pr_refresh_occupancy().
-- Stores current occupancy for every room.
-- Uses one row per date and room.
-- Replaces existing snapshot values when rerun.
-- ==========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN

    -- Insert or replace the occupancy snapshot
    -- for every room using the current date.
    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id)::INTEGER,
        r.capacity - COUNT(a.allocation_id)::INTEGER
    FROM rooms r
    LEFT JOIN allocations a
        ON r.room_id = a.room_id
        AND a.status = 'ACTIVE'
    GROUP BY
        r.room_id,
        r.capacity

    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;

END;
$$;


-- Test the occupancy refresh procedure.
CALL pr_refresh_occupancy();


-- Display the occupancy snapshots.
SELECT * FROM occupancy_snapshot;


-- ==========================================================
-- SCHEDULE THE JOB DAILY AT 23:55.
-- Requires pg_cron to be installed and configured.
-- ==========================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-hostel-occupancy',
    '55 23 * * *',
    'CALL pr_refresh_occupancy();'
);


-- ==========================================================
-- END OF QUESTION 5
-- ==========================================================
