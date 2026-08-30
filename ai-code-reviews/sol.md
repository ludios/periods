Yes — I finished the source review far enough to give you a substantive audit. The short version is: **I would not deploy the current `periods` unchanged on PostgreSQL 18.** Surprisingly, the biggest reasons are not PostgreSQL-18 C API changes. I found several serious privilege-boundary and temporal-integrity problems that also affect PostgreSQL 17.

I reviewed the supplied `periods` tree at `b7bc4eac98d583afe474aade534da9478f94d13b`, compared its C API use with your REL_17_STABLE, REL_18_STABLE, and master trees, inspected its SQL/event-trigger implementation and regression tests, and cross-checked the open issues. Your saved issue snapshot was captured August 29, 2026.  I also opened a few current upstream issue bodies where the saved listing did not contain the reproduction details.

One limitation: I could not run a clean 17/18 source-build/regression matrix in this environment because the supplied PostgreSQL git trees require generated parser files and the necessary bison/flex installation was unavailable. So below I distinguish source-proven bugs from things I consider risks. Upstream #39 independently reports that v1.2.2 **compiles on PG18 but fails regression tests**, which is consistent with what I found: I see no obvious removed C API, but plenty of behavior-sensitive SQL. ([github.com][1])

# Status of this review's findings (2026-08-30)

The "relatively easy" items were fixed on top of extension version **1.2.4**
(`periods--1.2--1.2.4.sql`), each with a capture-first regression test in the
`bugfixes` suite, a codex-reviewed plan, and verification on PostgreSQL 17.11
and 18.6.  Items this review shares with claude.md that were already fixed in
the earlier passes: T1/#27 (§2.2), C1+C2 (§4.1), F2/F4/F5 (§2.3), H6 (§6.1).
H7 stays a documented design decision (§5.3).

- **T3 fixed** (`ae53023`, `b81cbc7`): the unique-key collision check in
  `add_system_time_period()` is scoped to the table; a same-named column in
  another table's temporal unique key no longer blocks it.
- **T2 fixed** (`78b1df9`, `4a57f27`, `97c2ecf`): the period's own bound
  columns are rejected in `excluded_column_names` by both SQL entry points,
  and the C triggers additionally ignore such catalog rows (legacy rows,
  dump/restore), closing the row-start forgery / missing-history hole.
- **D2 / issue #14 fixed** (`dd6b830`, `e85a58a`, `bf89251`): all ten
  `%I`-on-regrole sites in `add_system_versioning()` and `health_checks()`
  now render owners with `%s`.  Found alongside it, not in this review: the
  grant-propagation loop rendered PUBLIC (grantee OID 0) as `-`, so a base
  table with `GRANT SELECT TO PUBLIC` could not get versioning at all.
- **D6 fixed** (`8b3edaa`, `d8b8efb`): adopting a pre-existing history
  relation requires relkind 'r', with a precise error.  No working
  configuration is lost: every other relkind already failed later behind
  misleading errors (a partitioned or materialized-view history dies at
  generated 'REVOKE ALL ON ERROR ...' SQL), so the code comment's
  partitioned-history aspiration was never reachable.
- **D5 fixed** (`8ffd32e`): `health_checks()` names the history table (not
  the base table) in its persistence error, with the correct reason; the
  existing health_checks test had the wrong name baked into its expected
  output, which flips with the fix.
- **T5+T6+§9 cardinality fixed** (`04d4f4b`, `ed3fc0c`): `add_foreign_key()`
  rejects MATCH PARTIAL, unsupported and NULL actions, a NULL match type,
  and empty/mismatched column lists up front (`cardinality()`, so
  multidimensional arrays are measured the way the machinery's `unnest()`
  flattens them).  The §1839 message complaint turned out to be a duplicated
  check shadowing a correctly-worded one; the duplicate is removed.
- **H2 fixed** (`19fb4ec`, `2a096bc`): `add_period(..., 'system_time')`
  forwards `bounds_check_constraint` and rejects a supplied `range_type`
  (which may not be tstzrange — SYSTEM_TIME columns can be date or plain
  timestamp, mapping to daterange/tsrange).
- **F3 fixed, with corrections** (`4798d43`, `bb12747`): the claim is wrong
  for the types it names — date/timestamp/timestamptz endpoints survive
  because PostgreSQL's datetime parsers skip double quotes (verified).  The
  real exposure is subtypes with strict parsers (e.g. a range over uuid),
  failing in the endpoint tests AND in a third interpolation site this
  review missed: the central UPDATE's row filter.  All three sites now
  unwrap the jsonb scalar with `#>> '{}'`, and NULL bounds get a real error.
  A jsonb subtype keeps its native JSON rendering (batch-review finding: its
  JSON strings must stay quoted), restoring the sequence-backed-PK case that
  worked before 1.2.4; a JSON-null bound is cleanly rejected because
  jsonb_populate_record() cannot represent a jsonb null in the slices (JSON
  null in a record is SQL NULL) — full JSON-null support, like container
  subtypes (arrays, hstore), needs the typed `EXECUTE ... USING` rewrite
  this review itself defers (F2).

Not addressed here, deliberately (larger redesigns or out of "easy" scope,
matching the claude.md deferrals): S1/S2/S3 (§3.2/§3.3), T4, T7, C3, C4,
F1, F6, R1–R4, H1, H3, H4, H5, D1/#22, D3, D4, and the §9 leftovers not
listed above.

