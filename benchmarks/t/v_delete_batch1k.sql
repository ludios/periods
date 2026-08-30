-- Model-output: Claude Fable 5
-- 1000-row delete on the versioned table, rolled back: write_history +
-- history INSERT per row, no OnlyExcludedColumnsChanged() on this path.
BEGIN;
DELETE FROM bench.versioned WHERE id <= 1000;
ROLLBACK;
