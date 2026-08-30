# master vs prime, PostgreSQL 18.6, 2026-08-30

Model-output: Claude Fable 5

- A = `origin/master` b7bc4ea (periods 1.2), B = `prime` b88a2a5 (periods 1.2.4).
- PostgreSQL 18.6, release build (no cassert), one copied install + cluster
  per side; fsync/synchronous_commit/full_page_writes/autovacuum/jit off,
  shared_buffers 512MB.
- 16-CPU NixOS box with unrelated load; servers pinned to CPUs 10,11 and
  12,13, pgbench to CPU 14.  9 iterations per side in alternating order,
  transaction counts 3x the defaults (`TXN_SCALE=300`), medians reported.
- Sanity: `write_history` proconfig is `none` on A and
  `search_path=pg_catalog, pg_temp` on B; deleting a *referenced* parent
  segment errors on B but silently passes on A (bug #27, the very defect the
  §2.2 rewrite fixes); updates touching only an excluded column write no
  history rows on either side.

```
median latency per transaction, master (A) vs prime (B); positive delta = B slower
scenario            rows       A ms       B ms   A us/row   B us/row    delta   noise
-------------------------------------------------------------------------------------
plain_insert           1      0.034      0.034       34.0       34.0    +0.0%    2.9%
plain_update           1      0.046      0.046       46.0       46.0    +0.0%    4.3%
v_insert_single        1      0.060      0.064       60.0       64.0    +6.7%    8.3%
v_insert_batch1k    1000     16.568     17.939       16.6       17.9    +8.3%   12.0%
v_update_single        1      0.154      0.123      154.0      123.0   -20.1%    4.1%
v_update_batch1k    1000     83.445     59.355       83.4       59.4   -28.9%   10.0%
v_delete_batch1k    1000     51.326     20.281       51.3       20.3   -60.5%   12.4%
v_update_excl          1      0.088      0.102       88.0      102.0   +15.9%    9.8%
fk_delete_c1           1      0.273      0.482      273.0      482.0   +76.6%    2.3%
fk_delete_c10          1      0.281      0.560      281.0      560.0   +99.3%    3.2%
fk_delete_c100         1      0.313      1.174      313.0     1174.0  +275.1%   14.4%
fk_update_c1           1      0.328      0.543      328.0      543.0   +65.5%    3.9%
fk_update_c10          1      0.335      0.616      335.0      616.0   +83.9%    4.5%
fk_update_c100         1      0.368      1.235      368.0     1235.0  +235.6%    3.6%
portion_update         1      1.016      1.178     1016.0     1178.0   +15.9%    4.2%
```

## Reading by candidate

1. **Parent-side FK coverage rewrite (§2.2/#27)** — the big one, and it
   scales with children per key: +77%/+99%/+275% for deletes at 1/10/100
   children (+66%/+84%/+236% for period-bound updates).  Marginal cost per
   child row is ~7 µs on 1.2.4 vs ~0.4 µs on 1.2.  Absolute cost stays
   moderate (1.2 ms/statement at 100 children), and 1.2's speed came from
   not actually checking anything (see the #27 sanity probe above).
2. **search_path pin on the C triggers (§3.2)** — inserts, the pure
   two-trigger path: +6.7% single-row, +8.3% batched (+1.3 µs/row over two
   pinned SECURITY DEFINER calls, ~0.7 µs per call).  Barely above noise but
   consistent in both insert scenarios.
3. **OnlyExcludedColumnsChanged join (sol T2)** — `v_update_excl` (pin + the
   joined query, no history write): +15.9%, i.e. +14 µs/row, of which ~1 µs
   is the pin.  The join to `periods.periods` costs ~a dozen µs per updated
   row.
4. **update_portion_of rework (§2.3/F3)** — +15.9% per portion update
   (1.02 → 1.18 ms for a 3-way split).
5. **§4.1 plan-cache fix (improvement)** — dominates real update/delete on
   versioned tables: batch updates -29%, batch deletes -60%, single-row
   updates -20%.  1.2 re-planned and leaked the history INSERT plan on every
   row; 1.2.4 caches it.  This more than pays for candidates 2 and 3 on any
   path that writes history.

Net: on ordinary system-versioned DML, 1.2.4 is *faster* than 1.2 wherever a
history row is written and a few percent slower on pure inserts.  The only
regression that grows with data volume is the parent-side FK check, which is
the price of the check being correct at all; it enters the child table
through the `(fk columns, period columns)` index, so keep one.