# Bottom line for PostgreSQL 18

At the C-source level, I found no obvious PG17→PG18 showstopper among the APIs `periods.c` directly uses. Things such as `table_open`, `convert_tuples_by_name`, `execute_attr_map_tuple`, `heap_modify_tuple_by_cols`, SPI, and the trigger interfaces it relies on are still available in the supplied PG18/master sources.

The final repository commit named “Upload for PostgreSQL 18” changes **Debian packaging only**, not `periods.c` or `periods--1.2.sql`. The workflow does list PG18, but there is no PG18-specific extension implementation change. The README is also stale and still says `compatible 9.5–15` (`README.md:6`).

More importantly, PostgreSQL 18 now natively implements application-time temporal `UNIQUE`/`PRIMARY KEY ... WITHOUT OVERLAPS` and temporal `FOREIGN KEY (..., PERIOD range)` constraints. ([PostgreSQL][2]) That overlaps a substantial and particularly buggy part of `periods`. Core PG18 requires a range/multirange column, whereas `periods` models a period using separate start/end columns, so migration isn't syntactically drop-in. But for a new PG18 design I would strongly prefer core constraints for **application time**, while retaining custom code only where PostgreSQL still lacks the equivalent SYSTEM_TIME/history functionality.

---

# 1. Security problems

| Severity     | Finding                                                                             | Status                          |
| ------------ | ----------------------------------------------------------------------------------- | ------------------------------- |
| **CRITICAL** | Public `SECURITY DEFINER` administrative API has no table-owner authorization check | Source-confirmed                |
| **CRITICAL** | Unsafe `search_path` in `SECURITY DEFINER` functions/event triggers                 | Source-confirmed unsafe pattern |
| **MEDIUM**   | “Private” helpers remain publicly executable, including advisory-lock helper        | Source-confirmed                |
| **MEDIUM**   | Security model is tightly coupled to extension owner, normally a superuser          | Architectural                   |

## S1. Any ordinary database user can apparently perform privileged temporal DDL on somebody else's table

This is the most serious thing I found.

The extension explicitly grants:

```sql
GRANT USAGE ON SCHEMA periods TO PUBLIC;
```

and almost all of its management operations are `SECURITY DEFINER`, including:

`add_period`, `drop_period`, `add_system_time_period`, `set_system_time_period_excluded_columns`, `drop_system_time_period`, `add_for_portion_view`, `drop_for_portion_view`, `add_unique_key`, `drop_unique_key`, `add_foreign_key`, `drop_foreign_key`, `add_system_versioning`, and `drop_system_versioning`.

See, for example, `periods--1.2.sql:246-255`, `633-645`, `1426-1435`, `1777-1792`, and `2363-2373`.

There is **no** corresponding:

```sql
REVOKE EXECUTE ... FROM PUBLIC
```

anywhere in the extension SQL, and I found no check equivalent to:

```sql
pg_has_role(session_user, table_owner, 'USAGE')
```

or a PostgreSQL internal table-owner check before the function executes `ALTER TABLE`, creates triggers, constraints, views, etc.

PostgreSQL grants `EXECUTE` on functions to `PUBLIC` by default, and its own documentation specifically warns that `SECURITY DEFINER` functions normally need that revoked and selectively re-granted. ([PostgreSQL][3])

So, by source inspection, an ordinary role that can resolve a victim table can apparently do something conceptually like:

```sql
SET ROLE ordinary_user;

SELECT periods.add_period(
    'public.somebody_elses_table',
    'validity',
    'valid_from',
    'valid_to'
);
```

The DDL then executes as the extension-function owner rather than `ordinary_user`.

This isn't an accidental use of `SECURITY DEFINER`: the changelog says v1.2 deliberately changed **all functions** to `SECURITY DEFINER` (`CHANGELOG.md:28`), and tests invoke the API as an unprivileged role. The missing part is authorization of the *target object*.

**Fix:** distinguish public predicates/trigger entry points from administrative DDL. For every management function, verify that `session_user` owns the target relation or is a member of its owning role before doing anything. Separately revoke `PUBLIC EXECUTE` on internal functions and selectively grant only intended public APIs.

I would treat this as a release-blocking security defect.

## S2. The `SECURITY DEFINER` functions do not establish a safe `search_path`

The extension has 19 `SECURITY DEFINER` declarations in the current SQL and essentially none use a function-level:

```sql
SET search_path = pg_catalog, periods, pg_temp
```

Many then call unqualified functions or query unqualified catalog names.

`health_checks()` is particularly concerning because it is a `SECURITY DEFINER` **event trigger** and executes automatically at every `ddl_command_end` (`periods--1.2.sql:3309-3312,3622`).

It temporarily changes `search_path` at 3344-3358 for one block, then restores the caller's path and proceeds to use unqualified names such as:

```sql
format(...)
pg_class
pg_proc
aclexplode(...)
acldefault(...)
has_table_privilege(...)
has_function_privilege(...)
```

through approximately lines 3360-3618.

PostgreSQL explicitly warns that writable schemas must be excluded from the `search_path` of `SECURITY DEFINER` functions because attackers can mask functions, operators, tables, etc. ([PostgreSQL][4])

