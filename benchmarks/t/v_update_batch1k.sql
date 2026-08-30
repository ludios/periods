-- Model-output: Claude Fable 5
-- 1000-row update on the versioned table, rolled back.  Exercises the
-- history-INSERT plan cache (rebuilt+leaked per row on 1.2, §4.1).
BEGIN;
UPDATE bench.versioned SET value = value + 1 WHERE id <= 1000;
ROLLBACK;
