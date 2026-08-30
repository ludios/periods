# Code review: `periods` PostgreSQL extension

**Reviewer:** Claude (Fable) · **Date:** 2026-08-29
**Scope:** whole extension at HEAD (`b7bc4ea`, version 1.2.3 / SQL 1.2) — `periods.c`, `periods--1.2.sql`, tests.
**Verified against:** PostgreSQL **17.11** and **18.6**, both built from `~/cloned/postgresql` (`REL_17_STABLE` / `REL_18_STABLE`) with `btree_gist`, `--enable-cassert`.

Findings marked **[reproduced]** were demonstrated live against a running server on the version(s) noted. Most
were also independently reproduced by an adversarial multi-agent pass; the headline items were additionally
cross-checked by hand and (for the FK bug) by `codex`.

---

## Status (2026-08-30)

Fixes ship as extension version **1.2.4** (`periods--1.2--1.2.4.sql`; a full install script is
generated at build time). Every fix has a regression test in the new `bugfixes` suite, committed
first with the buggy behavior captured, then flipped by the fix commit. All work verified on
PostgreSQL 17.11 and 18.6.

- **Fixed:** §2.1 (`b8f297f`..`bc2f0c6`), §2.3(b) (`4245542`, `0e32b81`), §4.1 (`5316fff`, `07a62a5`),
  §2.2/#27 (`202d17a`..`3b4fb07`), §5.1 (`233ed73`, `001785f`), §5.2 (`0c3bbba`, `6d4ffa8`),
  §6.1 (`d1346ec`, `cce0a82`), §6.4+§6.5 (`c35ff34`).
- **Found while fixing** (not in the review): same-named FK columns broke the coverage check
  entirely (fixed, `bfe662a`); `drop_period('t','system_time','CASCADE',purge=>true)` with active
  versioning always failed on a double-dropped constraint (fixed, `6d4ffa8`); plpgsql
  `BEGIN/EXCEPTION` cannot be used in the FK triggers (they run as deferred triggers during
  COMMIT, where subtransactions crash cassert builds — discovered by the new tests).
- **Fixed (second pass, after codex credits returned):** §2.3(a) (`894135b`, `55cf391` — PK columns
  are stripped from slices only when a column or domain DEFAULT regenerates them, and period bound
  columns never are) and §2.3(c) (`8df93f6`, `c6fdf71` — slice INSERTs and the central UPDATE go
  through `jsonb_populate_record`, the latter over changed columns only; array lower bounds are
  documented as not preserved).  Every commit batch has a completed codex review.
- **Security (§3), third pass:**
  - **§3.1 fixed** (`115026f`, `93d9c92`): the SQL injection through period column names in
    `add_system_versioning` is closed — the generated helper-function bodies are built with an inner
    `format()` and embedded via `%L`. The end-to-end escalation (unprivileged role → superuser) was
    reproduced first and no longer fires. Codex reviewed plan and commit; no findings.
  - **§3.2 not fixed — larger redesign required.** The proposed blanket `SET search_path =
    pg_catalog, pg_temp` on the 19 SECURITY DEFINER functions was verified to *regress real
    functionality*: under a pinned path `add_unique_key`/`add_foreign_key` fail for user-defined
    range types (the range constructor renders as a broken single identifier `"public.intrange"`),
    `health_checks`/`acl` behavior changes, and every regclass in a message becomes schema-qualified
    — 8 regression tests break on both PG 17 and 18. A correct fix needs either full
    `pg_catalog.`/`OPERATOR(pg_catalog.…)` qualification of every built-in call across all 19
    functions (operators included) plus fixing the latent `%I`-on-regtype emission bugs, or a
    privilege-separated design where user-type operations run as the invoker. Too invasive to land
    confidently here. Both the empirical breakage and this conclusion were confirmed by codex.
  - **§3.3 not fixed — larger authorization redesign required.** The review's suggested predicate
    `pg_has_role(current_user, relowner, 'USAGE')` is *wrong*: inside SECURITY DEFINER
    `current_user` is the superuser definer, so it never rejects (verified). `session_user` is the
    only non-masked identity and blocks the basic attack, but a codex call-path audit surfaced that a
    correct, complete fix must also: choose an ownership-identity policy (session_user ignores
    `SET ROLE`; exact semantics need `GetOuterUserId()` via C); split `drop_foreign_key` into a
    PUBLIC owner-checked entry and a REVOKE'd internal cascade worker; restructure or reject the
    NULL/bulk mode of `add_for_portion_view`/`drop_for_portion_view` (the bulk path is currently
    unreachable anyway — `LOCK TABLE NULL`); stop `add_system_versioning` from adopting and
    reassigning an existing history table owned by someone else (takeover); enforce REFERENCES on the
    parent in `add_foreign_key` (it installs triggers on the referenced table); check `CREATE` on the
    schema for created sibling objects; and lock the table before the ownership check (TOCTOU).
    Moreover, while §3.2 is open this guard does **not** remove the escalation path for a legitimate
    table owner (own a table → pass the guard → hijack the unpinned search_path). Deferred as a
    dedicated security-hardening effort rather than shipped partially.