I did not execute a privilege-escalation proof-of-concept, so I'm not claiming a demonstrated superuser takeover here. But **this is exactly the construction PostgreSQL documents as unsafe**, and because the extension is normally installed by a superuser and the event trigger is invoked automatically, I would treat it as critical until fixed.

## S3. Supposedly private helpers are callable by everyone

The comment at `periods--1.2.sql:158-162` says functions beginning with `_` are private and “should not be called by outsiders”. Privileges don't implement that promise.

For example:

```sql
periods._serialize(regclass)
```

is public by default. An ordinary user can acquire one of the extension's advisory transaction locks and deliberately keep the transaction open, blocking management operations on that relation.

The same general privilege mistake applies to trigger/helper functions. Some trigger functions reject direct calls, which limits direct misuse, but they should not be exposed just because PostgreSQL's default happens to grant `EXECUTE`.

---

# 2. Temporal-integrity bugs

These worry me more than the PG18 port itself.

| Severity     | Finding                                                                                   | Status               |
| ------------ | ----------------------------------------------------------------------------------------- | -------------------- |
| **CRITICAL** | Referenced-side temporal FK check uses the wrong interval predicate                       | Confirmed + open #27 |
| **HIGH**     | SYSTEM_TIME boundary columns can be put in the excluded-columns set                       | Source-confirmed     |
| **HIGH**     | Adding SYSTEM_TIME can be rejected because of a unique key on an entirely different table | Source-confirmed     |
| **HIGH**     | Existing-data temporal-FK validation mishandles NULL/MATCH semantics                      | Source-confirmed     |
| **MEDIUM**   | `MATCH PARTIAL` is accepted by DDL but explicitly unimplemented                           | Source-confirmed     |
| **MEDIUM**   | Unsupported FK referential actions are exposed by the public enum/API                     | Source-confirmed     |
| **MEDIUM**   | RESTRICT update checking can reject no-op/equivalent updates                              | High-confidence      |
| **MEDIUM**   | Custom history-table validation is much weaker than what `write_history()` requires       | Source-confirmed     |

## T1. Temporal foreign keys can become inconsistent after referenced DELETE/UPDATE

This is upstream #27, but I was able to identify the exact source defect rather than merely repeat the report.

The issue's example has referenced coverage `[1,3), [3,5)` and referencing periods `[1,2), [2,5)`. Deleting `[1,3)` is incorrectly allowed; shortening `[1,5)` to `[1,3)` is likewise incorrectly allowed. ([github.com][5])

The problem is in `validate_foreign_key_old_row()`, `periods--1.2.sql:2116-2122`:

```sql
AND t.fk_start <= old_uk_start
AND t.fk_end   >= old_uk_end
```

Conceptually, that asks:

> “Does a referencing period completely contain the referenced period I'm deleting?”

What it needs first is an overlap/candidate test:

```text
fk_start < old_uk_end
AND fk_end > old_uk_start
```

and then each affected referencing period needs its **complete coverage recomputed against the post-action state** of the referenced table.

That's why `[1,2)` doesn't protect `[1,3)` in the existing check: it doesn't contain the entirety of `[1,3)`, so the trigger doesn't even consider it a violation.

This is not an obscure edge case; it breaks referential integrity.

PG18 core PERIOD foreign keys implement exactly the desired “combined referenced periods completely cover the referencing period” semantics. ([PostgreSQL][6]) For PG18 I would retire this custom subsystem where possible instead of repairing an increasingly complicated trigger implementation.

## T2. SYSTEM_TIME's own start/end columns may be excluded from version tracking

`add_system_time_period()` checks that excluded columns exist and are not PostgreSQL system columns (`periods--1.2.sql:944-963`). `set_system_time_period_excluded_columns()` repeats the same checks at 1011-1030.

Neither rejects the actual SYSTEM_TIME start or end columns.

That's dangerous because `OnlyExcludedColumnsChanged()` ignores excluded attributes (`periods.c:269-271`). Then:

```c
/* Don't change anything if only excluded columns are being updated. */
if (OnlyExcludedColumnsChanged(...))
    return new_row;
```

at `periods.c:485-487`.

And `write_history()` likewise skips both generated-value validation and history creation for an excluded-only update (`periods.c:656-684`).

So making, say, `system_time_start` an excluded column gives a route for an UPDATE to change the supposedly `GENERATED ALWAYS AS ROW START` value without the normal trigger restoring/rejecting it.

**Fix:** period boundary attributes must never be accepted in `excluded_column_names`. I'd enforce this both in SQL validation and defensively in the C trigger.

## T3. SYSTEM_TIME checks temporal unique-key columns globally, rather than per table

At `periods--1.2.sql:689-695`:

```sql
IF EXISTS (
    SELECT
    FROM periods.unique_keys AS uk
    WHERE uk.column_names &&
          ARRAY[start_column_name, end_column_name])
```

There is no:

```sql
uk.table_name = table_class
```

Therefore an unrelated table with a temporal unique key containing columns named `system_time_start`, `system_time_end`, or whatever custom names you chose can cause adding SYSTEM_TIME to this table to fail.

This is a plain cross-table scoping bug.

## T4. Existing rows and newly inserted rows get different NULL semantics for temporal FKs

