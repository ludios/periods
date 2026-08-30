-- Model-output: Claude Fable 5
-- Scenario 1 tables: a temporal parent with a unique key and a child with a
-- temporal foreign key onto it.
--
-- psql variables:
--   :suffix    table-name suffix, e.g. c10  -> bench.parent_c10 / bench.child_c10
--   :keys      number of distinct parent key values
--   :children  child rows per parent key
--
-- Every parent key owns 4 contiguous segments [0,100) .. [300,400).  All
-- child rows live inside [0,300), so deleting or shrinking the [300,400)
-- segment never violates the foreign key: the benchmark measures the cost of
-- proving that per statement.
--
-- The FK uses RESTRICT actions on purpose: NO ACTION makes the uk_update /
-- uk_delete triggers INITIALLY DEFERRED, which would never fire inside the
-- rolled-back benchmark transactions.  The validation function is the same.
--
-- Seeding runs under session_replication_role = replica to skip the deferred
-- per-row child-insert validation; the data is valid by construction.
\set parent bench.parent_:suffix
\set child bench.child_:suffix

CREATE TABLE :parent (
    id integer NOT NULL,
    valid_from integer NOT NULL,
    valid_to integer NOT NULL
);
SELECT periods.add_period(:'parent', 'valid_time', 'valid_from', 'valid_to');
SELECT periods.add_unique_key(:'parent', ARRAY['id']::name[], 'valid_time') AS ukname \gset

CREATE TABLE :child (
    id integer NOT NULL,
    parent_id integer NOT NULL,
    valid_from integer NOT NULL,
    valid_to integer NOT NULL
);
SELECT periods.add_period(:'child', 'valid_time', 'valid_from', 'valid_to');
SELECT periods.add_foreign_key(:'child', ARRAY['parent_id']::name[], 'valid_time', :'ukname',
                               update_action => 'RESTRICT', delete_action => 'RESTRICT');

SET session_replication_role = replica;
INSERT INTO :parent (id, valid_from, valid_to)
SELECT k, s * 100, s * 100 + 100
FROM generate_series(1, :keys) AS k, generate_series(0, 3) AS s;

INSERT INTO :child (id, parent_id, valid_from, valid_to)
SELECT j, k, (j * 37) % 290, (j * 37) % 290 + 10
FROM generate_series(1, :keys) AS k, generate_series(1, :children) AS j;
RESET session_replication_role;

-- The index a sane schema would have for this FK; both the 1.2 probe and the
-- 7.0.0 coverage scan enter the child table through it.
CREATE INDEX ON :child (parent_id, valid_from, valid_to);

VACUUM ANALYZE :parent, :child;
