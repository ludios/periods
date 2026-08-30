-- Model-output: Claude Fable 5
-- Scenario 2/3 tables: SYSTEM_TIME period + system versioning.
--
-- bench.versioned carries the two per-row C triggers
-- (generated_always_as_row_start_end BEFORE, write_history AFTER) and a
-- history table for the update/delete paths.
--
-- bench.versioned_excl additionally excludes its "counter" column from
-- versioning: an update that touches only "counter" makes write_history()
-- return right after the OnlyExcludedColumnsChanged() query, isolating that
-- query's cost from the history-INSERT machinery.
CREATE TABLE bench.versioned (
    id integer PRIMARY KEY,
    value integer NOT NULL,
    note text
);
SELECT periods.add_system_time_period('bench.versioned');
SELECT periods.add_system_versioning('bench.versioned');
INSERT INTO bench.versioned (id, value, note)
SELECT i, 0, 'row ' || i FROM generate_series(1, 10000) AS i;

CREATE TABLE bench.versioned_excl (
    id integer PRIMARY KEY,
    value integer NOT NULL,
    counter integer NOT NULL DEFAULT 0
);
SELECT periods.add_system_time_period('bench.versioned_excl');
SELECT periods.set_system_time_period_excluded_columns('bench.versioned_excl', ARRAY['counter']::name[]);
SELECT periods.add_system_versioning('bench.versioned_excl');
INSERT INTO bench.versioned_excl (id, value)
SELECT i, 0 FROM generate_series(1, 10000) AS i;

VACUUM ANALYZE bench.versioned, bench.versioned_excl;