`validate_foreign_key_new_row(fk, row_data)` contains explicit MATCH handling when it is checking one row. For example, a `MATCH SIMPLE` row with a NULL ordinary FK column returns success at `periods--1.2.sql:2318-2326`.

But when `add_foreign_key()` validates **all existing data**, it calls:

```sql
PERFORM periods.validate_foreign_key_new_row(key_name, NULL);
```

at line 1968.

That path constructs one generic coverage query over the entire referencing table and does not implement the row-level NULL exemptions. Ordinary equality predicates involving a NULL FK key therefore yield no referenced match and can cause an existing row to be reported invalid even though an equivalent newly inserted row would be accepted under `MATCH SIMPLE`.

That's an inconsistency between constraint creation and later enforcement.

## T5. `MATCH PARTIAL` exists in the type and DDL API but isn't implemented

The public enum declares:

```sql
('FULL', 'PARTIAL', 'SIMPLE')
```

but the validator literally says:

```sql
WHEN 'PARTIAL' THEN
    RAISE EXCEPTION 'partial not implemented';
```

at lines 2322-2323.

It should be rejected by `add_foreign_key()` immediately rather than create a constraint that fails only when a particular data shape reaches the trigger.

## T6. `CASCADE`, `SET NULL`, and `SET DEFAULT` are similarly advertised but not implemented

`periods.fk_actions` exposes all five SQL actions, while the catalog table has CHECK constraints rejecting three of them (`periods--1.2.sql:119-120`).

The transaction will eventually roll back, so this isn't silent corruption, but the API promises functionality it doesn't provide and fails very late in the creation process.

## T7. Temporal FK insert/update triggers are always deferred

At lines 1950-1954, the referencing-side constraint triggers are unconditionally:

```sql
DEFERRABLE INITIALLY DEFERRED
```

There is no API parameter corresponding to ordinary FK deferrability. That's materially different from PostgreSQL's normal immediate-FK behavior and means invalid application state can survive until COMMIT.

May be intentional, but it belongs in the contract if so.

---

# 3. C implementation defects

| Severity   | Finding                                                                                  | Status                        |
| ---------- | ---------------------------------------------------------------------------------------- | ----------------------------- |
| **HIGH**   | Inverted `strcmp()` means history INSERT plan is normally rebuilt every historical write | Source-confirmed              |
| **HIGH**   | Replaced SPI plans are never freed                                                       | Source-confirmed              |
| **MEDIUM** | Plan cache never evicts dropped relations                                                | Source-confirmed architecture |
| **MEDIUM** | Excluded-change detection uses binary Datum equality, not datatype equality              | Source-confirmed              |
| **LOW**    | Catalog-derived attribute numbers aren't defensively checked before use                  | Hardening                     |

## C1. The history-plan cache condition is backwards

This one is wonderfully small:

`periods.c:544-547`:

```c
/* If we didn't find it or the name changed, re-plan it */
if (!found ||
    !strcmp(hentry->schemaname, schemaname) ||
    !strcmp(hentry->tablename, tablename))
```

`strcmp()` returns zero when equal.

So `!strcmp(...)` is true when the name **hasn't changed**.

In normal operation, both names are unchanged, meaning the INSERT plan is prepared again on every historical UPDATE/DELETE.

It should be approximately:

```c
if (!found ||
    strcmp(hentry->schemaname, schemaname) != 0 ||
    strcmp(hentry->tablename, tablename) != 0)
```

There is a second edge case: if both schema and table have changed since the cached entry was last used, both existing comparisons become false, so the extension doesn't enter the supposedly “name changed” branch at all.

## C2. Every unnecessary re-plan also leaks the previous kept SPI plan

The branch does:

```c
hentry->qplan = SPI_prepare(...);
SPI_keepplan(hentry->qplan);
```

but does not `SPI_freeplan()` the previous `hentry->qplan` before overwriting the pointer.

Because C1 makes this branch run on practically every history write, this isn't just a theoretical cache leak: a busy versioned table can continually accumulate kept plans in a long-lived backend.

I would expect this to be very visible in pooled sessions with a large number of writes.

## C3. Cache entries never disappear

`InsertHistoryPlanHash` is backend-global, keyed by history relation OID, and there is no relcache invalidation/drop cleanup.

Even after C1/C2 are fixed, creating and dropping lots of system-versioned tables from long-lived backend processes leaves entries behind indefinitely.

Not catastrophic for a conventional static schema, but avoidable.

## C4. “Only excluded columns changed” is based on binary representation

At `periods.c:287-291`:

```c
datumIsEqual(old_datum, new_datum, typbyval, typlen)
```

This is representation equality, not the datatype's SQL equality operator.

For some varlena/custom types, two SQL-equal values can have different physical representations. That can produce unnecessary history rows because the code thinks a non-excluded value changed.

A typcache equality operator or an explicit supported-type restriction would give more defensible semantics.

---

# 4. `FOR PORTION OF` has several substantial correctness problems

This subsystem is the other area I'd hesitate to use in production.

