-- Model-output: Claude Fable 5
-- 1000-row insert into the versioned table, rolled back so the table stays at
-- its seeded size.  Per-row µs equals the reported txn latency in ms.
BEGIN;
INSERT INTO bench.versioned (id, value, note)
SELECT i, 0, 'x' FROM generate_series(10000001, 10001000) AS i;
ROLLBACK;
