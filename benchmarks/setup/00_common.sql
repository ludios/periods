-- Model-output: Claude Fable 5
-- Common benchmark objects: the extension, the bench schema, and the plain
-- control table.  The control table has no periods machinery at all;
-- identical A/B numbers for it mean the harness itself is fair.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS periods;
CREATE SCHEMA bench;

CREATE TABLE bench.plain (
    id integer PRIMARY KEY,
    value integer NOT NULL,
    note text
);
INSERT INTO bench.plain (id, value, note)
SELECT i, 0, 'row ' || i FROM generate_series(1, 10000) AS i;

-- Insert benchmarks draw ids from sequences well above the seeded range so
-- they never collide with it.
CREATE SEQUENCE bench.plain_id START 20000000;
CREATE SEQUENCE bench.v_id START 20000000;

VACUUM ANALYZE bench.plain;
