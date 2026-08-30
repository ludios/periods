-- Model-output: Claude Fable 5
-- Single-row update on the versioned table: both C triggers plus the
-- OnlyExcludedColumnsChanged() query plus one history INSERT.
\set id random(1, 10000)
UPDATE bench.versioned SET value = value + 1 WHERE id = :id;