| Severity   | Finding                                                                        | Status                      |
| ---------- | ------------------------------------------------------------------------------ | --------------------------- |
| **HIGH**   | Documented zero-argument/global add mode is broken                             | Source-confirmed            |
| **HIGH**   | Row reconstruction through JSON text is not generic/type-safe                  | Source-confirmed design     |
| **HIGH**   | Date/timestamp period endpoints are especially vulnerable to JSON quoting      | High confidence             |
| **HIGH**   | UPDATE row locator uses columns from all constraints, not just the primary key | Source-confirmed            |
| **MEDIUM** | Splitting cannot handle ordinary PKs without defaults                          | Source-confirmed limitation |
| **MEDIUM** | `SET CONSTRAINTS ALL DEFERRED` mutates unrelated application constraints       | Source-confirmed            |
| **LOW**    | Generated trigger names can silently truncate/collide                          | Source-confirmed            |

## F1. `periods.add_for_portion_view()` with no table contradicts its own documented behavior

Its comment says:

```text
If no table is specified, add the views everywhere.
```

at lines 1099-1104.

But before iterating over all tables, it does:

```sql
PERFORM periods._serialize(table_name);
EXECUTE format(
    'LOCK TABLE %s IN ACCESS SHARE MODE',
    table_name);
```

with `table_name = NULL`.

`format('%s', NULL)` produces an empty substitution, yielding an invalid `LOCK TABLE ...` command.

So the advertised global mode is dead before the loop starts.

Interestingly, `drop_for_portion_view(NULL,NULL)` does not have the same `LOCK TABLE` and can globally drop views, while its advisory locking with NULL isn't meaningful either.

## F2. The implementation serializes arbitrary PostgreSQL values through JSON text

`update_portion_of()` does:

```sql
jnew := row_to_json(NEW);
...
jsonb_each_text(...)
...
quote_nullable(value)
```

to recreate INSERTs/UPDATEs.

That works for some scalar values but cannot generically reproduce PostgreSQL values.

For example PostgreSQL arrays use input syntax like:

```text
{1,2}
```

while JSON serializes an array as something like:

```text
[1,2]
```

Similar issues exist for composites, `bytea`, domains/custom types and types whose JSON representation is not their PostgreSQL input representation.

This conflicts directly with `add_period()`'s philosophy of permitting essentially any subtype having a corresponding range type.

The fix is to preserve typed Datums/records and use SPI parameters, not make SQL literals from JSON text.

## F3. The endpoint-testing path has the same problem for dates/timestamps

The period endpoint variables are `jsonb`, then inserted via `%L` into:

```sql
CAST(%L AS datatype)
```

at lines 1229-1231.

JSON string values carry JSON quoting, which is exactly the kind of thing that can make a perfectly valid date/timestamp no longer be a valid SQL type literal.

The existing `FOR PORTION OF` regression coverage heavily favors integer periods, so this kind of generic-type breakage is easy to miss.

## F4. The UPDATE row predicate isn't actually a primary-key predicate

At lines 1401-1407:

```sql
JOIN pg_constraint AS c
  ON c.conkey @> ARRAY[a.attnum]
WHERE a.attrelid = info.table_name
  AND c.conrelid = info.table_name
```

There is **no**:

```sql
c.contype = 'p'
```

So every JSON column participating in any constraint can become part of the generated `WHERE`.

This has two effects.

First, nullable UNIQUE/FK-constrained values can generate expressions equivalent to `col = NULL`, causing the intended base row not to match.

Second, this becomes even less stable on PostgreSQL 18 because PG18 now stores column `NOT NULL` declarations in `pg_constraint` as well. The PG18 release notes explicitly call that catalog change out. ([PostgreSQL][7])

I cannot say this is the exact reason upstream #39's regression log fails, because I couldn't retrieve its attachment, but it is a concrete example of a pre-existing catalog assumption becoming more exposed on PG18.

## F5. A natural primary key can make split inserts impossible

The code deliberately removes every primary-key column from the `pre_row`/`post_row` it inserts when splitting an UPDATE (`periods--1.2.sql:1240-1279,1342-1354`).

That's fine for an identity/serial/default-generated PK.

It doesn't work for:

```sql
id bigint PRIMARY KEY
```

with no default: the split INSERT omits `id` and hits NOT NULL.

The README says a primary key is required, but doesn't make “must be regeneratable automatically” part of the contract.

## F6. It executes `SET CONSTRAINTS ALL DEFERRED`

At line 1340:

```sql
SET CONSTRAINTS ALL DEFERRED;
```

That isn't local to `periods`. It alters the behavior of **every deferrable constraint in the caller's transaction**.

An extension trigger should not unexpectedly change unrelated application constraints just because one temporal row split is occurring.

---

# 5. Range types and temporal UNIQUE keys

## R1. Automatic range-type selection can be ambiguous

`add_period()` searches `pg_range` for any range with the correct subtype/collation and a default subtype opclass (`periods--1.2.sql:413-424`).

There can be user-defined range types with the same subtype characteristics. The query doesn't require uniqueness or specify an ordering, so the default chosen range type can become arbitrary.

Explicitly supplied `range_type` is much safer.

## R2. Schema-qualified custom range types are formatted incorrectly

This is a real generic-range bug.

At lines 1564-1565:

```sql
format('%I(%I, %I, ''[)''::text) WITH &&',
       period_row.range_type, ...)
```

`range_type` is `regtype`.

If its textual representation is:

```text
myschema.myrange
```

`%I` quotes that as one identifier:

```sql
"myschema.myrange"
```

instead of:

