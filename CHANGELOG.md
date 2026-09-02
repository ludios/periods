# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
### Fixed

## [7.0.0] – 2026-08-30

New extension SQL version 7.0.0; existing 1.2 installations get the fixes with
`ALTER EXTENSION periods UPDATE`.  The version number jumps well past upstream's
so that this fork's releases can never collide with anything
[xocolatl/periods](https://github.com/xocolatl/periods) publishes later; the
extension keeps its name so that existing installations upgrade in place.

### Security

  - `add_system_versioning()` no longer allows SQL injection through a
    SYSTEM_TIME period's start/end column names.  The generated temporal helper
    functions (`…__as_of`, `…__between`, `…__between_symmetric`, `…__from_to`)
    embedded those column names with `%I` inside a single-quoted function-body
    literal; a name containing a single quote (combined with
    `check_function_bodies = off`) could run arbitrary statements as the
    `SECURITY DEFINER` owner.  The bodies are now built with an inner `format()`
    and embedded via `%L`.

  - All 19 `SECURITY DEFINER` functions now run with
    `SET search_path = pg_catalog, pg_temp`.  Without it every unqualified name
    in them — including calls to built-ins such as `lower(period_name)` — was
    resolved through the *caller's* `search_path`.  PostgreSQL prefers an exact
    argument-type match over one reached by coercion, so a caller who could
    create a function in any schema on their own path could shadow one of those
    calls and have it run with the definer's (typically the superuser's)
    privileges.  Naming `pg_temp` explicitly, and last, closes a second route:
    left unnamed it is searched *ahead* of `pg_catalog` for relation names, so a
    plain temporary view called `pg_class` captured the catalog reads inside
    `health_checks()`, and evaluating its target list ran the attacker's
    expressions as the definer.  No privilege at all was needed for that one.

    The last 34 bare references to `pg_class`, `pg_proc`, `pg_attribute`,
    `pg_constraint`, `pg_namespace` and `pg_authid` are now schema-qualified as
    well, so that route stays closed even without the pinned path.

    The bounds check `add_period()` creates now names the range subtype's own
    "less than" operator, schema-qualified when the pinned path does not make it
    visible, so a range type over a user-defined subtype still works;
    `rename_following()` rebuilds the same text through the same helper, so the
    two continue to agree.

    User-visible consequence: `regclass` and `regprocedure` values interpolated
    into messages now render schema-qualified, so `table "dp"` reads
    `table "public.dp"`.

  - The DDL entry points now require the caller to be able to act as the owner
    of the table they are given.  They are `SECURITY DEFINER` and executable by
    `PUBLIC`, and previously performed no authorization at all: any role could
    add periods (and with them `CHECK` constraints and `SET NOT NULL`), add
    SYSTEM_TIME — which *adds two columns* — switch on SYSTEM VERSIONING, and
    tear any of it down again, on a table it had no privilege on whatsoever.

    Three routes needed more than the table argument: `add_foreign_key()` puts
    triggers on the *referenced* table and now requires `REFERENCES` on the
    referenced key columns, as a plain `FOREIGN KEY` does;
    `drop_foreign_key(NULL, key)` names no table and now authorizes per key,
    accepting either end's owner (which is what keeps
    `drop_unique_key(… 'CASCADE')` working across owners); and
    `add_system_versioning()` would adopt an existing history table with a
    matching column layout and `ALTER TABLE … OWNER TO` it, so owning any table
    let you take over any other table whose columns lined up.

    The role being authorized is the one the session is acting as, ignoring
    `SECURITY DEFINER` frames — a new `periods._outer_user()` over PostgreSQL's
    `GetOuterUserId()`.  `current_user` is by then the definer, and
    `session_user` cannot see a `SET ROLE`.  PostgreSQL does not expose the
    *immediate* caller's identity inside a definer frame, so if you wrap a
    `periods` call in your own `SECURITY DEFINER` function the check sees
    whoever called your wrapper, not your wrapper's owner.

    `drop_for_portion_view(NULL, NULL)` means "drop the views everywhere", so it
    authorizes every view it is about to remove rather than relying on the table
    argument.  `drop_foreign_key()` stops checking once either end of the key has
    been dropped, since that is the `sql_drop` event trigger clearing up after a
    table whose owner we can no longer ask about.

    `EXECUTE` is deliberately still granted to `PUBLIC`: these functions are
    meant to be used by ordinary table owners.

  - `add_unique_key()` and `rename_following()` no longer pass a period's
    `range_type` through `%I`.  A `regtype` already renders as a finished
    identifier, quoted or schema-qualified as needed, so `%I` quoted it a second
    time and any range type outside `pg_catalog`, or with a name needing quotes,
    failed to get an exclusion constraint.

  - The SYSTEM_TIME period's own start/end columns can no longer be named in
    `excluded_column_names`.  Excluding a bound column disabled both the
    `GENERATED ALWAYS` enforcement and the history write for updates touching
    only that column, letting anyone with UPDATE privilege forge row-start
    timestamps without leaving history.  Both SQL entry points now reject the
    period columns, and the C triggers ignore such catalog entries outright —
    also covering rows written by older versions or restored from dumps.

