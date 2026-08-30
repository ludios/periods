-- Model-output: Claude Fable 5
-- Delete the unreferenced [300,400) parent segment; 10 child rows per key.
-- Keys must match setup: -v keys=200.
\set k random(1, 200)
BEGIN;
DELETE FROM bench.parent_c10 WHERE id = :k AND valid_from = 300;
ROLLBACK;