```sql
"myschema"."myrange"
```

so custom range types outside a conveniently visible/default namespace break.

Use the OID/regtype's qualified SQL representation with `%s`, or separately quote namespace/type name.

This is especially notable because the README explicitly advertises the extension's willingness to use nonstandard range types.

## R3. Constraint identity is repeatedly determined by exact deparsed SQL text

Examples occur around:

* `add_period`: 445-472
* `add_system_time_period`: 833 onward
* `add_unique_key`: 1548-1591
* `rename_following`: ~3080-3240

The extension generates the string it expects `pg_get_constraintdef()` to return and compares for exact equality.

That's brittle across PostgreSQL releases because semantically equivalent expressions can deparse differently as parser/deparser behavior evolves.

For an extension trying to support 9.5 through 18+, comparing catalog structure/OIDs/dependency information is much safer than treating deparsed SQL as an API.

## R4. Generated temporal-key names can truncate when suffix numbers grow

`_choose_name()` reserves a fixed default amount of extra name space. `add_unique_key()` and `add_foreign_key()` subsequently append `_N`.

Once the suffix takes more bytes than reserved, assignment back to PostgreSQL's `name` type can truncate it. Under enough collisions this can produce another collision.

Minor, but easy to fix.

---

# 6. SYSTEM_TIME and history-table bugs

## H1. Existing SYSTEM_TIME columns have their defaults silently replaced

If the user already has a start column, `add_system_time_period()` unconditionally adds:

```sql
ALTER COLUMN start SET DEFAULT transaction_timestamp()
```

at line 765.

For an existing end column it similarly replaces the default with `infinity` at 784.

That's potentially destructive configuration rather than merely “adopting” existing columns. At minimum it should be explicit/documented; preferably reject incompatible pre-existing defaults unless the caller asks to replace them.

## H2. `add_period(..., period_name => 'system_time')` silently drops two arguments

The general API accepts:

```text
range_type
bounds_check_constraint
```

but if the normalized period name is `system_time`, line 302-304 simply calls:

```sql
periods.add_system_time_period(
    table_name, start_column_name, end_column_name)
```

and discards both of those supplied arguments.

That's surprising API behavior; either reject them explicitly or provide an equivalent SYSTEM_TIME path.

## H3. Non-timestamptz SYSTEM_TIME support is internally inconsistent

`add_system_time_period()` permits:

* `date`
* `timestamp`
* `timestamptz`

and maps them to the corresponding range type.

But `add_system_versioning()` always creates its synthesized query functions as:

```sql
...__as_of(timestamp with time zone)
...__between(timestamp with time zone, timestamp with time zone)
```

at lines 2554-2596.

So a DATE- or plain-TIMESTAMP-based SYSTEM_TIME table still exposes a timestamptz API, relying on implicit conversion and current timezone semantics.

I'd either make those functions use the actual period datatype or stop claiming the other SYSTEM_TIME types are interchangeable.

## H4. The infinity CHECK is constructed with a hard-coded timestamptz cast

The SYSTEM_TIME creation path builds its infinity constraint using a `timestamp with time zone` infinity literal even though DATE and TIMESTAMP are permitted.

Later `rename_following()` attempts to identify the same constraint using the **actual end-column type**.

That means a DATE/TIMESTAMP constraint's created text and its later expected text don't necessarily agree, so constraint rename-following can stop recognizing it.

This is another consequence of textual `pg_get_constraintdef()` matching.

## H5. Existing history tables are barely validated

When adopting an existing history table, compatibility means essentially:

```text
same column names
same types/typmods
same collations
```

(`periods--1.2.sql:2483-2501`).

Then the C code inserts with:

```c
INSERT INTO history VALUES (($1).*)
```

A history relation with generated columns, incompatible identity behavior, user triggers, rules, RLS behavior, etc. can pass that structural check and nevertheless fail or modify history writes.

Given that the SQL comments explicitly say “otherwise we trust the user”, this is partly a documented shortcut, but it's a big one.

## H6. The history-table name in the TRUNCATE trigger is stored temporarily as `name`

`truncate_system_versioning()` declares:

```sql
history_table_name name;
```

although the catalog field is `regclass`.

Schema-qualified relation rendering can exceed `NAMEDATALEN`, so this introduces pointless truncation risk. Keep it as `regclass`.

## H7. `TRUNCATE` destroys the entire history table

The base-table TRUNCATE trigger explicitly runs:

```sql
TRUNCATE history_table
```

This is deliberate — the tests expect it — so I wouldn't call it an accidental implementation bug.

But operationally it is an extremely sharp edge in something users may expect to be an audit/history mechanism: one `TRUNCATE` destroys both current state and historical evidence.

I would make this behavior unmissable in the documentation or consider forbidding TRUNCATE while system versioning is active.

---

# 7. DDL, ownership, backup/restore, and event-trigger fragility

## D1. The known pg_dump/pg_restore ACL bug is real and fairly fundamental

Open issue #22 describes a restore where generated history/view ACL commands are rejected by `periods.health_checks()`, after which normal GRANT changes become effectively wedged. ([GitHub][8])

The source supports the diagnosis.

`health_checks()` repeatedly interprets:

```sql
COALESCE(relacl, acldefault(...))
```