- **Support change (user decision):** PostgreSQL 9.5/9.6 dropped (`cebff70`) instead of shipping a
  generated full 1.2.4 install script; fresh installs use the PG10+ chained-script capability.
  This also mooted the request for a fabricated pre-10 `bugfixes` expected-output variant.
- **Deliberately left as design decisions:** §5.3 (TRUNCATE-wipes-history is by design; document loudly
  or block — upstream's call), §6.2 (ADD COLUMN vs history divergence), §6.3 (PG18 leftover named
  NOT NULL constraints on purge; benign).

---

## 1. PostgreSQL 18 status — the good news first

**All 15 regression tests pass on both PostgreSQL 17.11 and 18.6 with the current tree**, matching each test to its
existing expected-output variant (`acl` matches `acl_3.out` on both).

**Issue [#39](https://github.com/xocolatl/periods/issues/39) is already resolved at HEAD.** That report was filed
against **v1.2.2**. Its attached log is *entirely* the `acl` test, and every diff line is the new **`MAINTAIN`**
privilege that PostgreSQL 17 added to `information_schema` ACL listings. HEAD already ships `expected/acl_3.out`
(added in `1f615c2`, "Add expected output file for PG 17") which includes the `MAINTAIN` rows, so both 17 and 18
now match. There is **no source change needed for PG18 to pass the suite** — the extension compiles clean (only a
pre-existing signed/unsigned nit, §6.4) and the tests are green.

The one genuine PG18 *behavioral* change I found is benign and is §6.3.

**However** — the passing suite hides a number of real defects, because the tests exercise only narrow, favorable
table shapes. The rest of this document is those defects. None of them are PG18 regressions; most affect 17 too.

---

## 2. Critical — silent data corruption

### 2.1 `drop_period` deletes the wrong catalog row and silently disables SYSTEM VERSIONING **[reproduced: 17 & 18]**

`periods.drop_period()` tears down `system_time` triggers with a `DELETE` that filters on **`table_name` only**, not
on `period_name` ([periods--1.2.sql:545](periods--1.2.sql#L545)):

```sql
DELETE FROM periods.system_time_periods AS stp
WHERE stp.table_name = table_name          -- ← missing:  AND stp.period_name = period_name
RETURNING stp.* INTO system_time_period_row;
IF FOUND AND NOT is_dropped THEN
    -- drops infinity_check_constraint + generated_always/write_history/truncate triggers
```

A table may legitimately have **both** an application-time period (e.g. `validity`) **and** `system_time` with system
versioning. Calling `drop_period(t, 'validity')` matches the lone `system_time_periods` row (there is at most one per
table) and destroys the versioning machinery, while leaving the `periods.periods (system_time)` and
`periods.system_versioning` rows behind. The table then *claims* to be system-versioned but silently stops writing
history. `drop_protection` doesn't catch it because the catalog row is deleted before the triggers are.

Reproduction (PG18, isolated DB):

```sql
CREATE TABLE dpx (id int, val text, s date, e date, vs date, ve date, PRIMARY KEY (id));
SELECT periods.add_period('dpx','validity','vs','ve');
SELECT periods.add_system_time_period('dpx','s','e');
SELECT periods.add_system_versioning('dpx');
SELECT periods.drop_period('dpx','validity','CASCADE');   -- drop ONLY the app-time period
-- periods.system_versioning still lists dpx  ✗
-- periods.system_time_periods now has 0 rows for dpx  ✗
-- all 3 sysver triggers on dpx are gone  ✗
INSERT INTO dpx(id,val,vs,ve) VALUES (1,'a','2000-01-01','2010-01-01');
UPDATE dpx SET val='b' WHERE id=1;
SELECT count(*) FROM dpx_history;    -- 0  ✗  history silently not written
```

**Fix:** add `AND stp.period_name = period_name` to the `DELETE` (the *existence* check at line 574 is already keyed
correctly on `(table_name, period_name)`; only the `DELETE` is wrong). Since `system_time_periods` has
`CHECK (period_name = 'system_time')`, the filter also makes the intent explicit.

---

### 2.2 Temporal foreign keys do not prevent orphaning a *contained* child — parent DELETE/UPDATE **[reproduced: 17 & 18]**

This is [issue #27](https://github.com/xocolatl/periods/issues/27), still open, still unfixed. The check that runs
when a **parent (unique-key) row** is deleted or updated — `periods.validate_foreign_key_old_row`
([periods--1.2.sql:2116](periods--1.2.sql#L2116), used via `uk_delete_check`/`uk_update_check`) — looks for a child
whose period **fully contains** the removed parent period:

```sql
--   AND t.<fk_start> <= <deleted_parent_start>
--   AND t.<fk_end>   >= <deleted_parent_end>
```

So a child whose validity is a **strict subset** of the parent's — the overwhelmingly common case — is never
detected, and the delete/update silently orphans it.

```sql
-- parent covers [2000,2010); child references [2003,2004)  (strict subset)
DELETE FROM parent WHERE id = 1;   -- succeeds, leaving 0 parents + 1 orphaned child   ✗
```

PostgreSQL 18's **native** temporal FK correctly *blocks* the identical scenario
(`ERROR: update or delete on table "..." violates foreign key constraint ...`). The extension does not. The
UPDATE-shrink variant (`UPDATE parent SET s = '2005-01-01'`) orphans an interior child the same way.

The flaw is that the predicate tests *containment* instead of *coverage*. The correct semantics for `NO ACTION` /
`RESTRICT` is: for every child that **overlaps** the changed parent period, re-verify the child is *still fully
covered by the remaining parent rows* (which is exactly what `validate_foreign_key_new_row` already does for the
child side). A one-line predicate swap to overlap (`fk_start < uk_end AND fk_end > uk_start`) would catch the missed
cases but would over-reject when redundant parent coverage remains, so the real fix routes overlapping children
through the full-coverage check.

Both permitted actions (`NO ACTION`, `RESTRICT`) are affected. (`CASCADE`/`SET NULL`/`SET DEFAULT` are correctly
rejected by a `CHECK` on `periods.foreign_keys` — that part is fine.)

---

### 2.3 `FOR PORTION OF` is broken three independent ways

The `for_portion_of` test only ever uses tables whose PK is **auto-generated** (`serial` / `IDENTITY` /
`DEFAULT nextval`) and **excludes** the period columns, has **no nullable constrained columns**, and has **no array
columns**. Step outside that and `update_portion_of` ([periods--1.2.sql:1201](periods--1.2.sql#L1201)) fails. Three
distinct, verified bugs:

**(a) NULL primary key on any non-auto-generated PK. [reproduced: 18]**
The "generated columns" removal ([1264-1279](periods--1.2.sql#L1264)) strips **all primary-key columns** from the
re-inserted pre/post slices, assuming they regenerate. For a plain `id int` PK — or the standard temporal PK
`PRIMARY KEY (id, start, end)` — nothing regenerates them:

```sql
CREATE TABLE fb (id int, val text, s date, e date, PRIMARY KEY (id, s, e));
-- ... add_period + add_for_portion_view ...
UPDATE fb__for_portion_of_validity SET val='changed', s='2003-01-01', e='2006-01-01' WHERE id=1;
-- ERROR: null value in column "id" ... INSERT INTO fb (val) VALUES ('orig')   ✗
```

**(b) The "match by PK" WHERE clause matches on *every* constraint, so a NULL column silently voids the edit. [reproduced: 17 & 18]**
The `WHERE` that should re-find the row by primary key ([1401-1407](periods--1.2.sql#L1401)) joins `pg_constraint`
with `c.conkey @> ARRAY[a.attnum]` but **no `c.contype = 'p'` filter** — so it pulls in columns from CHECK, FK,
UNIQUE, the GiST exclusion constraint, and (on PG18) every NOT-NULL constraint. If any such column is NULL in the old
row, the predicate becomes `col = NULL` → false → the central `UPDATE` matches **zero** rows, yet the pre/post slice
`INSERT`s still run. Result: the original wide row is left intact, two overlapping slices are added, the intended
edit vanishes — and the command still reports `UPDATE 1`.

```sql
-- table with a nullable column under a CHECK, value NULL
UPDATE t__for_portion_of_p SET val=999, s=20, e=30;
-- expected: [10,20)=100, [20,30)=999, [30,40)=100
-- actual:   [10,20)=100, ORIGINAL [10,40)=100 (unchanged!), [30,40)=100   ✗ overlap + lost edit
```

PG18 makes the blast radius larger (NOT NULL constraints now live in `pg_constraint` as `contype='n'`, adding more
duplicated predicates), though the failure itself reproduces on 17 too. **Fix:** add `AND c.contype = 'p'`.

**(c) Array / composite / range columns abort the update. [reproduced: 17 & 18]**
Slices are rebuilt via `row_to_json(OLD/NEW)` → `jsonb_each_text` → `%L`. A Postgres array `{1,2,3}` becomes JSON
`[1,2,3]`, which is *not* a valid array input literal:

```sql
-- table with tags int[]
UPDATE t__for_portion_of_p SET val=999, s=20, e=30;
-- ERROR: malformed array literal: "[1, 2, 3]"   ✗   (even though tags wasn't the changed column)
```

Any table carrying an array (or composite/range) column cannot use `FOR PORTION OF` at all. The JSON round-trip also
loses fidelity for other types whose JSON form differs from their input literal.

---

## 3. Critical — security (privilege escalation)

These require the extension to be installed by a superuser (the default `CREATE EXTENSION periods`) and its
functions to be callable by unprivileged roles — which they are, because nothing `REVOKE`s `EXECUTE` from `PUBLIC`.

### 3.1 SQL injection via unvalidated period column names → arbitrary code as the definer **[reproduced: 18]** — FIXED (`93d9c92`, via `%L`-wrapped bodies)

`add_system_time_period` accepts arbitrary start/end **column names** without validation (unlike the period *name*,
which is regex-checked at [line 298](periods--1.2.sql#L298)). `add_system_versioning`
([2554-2596](periods--1.2.sql#L2554)) then interpolates those names with `%I` **inside a single-quoted function-body
literal**:

```sql
EXECUTE format($$ CREATE FUNCTION %1$I.%2$I(...) ... AS
    'SELECT * FROM %1$I.%3$I WHERE %4$I <= $1 AND %5$I > $1' $$,
    ..., period_row.start_column_name, period_row.end_column_name);
```

`quote_ident` escapes double quotes but **not the single quotes** that matter for the surrounding body literal, so a
column named `a'; ALTER ROLE me SUPERUSER; --` closes the literal early and the rest runs as separate statements —
executed by the `SECURITY DEFINER` (superuser) owner. Verified end-to-end: an unprivileged role went
`rolsuper = f → t`.

**Fix:** validate period column names (reject quotes) *and* stop building function bodies by literal interpolation —
use dollar-quoting with a parameter or `format('%L', ...)` for the literal context; `%I` alone is not sufficient
inside a string literal.

### 3.2 `SECURITY DEFINER` functions have no `SET search_path` → function/operator hijack **[reproduced: 18]** — NOT FIXED (blanket pin regresses user-defined types; needs full qualification or privilege separation — see Status)

None of the 19 `SECURITY DEFINER` functions pin `search_path`, and they call many unqualified functions/operators
(`lower()` at [297](periods--1.2.sql#L297), `format`, `left`, `octet_length`, `string_agg`, `||`, casts, …). A caller
who prepends their own schema to `search_path` and defines e.g. `lower(name)` running `ALTER ROLE me SUPERUSER` gets
it executed as the superuser owner (the classic CVE-2018-1058 shape). Verified live: role went to superuser.

**Fix:** add `SET search_path = pg_catalog, pg_temp` (or `= ''` with fully-qualified references) to every
`SECURITY DEFINER` function.

### 3.3 DDL functions are `PUBLIC`-executable with no ownership check **[reproduced: 18]** — NOT FIXED (review's `current_user` predicate is wrong inside SECURITY DEFINER; correct fix is a multi-part authorization redesign — see Status)

`add_period`, `add_system_time_period`, `add_system_versioning` (and siblings) never verify the caller owns
`table_name`, and `EXECUTE` is never revoked from `PUBLIC`. A low-privileged user can therefore add
constraints / `SET NOT NULL` / create triggers on tables they don't own, running as the definer. This is also the
delivery vector that makes §3.1/§3.2 reachable.

**Fix:** add an explicit ownership guard at the top of each mutating function (e.g. `pg_has_role(current_user,
relowner, 'USAGE')`) and/or `REVOKE EXECUTE ... FROM PUBLIC`.

> **Correction (third pass):** `current_user` is the *wrong* identity here — inside a `SECURITY DEFINER`
> function it is the superuser definer, so `pg_has_role(current_user, relowner, 'USAGE')` is always true
> and never rejects (verified on PG 18). Use `session_user` (unmasked by SECURITY DEFINER). A complete
> fix also has to handle: the identity policy (`session_user` ignores `SET ROLE`), the internal
> `drop_unique_key → drop_foreign_key(NULL, key)` cascade (split a PUBLIC entry from a REVOKE'd worker),
> the unreachable/bulk NULL-table paths, the existing-history-table takeover in `add_system_versioning`,
> REFERENCES enforcement on the parent in `add_foreign_key`, schema `CREATE` checks, and TOCTOU locking
> around the ownership check. It is a multi-part redesign, deferred — see the Status section at the top.

---

## 4. High — the C code

### 4.1 Inverted plan-cache condition in `insert_into_history()` → per-write plan leak + stale plan on rename **[reproduced: 18]**

[periods.c:545-547](periods.c#L545):

```c
/* If we didn't find it or the name changed, re-plan it */
if (!found ||
    !strcmp(hentry->schemaname, schemaname) ||    // !strcmp is TRUE when EQUAL — inverted
    !strcmp(hentry->tablename, tablename))
```

`strcmp` returns 0 (false) when strings are **equal**, so `!strcmp(...)` is true when the names **match** — the
opposite of the comment. Two consequences:

- **Common path (names unchanged):** every history-writing `UPDATE`/`DELETE` re-enters the branch, calls
  `SPI_prepare` + `SPI_keepplan`, and overwrites `hentry->qplan` **without `SPI_freeplan`-ing the previous kept
  plan** — which lives in a session-lifetime context. An unbounded per-backend leak, and the cache is entirely
  defeated. Measured: 5000 separate committed updates of one versioned row grew `SPI Plan` contexts from ~0 to
  ~46 MB in a single backend.
- **Rename path (both schema *and* table changed):** all three clauses are false → the stale plan runs, whose SQL
  hard-codes the *old* qualified name → `ERROR: relation "old.name" does not exist` (or, if some other relation now
  occupies that name, history rows land in the **wrong table**). Reachable because periods doesn't otherwise block
  renaming/moving a history table.

The `!found` (fresh-entry) case is safe — short-circuit initializes the buffers before they're read.

**Fix:**
```c
if (!found ||
    strcmp(hentry->schemaname, schemaname) != 0 ||
    strcmp(hentry->tablename, tablename) != 0)
{
    ...
    if (found && hentry->qplan != NULL)
        SPI_freeplan(hentry->qplan);   /* avoid leaking on a genuine re-plan */
    ...
}
```
(*Note:* the leak only shows across **separate committed** transactions — repeated updates inside one transaction
don't re-write history, so a `DO` loop won't reproduce it.)

---

## 5. Medium

### 5.1 `health_checks` doesn't re-enforce NOT NULL on period bounds **[reproduced: 17]**
`add_period` does `SET NOT NULL` on the bound columns and the FK/exclusion logic relies on it
([comment at 2311](periods--1.2.sql#L2311): "Period columns are by definition NOT NULL"). But `health_checks`
re-validates persistence, function existence, and ownership — **not** NOT-NULL. `ALTER TABLE t ALTER COLUMN s DROP
NOT NULL` slips through, then a NULL bound is accepted and the exclusion constraint turns it into an *unbounded*
range with no error, violating the invariant the rest of the code assumes.
**Fix:** in `health_checks`, raise if any period bound column has `attnotnull = false`.

### 5.2 `bounds_check_constraint` is unprotected by `drop_protection`; `purge` then fails **[reproduced: 17]**
`drop_protection` guards a `system_time` period's `infinity_check_constraint` but not any period's
`bounds_check_constraint` (the `CHECK (start < end)`). A user can `ALTER TABLE ... DROP CONSTRAINT <bounds_check>`
directly; later `drop_period(..., purge => true)` issues an unconditional `DROP CONSTRAINT` and aborts with
`constraint "..." does not exist`.
**Fix:** protect the bounds constraint in `drop_protection` (mirror the infinity check), and/or make the purge use
`DROP CONSTRAINT IF EXISTS`.

### 5.3 `TRUNCATE` on a versioned table wipes history — data-loss path around "immutable" history **[reproduced: 18]**
`truncate_system_versioning` ([1062](periods--1.2.sql#L1062)) `TRUNCATE`s the history table when the main table is
truncated. This is by design, but it means the audit trail — sold as read-only/immutable — is destroyed by a single
`TRUNCATE` (owner/`TRUNCATE` privilege only), with no way to opt out. Worth documenting loudly, and arguably worth
blocking while versioning is active (require `drop_system_versioning` first, like the DELETE path).

---

## 6. Low / nits

### 6.1 `truncate_system_versioning` casts `regclass` → `name`, truncating long qualified names
[1071](periods--1.2.sql#L1071)/[1079](periods--1.2.sql#L1079): `history_table_name` is declared `name` but the
catalog column is `regclass`; the `regclass→name` conversion truncates at 63 bytes, so a history table whose quoted
schema-qualified form exceeds 63 bytes yields a garbled `TRUNCATE <name>` (error, or worst-case a different
relation). Not injectable. **Fix:** declare it `regclass` and interpolate with `%s`, as other functions do.

### 6.2 `ALTER TABLE ... ADD COLUMN` on a versioned table silently produces incomplete history **[reproduced: 18]**
Adding a column to a versioned table isn't blocked (`DROP`/`ALTER TYPE` are, via view dependency), and the history
table doesn't get the column. Subsequent history writes silently omit the new column's values (the C
`convert_tuples_by_name` matches by name and drops the extra) rather than erroring. Partly covered by the README's
"other changes will be prevented in the future," but a real gotcha for audit use.

### 6.3 PG18: named NOT-NULL constraints from `add_period` are left behind on purge
On PG18 `SET NOT NULL` materializes a catalogued `<table>_<col>_not_null` constraint (on PG17 it was only the
`attnotnull` flag). `add_period`/`add_system_time_period` create these but never track them, and `drop_period` purges
only the bounds-check constraint — so purge leaves them behind on 18 but not 17. Benign (no integrity failure), but a
cross-version inconsistency worth a decision. This is the only genuine PG18-behavioral difference I found.

### 6.4 Signed/unsigned loop counter
[periods.c:212](periods.c#L212): `for (int i = 0; i < SPI_processed; …)` compares `int` against `uint64`
(`SPI_processed`). Cosmetic (`-Wsign-compare`); unreachable in practice. Use a `uint64` index.

### 6.5 `SPI_getbinval` NULL flags ignored (defensive)
[periods.c:145-149](periods.c#L145), 356, 659-660, 688 pass `&is_null` but never test it, then dereference the datum
as a `Name`/`Oid`. Safe today because the sources are NOT-NULL catalog/period columns, but a defensive `is_null`
check (or `elog`) would harden against future catalog changes.

---

## 7. Verified *correct* (no action needed)

- **Predicates** (`contains`/`overlaps`/`precedes`/… [3626-3697](periods--1.2.sql#L3626)) — all correct for
  half-open `[start,end)`; NULL propagates as NULL per spec. Checked by reading and live.
- **Temporal query bounds** (`t__as_of` / `t__from_to` / `t__between` / `t__between_symmetric`) — inclusive/exclusive
  bounds correct.
- **FK coverage on the child side** (insert / child-update, contiguous coverage across adjacent parent rows, gap
  rejection) — correct on 18.
- **`drop_protection`** blocks dropping the history table, the period, and the versioned table directly; **FK action
  `CHECK`** correctly rejects unimplemented `CASCADE`/`SET NULL`/`SET DEFAULT`.
- **All `PG_VERSION_NUM` / `server_version_num` branches** — the newest branch is correct for PG18 (180000).

---

## 8. Suggested priority

1. **§2.1 `drop_period` wrong-row** and **§2.2 FK orphan (#27)** — silent integrity loss on core features; smallest,
   highest-value fixes (one predicate each, roughly).
2. **§2.3 FOR PORTION OF (b) `contype='p'`** — one-line fix, prevents silent data corruption.
3. **§3.1 SQL injection** / **§3.3 ownership+`PUBLIC`** / **§3.2 `search_path`** — the security trio; fix together.
4. **§4.1 C plan-cache** — small C fix, stops a real leak.
5. **§2.3 (a)/(c)** and **§5.x** — larger design work on `update_portion_of` and the event-trigger invariants.

**Note on tests:** every bug above is invisible to the current suite. Worth adding regression cases for: a plain /
composite-including-period PK with `FOR PORTION OF`; a nullable constrained column with `FOR PORTION OF`; an array
column; a parent delete/update against a strict-subset child; `drop_period` of an app-time period on a
system-versioned table; and a hostile column name through `add_system_versioning`.
