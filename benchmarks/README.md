# DML hot-path benchmark suite

Model-output: Claude Fable 5

An A/B benchmark comparing the per-row DML cost of two builds of the
`periods` extension — typically `origin/master` (1.2) as side A and a work
branch (7.0.0) as side B.  Only DML paths are measured (INSERT/UPDATE/DELETE
on tables the extension instruments); one-time DDL such as `add_period()` is
deliberately out of scope.

## Scenarios

| scenario            | rows/txn | what it measures |
|---------------------|----------|------------------|
| `plain_insert`      | 1        | control: table with no periods machinery.  A/B must be ~equal or the harness is unfair. |
| `plain_update`      | 1        | control, update path. |
| `v_insert_single`   | 1        | SYSTEM_TIME + versioning: `generated_always_as_row_start_end()` + `write_history()` per row.  Isolates the §3.2 `search_path` pin on the two C triggers (no history INSERT happens on this path). |
| `v_insert_batch1k`  | 1000     | same, amplified; per-row µs = txn latency in ms. |
| `v_update_single`   | 1        | update on a versioned table: pin + `OnlyExcludedColumnsChanged()` + history INSERT (`insert_into_history()`, whose plan cache 1.2 rebuilt and leaked every call — expect 7.0.0 *faster* here). |
| `v_update_batch1k`  | 1000     | same, amplified, rolled back. |
| `v_delete_batch1k`  | 1000     | delete on a versioned table: pin + history INSERT; no `OnlyExcludedColumnsChanged()`. |
| `v_update_excl`     | 1        | update touching only an excluded column: `write_history()` returns right after `OnlyExcludedColumnsChanged()`, isolating that query's added join (sol T2) + the pin, with no history INSERT confound. |
| `fk_delete_c{1,10,100}` | 1    | delete of one parent segment nothing references, with 1/10/100 child rows per key: `validate_foreign_key_old_row()`'s coverage rewrite (§2.2/#27) scales with child count; 1.2 did a single containment probe. |
| `fk_update_c{1,10,100}` | 1    | same via an UPDATE of a period bound. |
| `portion_update`    | 1        | UPDATE through the FOR PORTION OF view splitting a row in three: the §2.3/F3 `jsonb_populate_record()` rework. |

All state-changing transactions either roll back or touch bounded state, and
the driver runs `VACUUM ANALYZE` between iterations, so both sides see the
same bloat trajectory.  The FKs are created with `RESTRICT` actions: with the
default `NO ACTION` the uk triggers are `INITIALLY DEFERRED` and would never
fire inside the rolled-back benchmark transactions.  RESTRICT and NO ACTION
run the same check; only the timing differs.

## Requirements

Two PostgreSQL installs (same server version, ideally the same non-cassert
build copied twice) with the two extension builds installed via
`make PG_CONFIG=<install>/bin/pg_config install`, and one running cluster per
install, both listening on the same unix socket directory with different
ports.  `btree_gist` must be installed in both (the extension requires it).
Benchmark-friendly settings for both clusters:

    fsync = off
    synchronous_commit = off
    full_page_writes = off
    autovacuum = off
    jit = off
    shared_buffers = 512MB
    max_wal_size = 8GB
    checkpoint_timeout = 60min

## Running

    A_BIN=.../pgA/bin  A_PORT=6431  A_LABEL=master \
    B_BIN=.../pgB/bin  B_PORT=6432  B_LABEL=prime  \
    PGHOST=/tmp/pb ITERS=5 \
    ./run.sh /path/to/output-dir

The driver recreates the `bench` database on both sides, runs every scenario
`ITERS` times per side in alternating A/B order (to cancel machine drift),
writes `results.csv`, and prints a median-latency summary via
`summarize.py`.  `TXN_SCALE=5` (percent) gives a quick smoke run.

## Interpreting

- Δ% is the change in median latency of side B relative to side A; positive
  means B is slower.
- `v_update_*`/`v_delete_*` mix three effects: the §3.2 pin (regression), the
  sol T2 join (regression), and the §4.1 plan-cache fix (improvement).  Use
  `v_insert_*` for the pin alone and `v_update_excl` for pin + T2 join.
- The `fk_*` scenarios are the ones expected to scale: 1.2's parent-side
  check was a single (incorrect — #27) probe, 7.0.0 proves coverage for every
  child of the key.