as though default owner privileges represented an explicit ACL that it should validate/propagate. During restore that makes owner defaults such as INSERT/UPDATE/DELETE appear on a history object that `periods` insists must be read-only, and the event trigger then blocks the ACL commands that would have normalized things.

This matters especially for major-version upgrades because `pg_upgrade` and dump/restore both rely heavily on object reconstruction and privilege restoration.

I would consider #22 a **PG18 migration blocker** until tested with your actual upgrade method.

## D2. Capitalized/mixed-case role names remain broken

This is current open issue #14 and the source still has the problematic construction.

`table_owner` is declared as `regrole`; it can render a mixed-case role as already quoted text. Then code such as:

```sql
format('... OWNER TO %I', table_owner)
```

quotes that textual representation again.

The issue demonstrates the resulting:

```text
role ""TestUser"" does not exist
```

error. ([GitHub][9])

Use the raw `pg_roles.rolname` with `%I`, or emit a properly formed `regrole` representation with `%s`; don't quote a quoted `regrole` rendering.

## D3. Rename tracking relies on heuristics, not stable object identity

`rename_following()` finds generated constraints/triggers after DDL by things such as:

* exact `pg_get_constraintdef()` text,
* function OID,
* absence of the old name.

If two semantically identical constraints/triggers exist, it can become ambiguous which one was renamed.

The more durable design is to retain object OIDs/dependencies where pg_upgrade allows it, or establish extension dependencies that PostgreSQL itself can follow.

## D4. Existing system-versioning helper functions are stored as text specifically to work around pg_upgrade

The source explains at `periods--1.2.sql:133-137` that these “should be regprocedure, but that blocks pg_upgrade”.

That's an understandable compatibility workaround, but it means the event trigger must continually resolve textual procedure identities and defend them against rename/drop. This is exactly the kind of fragile code path major releases expose.

## D5. Error message for nonpersistent history table names the wrong object

At `health_checks():3333-3340` it selects:

```sql
sv.table_name
```

then reports:

```text
history table "%" must remain persistent
```

using that base table.

Tiny bug, but confusing when diagnosing DDL.

## D6. Existing history relation lookup has no useful relkind check up front

`add_system_versioning()` finds any `pg_class` object of the requested same-schema name, then starts treating it as a history table.

A same-named view or other relation kind should be rejected immediately with a precise diagnostic rather than falling into attribute comparison/`ALTER TABLE` failures.

---

# 8. PostgreSQL 18-specific observations

There are three separate concepts here.

**C ABI/API compatibility:** I don't presently see a source-level C API break between your 17, 18, and master trees for the APIs `periods.c` uses. Upstream #39 likewise says the extension compiles on PG18. ([github.com][1])

**Regression compatibility:** not established. Upstream #39 says tests fail. Current source did not contain a substantive PG18 implementation fix; the 2025 “PG18” commit is packaging-only. So I would not interpret the presence of 18 in `.github/workflows/regression.yml` or Debian metadata as evidence of clean PG18 compatibility.

**Architecture:** PG18 makes a large chunk of `periods`' application-time machinery obsolete. Native PostgreSQL now knows temporal UNIQUE/PK and temporal FK semantics, represents them explicitly in `pg_constraint.conperiod`, and enforces them in core. ([PostgreSQL][6]) Core also gained other catalog changes such as NOT NULL constraints in `pg_constraint`, which matters because `periods` has several queries that implicitly assumed older catalog contents. ([PostgreSQL][7])

For a PG18 port, I'd therefore avoid merely adding another `#if PG_VERSION_NUM`. I'd split the project conceptually:

| Feature                             | PG18 direction                           |
| ----------------------------------- | ---------------------------------------- |
| Period predicates                   | Fine to retain, after volatility review  |
| Application-period metadata         | Possibly retain as convenience           |
| Temporal UNIQUE/PK                  | Prefer PG18 `WITHOUT OVERLAPS`           |
| Temporal FOREIGN KEY                | Strongly prefer PG18 `PERIOD` FK         |
| `FOR PORTION OF` UPDATE emulation   | Requires substantial rewrite if retained |
| SYSTEM_TIME row timestamps          | Still extension territory                |
| History tables/system versioning    | Still extension territory                |
| AS OF/BETWEEN convenience functions | Fine conceptually, but fix type handling |
| DDL/ACL event-trigger machinery     | Needs security and restore redesign      |

---

# 9. Smaller correctness/API issues

A few more I would put in the bug tracker even if they aren't blockers.

`add_foreign_key()` doesn't explicitly check that referencing and referenced ordinary-key arrays have the same cardinality. Multi-array `unnest()` pads shorter arrays with NULL, so malformed input gets a confusing later failure instead of the obvious “number of columns does not match”.

The system-time/foreign-key error at `periods--1.2.sql:1839` says “not allowed in UNIQUE keys” while processing a foreign key.

`add_unique_key()` discovers newly created unnamed constraints using catalog/OID ordering rather than assigning deterministic names before creation. Locking reduces the concurrency risk, but this is unnecessarily fragile.

The application's temporal-key/FK validation generates lots of SQL literals with `quote_literal()` rather than typed SPI parameters. Besides the JSON bugs above, this causes extra parse/planning work and makes generic datatype behavior depend on text I/O.

