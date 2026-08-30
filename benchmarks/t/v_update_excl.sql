-- Model-output: Claude Fable 5
-- Update touching only the excluded column: write_history() returns right
-- after OnlyExcludedColumnsChanged(), writing no history row.  Isolates the
-- search_path pin + the sol T2 join with no history-INSERT confound.
\set id random(1, 10000)
UPDATE bench.versioned_excl SET counter = counter + 1 WHERE id = :id;