### Changed

  - The `ddl_command_end` event triggers (`rename_following`, `health_checks`)
    return at once for commands that only create objects, and
    `rename_following` re-examines a period's bounds constraint only when one
    of its recorded columns has gone missing.  On a database with 200
    versioned tables every `CREATE TEMP TABLE` used to pay about 80 ms for a
    full audit of the extension's catalogs.

  - Temporal foreign key checks: the child-side check validates the row being
    written instead of every row sharing its key (a batch of N rows under one
    key cost O(N²) checks); the parent-side check considers only children
    whose period overlaps the old row's; and the update triggers now carry a
    `WHEN` condition, so an UPDATE that leaves the key and period unchanged is
    not checked at all.  Foreign keys created by 1.2 keep their old update
    triggers (constraint triggers cannot be replaced in place); drop and re-add
    them to get the last of these.

  - `health_checks()` looks the system-versioning helper functions up by name
    (`to_regprocedure`) instead of rendering every `pg_proc` row as text and
    comparing, and `rename_following()` writes its catalog fixes as plain
    `UPDATE ... FROM` statements.

  - `write_history()` returns before looking up the period when an UPDATE
    changed only excluded columns.

### Removed

  - Support for PostgreSQL releases before 17.  Fresh installations of 7.0.0
    rely on `CREATE EXTENSION` applying the base 1.2 script plus the update
    script, and each regression test has a single expected output, verified on
    17 and 18.

### Added

  - New regression test file `bugfixes` covering everything below.

  - `FOR PORTION OF` updates now work on tables whose primary key does not
    regenerate itself (e.g. a temporal `PRIMARY KEY (id, start, end)`), and on
    tables with array or composite columns — including updating such columns
    through the view.  Array lower bounds other than 1 are not preserved in
    the re-inserted slices (JSON carries none).

