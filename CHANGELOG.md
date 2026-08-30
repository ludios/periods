# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
### Fixed

## [1.2.4] – 2026-08-30

New extension SQL version 1.2.4; existing 1.2 installations get the fixes with
`ALTER EXTENSION periods UPDATE`.

### Security

  - `add_system_versioning()` no longer allows SQL injection through a
    SYSTEM_TIME period's start/end column names.  The generated temporal helper
    functions (`…__as_of`, `…__between`, `…__between_symmetric`, `…__from_to`)
    embedded those column names with `%I` inside a single-quoted function-body
    literal; a name containing a single quote (combined with
    `check_function_bodies = off`) could run arbitrary statements as the
    `SECURITY DEFINER` owner.  The bodies are now built with an inner `format()`
    and embedded via `%L`.

    Two further SECURITY DEFINER weaknesses from the same review remain open and
    need a larger redesign: the functions do not pin `search_path` (a naive pin
    breaks user-defined range types), and they do not verify table ownership
    before running as the definer.  See `ai-code-reviews/claude.md` §3.2/§3.3.

### Removed

  - Support for PostgreSQL 9.5 and 9.6.  Fresh installations of 1.2.4 rely on
    `CREATE EXTENSION` applying the base 1.2 script plus the update script,
    which PostgreSQL supports since version 10.

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
