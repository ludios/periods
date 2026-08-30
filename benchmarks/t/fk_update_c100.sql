-- Model-output: Claude Fable 5
-- Shrink the unreferenced [300,400) parent segment; 100 child rows per key.
-- Keys must match setup: -v keys=200.
\set k random(1, 200)
BEGIN;
UPDATE bench.parent_c100 SET valid_to = 350 WHERE id = :k AND valid_from = 300;
ROLLBACK;