The generic predicate functions (`contains`, `overlaps`, etc.) are declared `IMMUTABLE` over `anyelement`, but their actual volatility is inherited from whatever comparison operators the datatype provides. PostgreSQL does not guarantee that every user-defined datatype's `<`, `=`, etc. is immutable. Either limit accepted datatypes or use a less aggressive volatility claim.

`_serialize()`'s comment/table documentation says DDL operations “lock the periods table”, but the implementation actually uses an advisory lock based on relation OIDs. That's relevant because advisory locks only coordinate participants that agree to use them.

The application does not support partitioned base tables (`relkind = 'p'` is explicitly rejected). History partitioning is partially contemplated but not first-class. These correspond to some of the open feature requests rather than bugs.

`FOR PORTION OF ... DELETE` remains unimplemented. Again, a limitation rather than a hidden defect.

The README compatibility declaration, changelog and package versioning have drifted apart: extension SQL version remains `1.2`, the package/tag is `1.2.3`, README says through PG15, CI lists PG18. That makes it hard for users to know what "`ALTER EXTENSION UPDATE`" actually means. A real PG18/security release needs a **new SQL extension version plus an upgrade script**; merely patching `periods--1.2.sql` won't fix already-installed databases.

---

# 10. Existing open issues versus things I found

Your saved page has sixteen open issues, including #39 PG18 support, #22 backup/restore ACLs, #27 temporal-FK inconsistency, #14 capitalized roles, #30 insert errors, #9 history-trigger failures, plus several feature/design requests.

Of the substantive old bugs I investigated, several are **still visibly present in HEAD**:

| Existing issue                 | Review result                                                                         |
| ------------------------------ | ------------------------------------------------------------------------------------- |
| #27 temporal FK inconsistency  | Root cause found; definitely still present                                            |
| #22 GRANT after backup/restore | Problematic ACL logic still present                                                   |
| #14 capitalized owner          | Faulty `%I`/`regrole` pattern still present                                           |
| #39 PG18 support               | No substantive PG18 source fix; compile looks plausible, regression status unresolved |
| #30 insertion error            | Report exists; I did not establish a reliable source-level root cause                 |
| #9 write-history failure/crash | Old report; I did not reproduce or establish a current root cause                     |

So I've intentionally **not** presented #30/#9 as newly proven bugs just because they're open. The stronger findings above are the ones I can tie directly to current source.

---

# What I would fix before testing PG18 seriously

My order would be:

1. **Fix the privilege boundary first.** Revoke public execution on management/internal functions, add explicit target-table owner/membership checks, and set secure function-level `search_path` values everywhere a SECURITY DEFINER function remains.
2. **Fix temporal FK integrity** — or better on PG18, replace the custom application-time unique/FK implementation with native `WITHOUT OVERLAPS`/`PERIOD`.
3. **Forbid SYSTEM_TIME start/end columns in the excluded set.**
4. **Fix the C plan-cache condition and free replaced plans.**
5. **Repair the pg_dump/pg_restore ACL model** and make an actual PG17→18 dump/restore/pg_upgrade test part of CI.
6. **Rewrite `FOR PORTION OF` without JSON/text round-tripping**, and restrict its row locator to a real primary-key definition.
7. Fix custom range quoting, range-type ambiguity, mixed-case role handling, and textual constraint matching.
8. Publish this as a new extension SQL version with a `1.2--X.Y.sql` upgrade script so existing installations actually receive the security changes.

The two findings I'd treat as an immediate security advisory are **S1** and **S2**. The findings I'd consider potential silent-data-integrity issues are **T1** and **T2**. And the `strcmp()` cache bug is likely the best explanation for surprisingly poor/memory-growing system-versioning workloads even where correctness appears fine.

If your immediate goal is “make `periods` safe enough for a PG18 production upgrade”, I would scope the first patch series to those four areas plus #22; the rest can follow without blocking the port.

[1]: https://github.com/xocolatl/periods/issues/39 "PostgreSQL 18 support · Issue #39 · xocolatl/periods · GitHub"
[2]: https://www.postgresql.org/docs/18/release-18.html?utm_source=chatgpt.com "PostgreSQL: Documentation: 18: E.6. Release 18"
[3]: https://www.postgresql.org/docs/17/sql-createfunction.html?utm_source=chatgpt.com "PostgreSQL: Documentation: 17: CREATE FUNCTION"
[4]: https://www.postgresql.org/docs/current/sql-createfunction.html?utm_source=chatgpt.com "PostgreSQL: Documentation: 18: CREATE FUNCTION"
[5]: https://github.com/xocolatl/periods/issues/27 "Foreign key constraints allow inconsistent state? · Issue #27 · xocolatl/periods · GitHub"
[6]: https://www.postgresql.org/docs/18/sql-createtable.html?utm_source=chatgpt.com "PostgreSQL: Documentation: 18: CREATE TABLE"
[7]: https://www.postgresql.org/files/documentation/pdf/18/postgresql-18-US.pdf?utm_source=chatgpt.com "PostgreSQL 18.1 Documentation"
[8]: https://github.com/xocolatl/periods/issues/22 "Can't adjust GRANTs after backup and restore · Issue #22 · xocolatl/periods · GitHub"
[9]: https://github.com/xocolatl/periods/issues/14 "Capitalised role throws error on add_system_versioning · Issue #14 · xocolatl/periods · GitHub"