### Fixed

  - `drop_period()` of an application-time period no longer tears down the
    table's `system_time` triggers and SYSTEM VERSIONING machinery.

  - `FOR PORTION OF` works on a table with a temporal unique key.  The slices
    were inserted before the edited row was shrunk to the portion, so the
    first slice overlapped it and the key's exclusion constraint, which is not
    deferrable, rejected it.  The row is shrunk first now.

  - `rename_following()` re-discovers a period's bounds constraint by looking
    only at the columns the constraint references (`conkey`), instead of
    testing every pair of the table's columns; on a database with a few wide
    period tables that cross join had cost every DDL statement seconds.

  - Temporal foreign keys now prevent deleting or updating a referenced row
    while a child's period lies strictly inside the removed interval
    (issue #27); previously only children *containing* the whole interval
    were detected, so such parents could be changed and the children silently
    orphaned.

  - Temporal foreign keys where the referencing and referenced columns have
    the same name work now.  The coverage query correlated the key columns
    without table qualification, so `id = id` degenerated into a tautology:
    orphans of other keys could be accepted and valid rows were spuriously
    rejected.  FK violations also report SQLSTATE 23503 (foreign_key_violation)
    instead of P0001.

  - `FOR PORTION OF` updates: the edited row is matched by its primary key
    only.  It used to be matched on the columns of *every* constraint, so a
    NULL in any CHECK/UNIQUE/FOREIGN KEY-constrained column made the UPDATE
    silently do nothing while still inserting the leftover slices.

  - The `insert_into_history` plan cache re-plans exactly when the history
    table's qualified name (or row type) changes.  An inverted comparison made
    it re-plan on every history write, leaking one cached plan per write, and
    run a stale plan after the history table changed both schema and name.

  - `drop_protection` now guards the periods' bounds `CHECK` constraints, and
    `health_checks` re-enforces `NOT NULL` on period bound columns.

  - `drop_period(..., purge => true)` purges cleanly: for `system_time` with
    active versioning it no longer fails on a doubly-dropped constraint, and a
    bounds constraint shared by two periods survives until the last one is
    purged.

  - `TRUNCATE` now works on versioned tables whose history table has a
    schema-qualified name longer than 63 bytes.

  - `add_system_versioning()` and `health_checks()` no longer double-quote
    role names: a table owned by a role whose name needs quoting (mixed case,
    spaces) can get system versioning, and ownership realignment after
    `ALTER TABLE ... OWNER TO` works for such roles (issue #14).  The
    grant-propagation loop also learned to spell PUBLIC — which `aclexplode()`
    reports as OID 0 — instead of emitting `GRANT ... TO owner, -`, so a base
    table with `GRANT SELECT TO PUBLIC` can be versioned.

  - `add_system_time_period()` no longer refuses column names merely because
    a temporal unique key on some *other* table uses the same names as scalar
    key columns; the collision check is scoped to the table getting the
    period.

  - `add_foreign_key()` validates its arguments up front: the unimplemented
    `MATCH PARTIAL` and `CASCADE`/`SET NULL`/`SET DEFAULT` actions, NULL
    match/action parameters, an empty referencing-column list, and
    referencing/referenced column-count mismatches are rejected with clear
    errors.  They used to surface later as catalog constraint violations,
    'null values cannot be formatted as an SQL identifier', or — for
    `MATCH PARTIAL` — a deferred trigger exploding at COMMIT once a
    partially-NULL key arrived.  A SYSTEM_TIME column in the referencing list
    is reported as '... must not be part of foreign keys' instead of the
    misworded UNIQUE-keys message.

  - `add_period(..., 'system_time')` forwards `bounds_check_constraint` to
    `add_system_time_period()` instead of silently ignoring it, and rejects a
    supplied `range_type` (SYSTEM_TIME derives the range type from the column
    datatype).

  - `add_system_versioning()` refuses to adopt a pre-existing history
    *relation* that is not a regular table, with a clear message; a view used
    to produce a misleading "not compatible" error and a materialized view a
    'REVOKE ALL ON ERROR ...' syntax error.

  - `health_checks()` names the actual history table in its persistence
    error instead of the base table, and gives the real reason (it is used in
    SYSTEM VERSIONING; history tables never have periods).

  - `FOR PORTION OF` updates work for period datatypes with strict input
    parsers (e.g. a range over `uuid`): the endpoint comparisons and the row
    filter no longer leak JSON string quoting into SQL literals.  Datetime
    subtypes only ever worked because their parsers skip double quotes.
    Setting a portion bound to NULL raises 'portion bounds cannot be NULL'
    instead of a nonsense cast error.  A `jsonb` period subtype keeps its
    native JSON rendering (string endpoints stay quoted); a JSON-null bound
    is rejected with the same clean error, since the slice machinery cannot
    represent a jsonb null.  Container subtypes (arrays, `hstore`) remain
    unsupported in `FOR PORTION OF`, as before.

## [1.2] – 2020-09-21

### Added

  - Add Access Control to prevent users from modifying the history.  Only the table owner
    and superusers can do this because we can't prevent it.

  - Compatibility with PostgreSQL 13

### Fixed

  - Use SPI to insert into the history table.  They previous way of doing it didn't
    update the indexes, leading to wrong results depending on the execution plan.

    Users must REINDEX all indexes on history tables.

  - Ensure all of our functions are `SECURITY DEFINER`.

  - Ensure ownership of history and for-portion objects follow the main table's owner.

  - Quote all identifiers when building queries.

  - Don't use `regprocedure` in our catalogs, they prevent `pg_upgrade` from working.
    This reduces functionality a little but, but not being able to upgrade is a
    showstopper.

## [1.1] – 2020-02-05

### Added

  - Add support for excluded columns. These are columns for which
    updates do not cause `GENERATED ALWAYS AS ROW START` to change, and
    historical rows will not be generated.

    This is not in the standard, but was requested by several people.

  - Cache some query plans in the C code.

  - Describe the proper way to `ALTER` a table with `SYSTEM VERSIONING`.

### Fixed

  - Match columns in the main table and the history table by name.  This was an
    issue if either of the tables had dropped columns.

  - Use the main table's tuple descriptor when there is no mapping necessary with the
    history table's tuple descriptor (see previous item).  This works around PostgreSQL
    bug #16242 where missing attributes are not considered when detecting differences.

## [1.0] – 2019-08-25

### Added

  - Initial release. Supports all features of the SQL Standard
    concerning periods and `SYSTEM VERSIONING`.

[Unreleased]: https://github.com/xocolatl/periods/compare/v1.2...HEAD
[1.2]: https://github.com/xocolatl/periods/compare/v1.1...v1.2
[1.1]: https://github.com/xocolatl/periods/compare/v1.0...v1.1
[1.0]: https://github.com/xocolatl/periods/releases/tag/v1.0
