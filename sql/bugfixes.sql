-- Model-output: Claude Fable 5
-- Model-output: Claude Opus 4.8
-- Model-output: Claude Opus 5
/*
 * Regression tests for bugs found in the 2026-08 code review
 * (ai-code-reviews/claude.md).  Section markers below refer to that
 * document's numbering.
 */

/* Run tests as unprivileged user */
SET ROLE TO periods_unprivileged_user;

/*
 * §2.1: dropping an application-time period must not tear down the table's
 * SYSTEM VERSIONING machinery, which belongs to the system_time period.
 */

CREATE TABLE dp_sysver (id integer PRIMARY KEY, val text, vs date, ve date);
SELECT periods.add_period('dp_sysver', 'validity', 'vs', 've');
SELECT periods.add_system_time_period('dp_sysver');
SELECT periods.add_system_versioning('dp_sysver');
INSERT INTO dp_sysver (id, val, vs, ve) VALUES (1, 'a', '2000-01-01', '2010-01-01');

SELECT periods.drop_period('dp_sysver', 'validity');

/* The system_time period, its triggers, and its constraint must survive. */
SELECT period_name FROM periods.periods WHERE table_name = 'dp_sysver'::regclass ORDER BY period_name;
SELECT period_name FROM periods.system_time_periods WHERE table_name = 'dp_sysver'::regclass;
SELECT count(*) AS sysver_rows FROM periods.system_versioning WHERE table_name = 'dp_sysver'::regclass;
SELECT count(*) AS row_triggers FROM pg_catalog.pg_trigger WHERE tgrelid = 'dp_sysver'::regclass AND NOT tgisinternal;
SELECT count(*) AS infinity_constraints
FROM periods.system_time_periods AS stp
JOIN pg_catalog.pg_constraint AS c ON (c.conrelid, c.conname) = (stp.table_name, stp.infinity_check_constraint)
WHERE stp.table_name = 'dp_sysver'::regclass;

/* History must still be written (the INSERT above was an earlier transaction). */
UPDATE dp_sysver SET val = 'b' WHERE id = 1;
SELECT val FROM dp_sysver_history;

SELECT periods.drop_system_versioning('dp_sysver', drop_behavior => 'CASCADE', purge => true);
DROP TABLE dp_sysver;

/*
 * §2.3(b): update_portion_of() must match the edited row by its primary key
 * alone.  Matching on the columns of every constraint means a NULL in any
 * CHECK/UNIQUE/FOREIGN KEY-constrained column makes the central UPDATE match
 * nothing, while the pre/post slices are still inserted: the edit is silently
 * lost and the periods overlap.
 */

CREATE TABLE fp_nullable (
    id serial PRIMARY KEY,
    val integer,
    note text CHECK (note <> 'wrong'),
    s integer,
    e integer
);
SELECT periods.add_period('fp_nullable', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_nullable', 'p');
INSERT INTO fp_nullable (val, note, s, e) VALUES (100, NULL, 10, 40);

UPDATE fp_nullable__for_portion_of_p SET val = 999, s = 20, e = 30;

/* Expect [10,20) val 100, [20,30) val 999, [30,40) val 100; note NULL in all. */
SELECT id, val, note, s, e FROM fp_nullable ORDER BY s, e, id;

SELECT periods.drop_period('fp_nullable', 'p');
DROP TABLE fp_nullable;

/*
 * §4.1: insert_into_history()'s plan cache must re-plan exactly when the
 * history table's qualified name changes: not on every write (which leaks
 * one kept plan per history-writing statement), and never running a stale
 * plan after the history table changed both schema and name.
 */

CREATE TABLE pc_leak (id integer PRIMARY KEY, val integer);
SELECT periods.add_system_time_period('pc_leak');
SELECT periods.add_system_versioning('pc_leak');
INSERT INTO pc_leak (id, val) VALUES (1, 0);
UPDATE pc_leak SET val = 1;
UPDATE pc_leak SET val = 2;
UPDATE pc_leak SET val = 3;
UPDATE pc_leak SET val = 4;
UPDATE pc_leak SET val = 5;

/*
 * Count this backend's cached history INSERT plans: one per UPDATE when
 * leaking, exactly one when behaving.  pg_backend_memory_contexts needs a
 * superuser.
 */
RESET ROLE;
SELECT count(*) AS cached_history_insert_plans
FROM pg_backend_memory_contexts
WHERE ident LIKE 'INSERT INTO %pc_leak_history%';

/* Changing both schema and name of the history table must cause a re-plan. */
CREATE SCHEMA pc_leak_hs;
ALTER TABLE pc_leak_history SET SCHEMA pc_leak_hs;
ALTER TABLE pc_leak_hs.pc_leak_history RENAME TO relocated_history;

UPDATE pc_leak SET val = 6;
SELECT val FROM pc_leak_hs.relocated_history ORDER BY val;

SELECT periods.drop_system_versioning('pc_leak', drop_behavior => 'CASCADE', purge => true);
DROP TABLE pc_leak;
DROP SCHEMA pc_leak_hs;
SET ROLE TO periods_unprivileged_user;

/*
 * §2.2 (github issue #27): deleting or updating a referenced row must not
 * orphan children whose periods lie strictly inside the removed interval.
 * The old parent-side check looked only for children *containing* the whole
 * removed interval.
 */

CREATE TABLE fk_parent (id integer, s integer, e integer);
SELECT periods.add_period('fk_parent', 'p', 's', 'e');
SELECT periods.add_unique_key('fk_parent', ARRAY['id'], 'p', key_name => 'fk_parent_id_p');
CREATE TABLE fk_child (id integer, parent_id integer, s integer, e integer);
SELECT periods.add_period('fk_child', 'p', 's', 'e');
SELECT periods.add_foreign_key('fk_child', ARRAY['parent_id'], 'p', 'fk_parent_id_p', key_name => 'fk_child_parent_id_p');
INSERT INTO fk_parent VALUES (1, 0, 100);
INSERT INTO fk_child VALUES (1, 1, 30, 40);

/* Deleting or shrinking the parent across the child must be blocked. */
DELETE FROM fk_parent WHERE id = 1;
UPDATE fk_parent SET s = 35 WHERE id = 1;
/* Changing the key while a child references it must be blocked. */
UPDATE fk_parent SET id = 2 WHERE id = 1;
/* Changes that keep the child covered are allowed. */
UPDATE fk_parent SET s = 10, e = 90 WHERE id = 1;
SELECT id, s, e FROM fk_parent ORDER BY id, s;
SELECT id, parent_id, s, e FROM fk_child ORDER BY id, s;

/* NO ACTION is deferred: replacing coverage within a transaction is allowed. */
BEGIN;
DELETE FROM fk_parent WHERE id = 1;
INSERT INTO fk_parent VALUES (1, 10, 35), (1, 35, 90);
COMMIT;
SELECT id, s, e FROM fk_parent ORDER BY id, s;

/* Removing an interior piece of the coverage must still fail at commit. */
BEGIN;
DELETE FROM fk_parent WHERE (id, s) = (1, 35);
COMMIT;
SELECT id, s, e FROM fk_parent ORDER BY id, s;

/* Once the child is gone, the parent can go too. */
DELETE FROM fk_child;
DELETE FROM fk_parent;

/* RESTRICT differs from NO ACTION only in timing in this extension. */
CREATE TABLE fkr_parent (id integer, s integer, e integer);
SELECT periods.add_period('fkr_parent', 'p', 's', 'e');
SELECT periods.add_unique_key('fkr_parent', ARRAY['id'], 'p', key_name => 'fkr_parent_id_p');
CREATE TABLE fkr_child (id integer, parent_id integer, s integer, e integer);
SELECT periods.add_period('fkr_child', 'p', 's', 'e');
SELECT periods.add_foreign_key('fkr_child', ARRAY['parent_id'], 'p', 'fkr_parent_id_p',
    key_name => 'fkr_child_parent_id_p', update_action => 'RESTRICT', delete_action => 'RESTRICT');
INSERT INTO fkr_parent VALUES (1, 0, 100);
INSERT INTO fkr_child VALUES (1, 1, 30, 40);
DELETE FROM fkr_parent WHERE id = 1;
/* Extending the parent period keeps the child covered and is allowed. */
UPDATE fkr_parent SET e = 200 WHERE id = 1;
SELECT id, s, e FROM fkr_parent ORDER BY id, s;

/* A self-referencing foreign key. */
CREATE TABLE fk_selfref (id integer, mgr integer, s integer, e integer);
SELECT periods.add_period('fk_selfref', 'p', 's', 'e');
SELECT periods.add_unique_key('fk_selfref', ARRAY['id'], 'p', key_name => 'fk_selfref_id_p');
SELECT periods.add_foreign_key('fk_selfref', ARRAY['mgr'], 'p', 'fk_selfref_id_p', key_name => 'fk_selfref_mgr_p');
INSERT INTO fk_selfref VALUES (1, 1, 0, 50);
INSERT INTO fk_selfref VALUES (2, 1, 10, 20);
/* id 1 is still referenced by id 2. */
DELETE FROM fk_selfref WHERE id = 1;
/* id 2 is referenced by nobody. */
DELETE FROM fk_selfref WHERE id = 2;
/* Now id 1 references only itself, and deleting it removes both sides. */
DELETE FROM fk_selfref WHERE id = 1;
SELECT id, mgr, s, e FROM fk_selfref ORDER BY id, s;

/*
 * Same-named referencing and referenced columns: the coverage query used to
 * correlate them without table qualification, so "id = id" collapsed into a
 * tautology and the key filter vanished, accepting orphans of other keys and
 * spuriously rejecting valid rows once different keys' periods overlapped.
 */

CREATE TABLE sn_parent (id integer, s integer, e integer);
SELECT periods.add_period('sn_parent', 'p', 's', 'e');
SELECT periods.add_unique_key('sn_parent', ARRAY['id'], 'p', key_name => 'sn_parent_id_p');
CREATE TABLE sn_child (id integer, s integer, e integer);
SELECT periods.add_period('sn_child', 'p', 's', 'e');
SELECT periods.add_foreign_key('sn_child', ARRAY['id'], 'p', 'sn_parent_id_p', key_name => 'sn_child_id_p');
INSERT INTO sn_parent VALUES (1, 0, 20);
/* A child with a key that has no parent at all must be rejected. */
INSERT INTO sn_child VALUES (999, 5, 10);
/* A properly covered child is accepted. */
INSERT INTO sn_child VALUES (1, 5, 10);
INSERT INTO sn_parent VALUES (2, 10, 50);
/* Overlapping periods of *other* keys must not confuse the check. */
INSERT INTO sn_child VALUES (1, 12, 18);
SELECT id, s, e FROM sn_child ORDER BY id, s;
/* Re-adding the foreign key revalidates existing data with the same query. */
SELECT periods.drop_foreign_key('sn_child', 'sn_child_id_p');
SELECT periods.add_foreign_key('sn_child', ARRAY['id'], 'p', 'sn_parent_id_p', key_name => 'sn_child_id_p');

/* Clean up all foreign key test objects. */
SELECT periods.drop_period('fk_child', 'p', 'CASCADE');
DROP TABLE fk_child;
SELECT periods.drop_period('fk_parent', 'p', 'CASCADE');
DROP TABLE fk_parent;
SELECT periods.drop_period('fkr_child', 'p', 'CASCADE');
DROP TABLE fkr_child;
SELECT periods.drop_period('fkr_parent', 'p', 'CASCADE');
DROP TABLE fkr_parent;
SELECT periods.drop_period('fk_selfref', 'p', 'CASCADE');
DROP TABLE fk_selfref;
SELECT periods.drop_period('sn_child', 'p', 'CASCADE');
DROP TABLE sn_child;
SELECT periods.drop_period('sn_parent', 'p', 'CASCADE');
DROP TABLE sn_parent;

/*
 * §5.2: the bounds check constraint of a period must be protected from being
 * dropped (like the system_time infinity constraint already is), and
 * drop_period(..., purge => true) must not trip over its own protection, a
 * recursive teardown, or a constraint shared by another period.
 */

CREATE TABLE bcp (id integer, s integer, e integer);
SELECT periods.add_period('bcp', 'p', 's', 'e');
/* Dropping the bounds constraint out from under the period must be blocked. */
ALTER TABLE bcp DROP CONSTRAINT bcp_p_check;
/* And purging the period must work. */
SELECT periods.drop_period('bcp', 'p', purge => true);
DROP TABLE bcp;

/* CASCADE+purge of system_time with versioning tears down through
 * drop_system_versioning, which recurses into drop_period; the bounds
 * constraint must not be dropped twice. */
CREATE TABLE dtd (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('dtd');
SELECT periods.add_system_versioning('dtd');
SELECT periods.drop_period('dtd', 'system_time', 'CASCADE', purge => true);
SELECT periods.drop_system_versioning('dtd', drop_behavior => 'CASCADE', purge => true);
SELECT periods.drop_period('dtd', 'system_time', purge => true);
DROP TABLE dtd;

/* Two periods adopting the same pre-existing CHECK constraint: purging one
 * period must leave the constraint for the other. */
CREATE TABLE shc (id integer, s integer, e integer, CONSTRAINT shc_se_check CHECK (s < e));
SELECT periods.add_period('shc', 'p1', 's', 'e');
SELECT periods.add_period('shc', 'p2', 's', 'e');
SELECT periods.drop_period('shc', 'p1', purge => true);
SELECT count(*) AS constraint_survives FROM pg_catalog.pg_constraint
    WHERE (conrelid, conname) = ('shc'::regclass, 'shc_se_check');
SELECT periods.drop_period('shc', 'p2', purge => true);
SELECT count(*) AS constraint_purged FROM pg_catalog.pg_constraint
    WHERE (conrelid, conname) = ('shc'::regclass, 'shc_se_check');
DROP TABLE shc;

/*
 * §5.1: period bound columns are by definition NOT NULL and the rest of the
 * code relies on it, so health_checks() must reject dropping that.
 * Otherwise a NULL bound slips past the bounds CHECK constraint (NULL is not
 * false) and produces a nonsense period.
 */

CREATE TABLE nn (id integer, s integer, e integer);
SELECT periods.add_period('nn', 'p', 's', 'e');
ALTER TABLE nn ALTER COLUMN s DROP NOT NULL;
INSERT INTO nn VALUES (1, NULL, 10);
SELECT id, s, e FROM nn ORDER BY id;
SELECT periods.drop_period('nn', 'p');
DROP TABLE nn;

/*
 * §6.1: truncate_system_versioning() read the history table's regclass into a
 * name-typed variable, truncating the qualified form at 63 bytes, so history
 * tables whose schema-qualified name is longer could not be truncated.
 */

RESET ROLE;
CREATE SCHEMA history_schema_with_quite_a_long_name_indeed;
CREATE TABLE trunc_sv (id integer PRIMARY KEY, val integer);
SELECT periods.add_system_time_period('trunc_sv');
SELECT periods.add_system_versioning('trunc_sv');
ALTER TABLE trunc_sv_history SET SCHEMA history_schema_with_quite_a_long_name_indeed;
ALTER TABLE history_schema_with_quite_a_long_name_indeed.trunc_sv_history
    RENAME TO history_table_with_quite_a_long_name_as_well;
INSERT INTO trunc_sv (id, val) VALUES (1, 10);
UPDATE trunc_sv SET val = 20;
SELECT count(*) AS history_rows_before
    FROM history_schema_with_quite_a_long_name_indeed.history_table_with_quite_a_long_name_as_well;
TRUNCATE trunc_sv;
SELECT count(*) AS history_rows_after
    FROM history_schema_with_quite_a_long_name_indeed.history_table_with_quite_a_long_name_as_well;
SELECT periods.drop_system_versioning('trunc_sv', drop_behavior => 'CASCADE', purge => true);
DROP TABLE trunc_sv;
DROP SCHEMA history_schema_with_quite_a_long_name_indeed;
SET ROLE TO periods_unprivileged_user;

/*
 * §2.3(a): update_portion_of() stripped ALL primary key columns from the
 * re-inserted pre/post slices on the assumption that they regenerate.  For
 * primary key columns without a default — the temporal-key shape
 * PRIMARY KEY (id, s, e), or a plain integer PK — nothing regenerates them,
 * and the slice INSERT failed on a NULL primary key column.
 */

CREATE TABLE fp_tpk (id integer, val text, s integer, e integer, PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_tpk', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_tpk', 'p');
INSERT INTO fp_tpk VALUES (1, 'a', 10, 40);
UPDATE fp_tpk__for_portion_of_p SET val = 'b', s = 20, e = 30;
SELECT id, val, s, e FROM fp_tpk ORDER BY s;
SELECT periods.drop_period('fp_tpk', 'p');
DROP TABLE fp_tpk;

/* A single-column primary key cannot survive a row split; the error should
 * say so honestly (duplicate key) rather than fail on a NULL id. */
CREATE TABLE fp_spk (id integer PRIMARY KEY, val text, s integer, e integer);
SELECT periods.add_period('fp_spk', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_spk', 'p');
INSERT INTO fp_spk VALUES (1, 'a', 10, 40);
UPDATE fp_spk__for_portion_of_p SET val = 'b', s = 20, e = 30;
SELECT id, val, s, e FROM fp_spk ORDER BY s;
SELECT periods.drop_period('fp_spk', 'p');
DROP TABLE fp_spk;

/* Period bound columns must never be treated as regenerating, even when they
 * are in the primary key and have DEFAULTs: the slices carry freshly
 * computed bounds. */
CREATE TABLE fp_dpk (id serial, val text, s integer DEFAULT 0, e integer DEFAULT 100,
                     PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_dpk', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_dpk', 'p');
INSERT INTO fp_dpk (val, s, e) VALUES ('a', 10, 40);
UPDATE fp_dpk__for_portion_of_p SET val = 'b', s = 20, e = 30;
SELECT id, val, s, e FROM fp_dpk ORDER BY s, e, id;
SELECT periods.drop_period('fp_dpk', 'p');
DROP TABLE fp_dpk;

/* A primary key regenerated by a DOMAIN default (atthasdef is false for
 * those) must keep regenerating. */
CREATE SEQUENCE fp_dom_seq;
CREATE DOMAIN fp_dom_id AS integer DEFAULT nextval('fp_dom_seq');
CREATE TABLE fp_dom (id fp_dom_id PRIMARY KEY, val text, s integer, e integer);
SELECT periods.add_period('fp_dom', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_dom', 'p');
INSERT INTO fp_dom (val, s, e) VALUES ('a', 10, 40);
UPDATE fp_dom__for_portion_of_p SET val = 'b', s = 20, e = 30;
SELECT id, val, s, e FROM fp_dom ORDER BY s;
SELECT periods.drop_period('fp_dom', 'p');
DROP TABLE fp_dom;
DROP DOMAIN fp_dom_id;
DROP SEQUENCE fp_dom_seq;

/*
 * §2.3(c): the slice INSERTs and the central UPDATE's SET list were built
 * from jsonb_each_text() output as quoted literals, so array values arrived
 * in JSON form ('[1, 2, 3]') and composites as JSON objects; any table
 * carrying such a column could not use FOR PORTION OF at all.
 */

CREATE TABLE fp_arr (id serial PRIMARY KEY, val integer, tags integer[], s integer, e integer);
SELECT periods.add_period('fp_arr', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_arr', 'p');
INSERT INTO fp_arr (val, tags, s, e) VALUES (100, ARRAY[1, 2, 3], 10, 40);
/* Updating an unrelated column must not trip over the array column. */
UPDATE fp_arr__for_portion_of_p SET val = 999, s = 20, e = 30;
SELECT id, val, tags, s, e FROM fp_arr ORDER BY s;
/* Updating the array column itself must work, too. */
UPDATE fp_arr__for_portion_of_p SET tags = ARRAY[7, 8], s = 20, e = 30;
SELECT id, val, tags, s, e FROM fp_arr ORDER BY s;
SELECT periods.drop_period('fp_arr', 'p');
DROP TABLE fp_arr;

CREATE TYPE fp_pair AS (x integer, y text);
CREATE TABLE fp_comp (id serial PRIMARY KEY, val integer, pair fp_pair, s integer, e integer);
SELECT periods.add_period('fp_comp', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_comp', 'p');
INSERT INTO fp_comp (val, pair, s, e) VALUES (100, ROW(7, 'seven')::fp_pair, 10, 40);
UPDATE fp_comp__for_portion_of_p SET val = 999, s = 20, e = 30;
SELECT id, val, pair, s, e FROM fp_comp ORDER BY s;
SELECT periods.drop_period('fp_comp', 'p');
DROP TABLE fp_comp;
DROP TYPE fp_pair;

/* Known limitation: JSON carries no array bounds, so the slices' copies of a
 * non-1-based array are renumbered from 1 (the row updated in place keeps
 * its bounds).  This documents that behavior. */
CREATE TABLE fp_lb (id serial PRIMARY KEY, val integer, tags integer[], s integer, e integer);
SELECT periods.add_period('fp_lb', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_lb', 'p');
INSERT INTO fp_lb (val, tags, s, e) VALUES (100, '[0:2]={1,2,3}'::integer[], 10, 40);
UPDATE fp_lb__for_portion_of_p SET val = 999, s = 20, e = 30;
SELECT id, val, tags, array_dims(tags) AS dims, s, e FROM fp_lb ORDER BY s;
SELECT periods.drop_period('fp_lb', 'p');
DROP TABLE fp_lb;

/*
 * §3.1: add_system_versioning() assembled the generated temporal helper
 * functions (__as_of, __between, __between_symmetric, __from_to) by
 * interpolating the SYSTEM_TIME period's column names with %I *inside* a
 * single-quoted function-body literal.  %I (quote_ident) does not escape the
 * single quotes that delimit that literal, so a column name containing one
 * closed the body early; with check_function_bodies = off the trailing text
 * ran as extra statements executed by the SECURITY DEFINER (superuser) owner --
 * arbitrary code / privilege escalation.  The bodies are now built with an
 * inner format() and embedded via %L, which cannot be broken out of (this also
 * protects a hostile schema or view name).
 */

/*
 * An injection-shaped end-column name must be stored and quoted as literal
 * text, never executed.  A temp-table marker proves whether the payload ran as
 * the definer; check_function_bodies = off removes the body-validation that
 * would otherwise mask the exploit.
 */
SET check_function_bodies TO off;
CREATE TEMP TABLE b31_marker (fired boolean);
CREATE TABLE b31_inj (
    id integer PRIMARY KEY,
    ss timestamptz,
    "e'; INSERT INTO pg_temp.b31_marker VALUES (true); --" timestamptz
);
SELECT periods.add_system_time_period('b31_inj', 'ss', 'e''; INSERT INTO pg_temp.b31_marker VALUES (true); --');
SELECT periods.add_system_versioning('b31_inj');
SELECT EXISTS (SELECT FROM pg_temp.b31_marker) AS injection_fired;
SELECT periods.drop_system_versioning('b31_inj', drop_behavior => 'CASCADE', purge => true);
DROP TABLE b31_inj;
DROP TABLE b31_marker;
RESET check_function_bodies;

/*
 * A legitimately single-quoted period column name must work end-to-end: the
 * generated helper functions must be created and return the right rows.
 */
CREATE TABLE b31_ok (id integer PRIMARY KEY, val text, "s'" timestamptz, "e'" timestamptz);
SELECT periods.add_system_time_period('b31_ok', 's''', 'e''');
SELECT periods.add_system_versioning('b31_ok');
INSERT INTO b31_ok (id, val) VALUES (1, 'a');
SELECT val FROM b31_ok__as_of(transaction_timestamp()) ORDER BY val;
SELECT periods.drop_system_versioning('b31_ok', drop_behavior => 'CASCADE', purge => true);
DROP TABLE b31_ok;

/*
 * sol.md T3: add_system_time_period() checked the requested start/end column
 * names against the unique keys of EVERY table, so a temporal unique key on an
 * unrelated table whose scalar columns share a name blocked adding SYSTEM_TIME.
 */

CREATE TABLE t3_other (sys_s integer, vf integer, vt integer);
SELECT periods.add_period('t3_other', 'validity', 'vf', 'vt');
SELECT periods.add_unique_key('t3_other', '{sys_s}', 'validity', key_name => 't3_other_uk');

CREATE TABLE t3_victim (id integer PRIMARY KEY);
SELECT periods.add_system_time_period('t3_victim', 'sys_s', 'sys_e');

/* A collision on the table itself must still be rejected */
CREATE TABLE t3_self (sys_s timestamptz, vf integer, vt integer);
SELECT periods.add_period('t3_self', 'validity', 'vf', 'vt');
SELECT periods.add_unique_key('t3_self', '{sys_s}', 'validity', key_name => 't3_self_uk');
SELECT periods.add_system_time_period('t3_self', 'sys_s', 'sys_e');

SELECT periods.drop_unique_key('t3_self', 't3_self_uk');
SELECT periods.drop_unique_key('t3_other', 't3_other_uk');
DROP TABLE t3_self;
DROP TABLE t3_victim;
DROP TABLE t3_other;

/*
 * sol.md T2: excluded_column_names accepted the SYSTEM_TIME period's own
 * start/end columns.  Excluding a bound column disables both the
 * GENERATED ALWAYS enforcement and the history write for updates touching
 * only that column, so the row-start timestamp became forgeable without
 * leaving any history.
 */

CREATE TABLE t2_excl (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('t2_excl', excluded_column_names => '{system_time_start}');
SELECT periods.add_system_time_period('t2_excl');
SELECT periods.add_system_versioning('t2_excl');

INSERT INTO t2_excl (id, val) VALUES (1, 'a');
UPDATE t2_excl SET system_time_start = 'epoch';
SELECT id, val, system_time_start = 'epoch' AS forged FROM t2_excl;
SELECT count(*) AS history_rows FROM t2_excl_history;

SELECT periods.set_system_time_period_excluded_columns('t2_excl', '{system_time_end}');
/* Excluding an ordinary column must keep working */
SELECT periods.set_system_time_period_excluded_columns('t2_excl', '{val}');
SELECT stp.excluded_column_names
FROM periods.system_time_periods AS stp
WHERE stp.table_name = 't2_excl'::regclass;
SELECT periods.drop_system_versioning('t2_excl', drop_behavior => 'CASCADE', purge => true);
DROP TABLE t2_excl;

/* Custom bound column names must be looked up, not assumed */
CREATE TABLE t2_names (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('t2_names', 'my_start', 'my_end');
SELECT periods.set_system_time_period_excluded_columns('t2_names', '{my_end}');
SELECT stp.excluded_column_names
FROM periods.system_time_periods AS stp
WHERE stp.table_name = 't2_names'::regclass;
DROP TABLE t2_names;

/* A table without a SYSTEM_TIME period: the setter stays a silent no-op */
CREATE TABLE t2_nop (id integer, val text);
SELECT periods.set_system_time_period_excluded_columns('t2_nop', '{val}');
DROP TABLE t2_nop;

/*
 * Defense in depth: a bound column that reached the catalog through an old
 * version (or a dump/restore of one) must be ignored by the C triggers, not
 * honored.  Poison the catalog directly as superuser to simulate that.
 */
CREATE TABLE t2_legacy (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('t2_legacy');
SELECT periods.add_system_versioning('t2_legacy');
INSERT INTO t2_legacy (id, val) VALUES (1, 'a');
RESET ROLE;
UPDATE periods.system_time_periods
SET excluded_column_names = '{system_time_start}'
WHERE table_name = 't2_legacy'::regclass;
SET ROLE TO periods_unprivileged_user;
UPDATE t2_legacy SET system_time_start = 'epoch';
SELECT id, val, system_time_start = 'epoch' AS forged FROM t2_legacy;
SELECT count(*) AS history_rows FROM t2_legacy_history;
SELECT periods.drop_system_versioning('t2_legacy', drop_behavior => 'CASCADE', purge => true);
DROP TABLE t2_legacy;

/*
 * sol.md D2 (upstream #14): add_system_versioning() and health_checks()
 * formatted role names by applying %I to a regrole rendering, which is
 * already quoted, so any owner whose name needs quoting was looked up as a
 * role with literal double quotes in its name.  The grant-propagation loop
 * also rendered the PUBLIC pseudo-role (grantee OID 0) as "-", which is not
 * valid GRANT syntax.
 */

RESET ROLE;

CREATE ROLE "Bug14 Owner";
CREATE ROLE "Bug14 Successor";
CREATE ROLE bug14_pub_owner;
CREATE ROLE bug14_probe;

CREATE TABLE b14 (id integer PRIMARY KEY, val text, vf integer, vt integer);
ALTER TABLE b14 OWNER TO "Bug14 Owner";
SELECT periods.add_system_time_period('b14');
SELECT periods.add_system_versioning('b14');

/* The history objects must all belong to the table's owner */
SELECT c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
FROM pg_catalog.pg_class AS c
WHERE c.relname IN ('b14', 'b14_history', 'b14_with_history')
ORDER BY c.relname;
SELECT p.proname, pg_catalog.pg_get_userbyid(p.proowner) AS owner
FROM pg_catalog.pg_proc AS p
WHERE p.proname LIKE 'b14\_\_%'
ORDER BY p.proname;

/* health_checks' ownership realignment must handle quoted names, too,
 * including the FOR PORTION OF view */
SELECT periods.add_period('b14', 'validity', 'vf', 'vt');
SELECT periods.add_for_portion_view('b14', 'validity');
ALTER TABLE b14 OWNER TO "Bug14 Successor";
SELECT c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
FROM pg_catalog.pg_class AS c
WHERE c.relname IN ('b14', 'b14_history', 'b14_with_history', 'b14__for_portion_of_validity')
ORDER BY c.relname;
SELECT p.proname, pg_catalog.pg_get_userbyid(p.proowner) AS owner
FROM pg_catalog.pg_proc AS p
WHERE p.proname LIKE 'b14\_\_%'
ORDER BY p.proname;
SELECT periods.drop_for_portion_view('b14', 'validity');

/* Reconnecting a retained history table goes through the adoption branch */
SELECT periods.drop_system_versioning('b14', drop_behavior => 'CASCADE');
SELECT periods.add_system_versioning('b14');
SELECT c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
FROM pg_catalog.pg_class AS c
WHERE c.relname IN ('b14_history', 'b14_with_history')
ORDER BY c.relname;

SELECT periods.drop_system_versioning('b14', drop_behavior => 'CASCADE', purge => true);
DROP TABLE b14;

/* A SELECT grant to PUBLIC on the base table must propagate, not break */
CREATE TABLE b14pub (id integer PRIMARY KEY, val text);
ALTER TABLE b14pub OWNER TO bug14_pub_owner;
GRANT SELECT ON b14pub TO PUBLIC;
SELECT periods.add_system_time_period('b14pub');
SELECT periods.add_system_versioning('b14pub');
SELECT pg_catalog.has_table_privilege('bug14_probe', 'b14pub_history', 'SELECT') AS probe_sees_history;
SELECT periods.drop_system_versioning('b14pub', drop_behavior => 'CASCADE', purge => true);
DROP TABLE b14pub;

DROP ROLE "Bug14 Owner";
DROP ROLE "Bug14 Successor";
DROP ROLE bug14_pub_owner;
DROP ROLE bug14_probe;

SET ROLE TO periods_unprivileged_user;

/*
 * sol.md D6: add_system_versioning() adopted any same-named pg_class entry as
 * the history table without checking relkind.  A view happened to fail the
 * attribute-compatibility check (views have no system columns in
 * pg_attribute), a materialized view sailed through it and died later on
 * generated 'REVOKE ALL ON ERROR ...' SQL -- both errors pointing far away
 * from the actual problem.
 */

CREATE TABLE d6 (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('d6');

CREATE VIEW d6_history AS SELECT * FROM d6;
SELECT periods.add_system_versioning('d6');
DROP VIEW d6_history;

CREATE MATERIALIZED VIEW d6_history AS SELECT * FROM d6;
SELECT periods.add_system_versioning('d6');
DROP MATERIALIZED VIEW d6_history;

/* Adopting a legitimate pre-existing plain table must keep working */
CREATE TABLE d6_history (LIKE d6);
SELECT periods.add_system_versioning('d6');
SELECT periods.drop_system_versioning('d6', drop_behavior => 'CASCADE', purge => true);
DROP TABLE d6;

/*
 * sol.md H2: add_period(..., 'system_time') silently discarded its
 * range_type and bounds_check_constraint arguments instead of applying or
 * rejecting them.
 */

CREATE TABLE h2 (id integer PRIMARY KEY);
SELECT periods.add_period('h2', 'system_time', 'sts', 'ste',
                          bounds_check_constraint => 'h2_custom_bounds');
SELECT p.period_name, p.bounds_check_constraint
FROM periods.periods AS p
WHERE p.table_name = 'h2'::regclass;
SELECT periods.drop_system_time_period('h2', purge => true);
SELECT periods.add_period('h2', 'system_time', 'sts', 'ste', range_type => 'tstzrange');
SELECT periods.drop_system_time_period('h2', purge => true);
DROP TABLE h2;

/*
 * sol.md T5/T6/§9: add_foreign_key() validated its parameters too late or
 * not at all.  MATCH PARTIAL was accepted at DDL time and exploded only when
 * a partially-NULL key reached the deferred trigger; CASCADE/SET NULL/
 * SET DEFAULT actions and NULL parameters surfaced as raw catalog
 * constraint violations after the triggers were already created; and a
 * referencing/referenced column-count mismatch (including multidimensional
 * and empty arrays) died with 'null values cannot be formatted as an SQL
 * identifier' from the NULL-padded correlation builder.
 */

CREATE TABLE fkb_uk (uid integer, uid2 integer, vf integer, vt integer);
SELECT periods.add_period('fkb_uk', 'validity', 'vf', 'vt');
SELECT periods.add_unique_key('fkb_uk', '{uid,uid2}', 'validity', key_name => 'fkb_uk2');
SELECT periods.add_unique_key('fkb_uk', '{uid}', 'validity', key_name => 'fkb_uk1');
CREATE TABLE fkb_fk (uid integer, uid2 integer, vf integer, vt integer);
SELECT periods.add_period('fkb_fk', 'validity', 'vf', 'vt');

/* MATCH PARTIAL: unimplemented, must not be accepted at DDL time */
SELECT periods.add_foreign_key('fkb_fk', '{uid,uid2}', 'validity', 'fkb_uk2', match_type => 'PARTIAL', key_name => 'fkb_partial');
INSERT INTO fkb_uk VALUES (1, 1, 0, 100);
INSERT INTO fkb_fk VALUES (1, NULL, 10, 20);
DELETE FROM fkb_fk;
SELECT periods.drop_foreign_key('fkb_fk', 'fkb_partial');

/* Unsupported referential actions must be rejected up front */
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk1', delete_action => 'CASCADE');
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk1', update_action => 'SET NULL');

/* Column-count mismatches in both directions, multidimensional, and empty.
 * (terse: the verbose CONTEXT here is version-dependent wording) */
\set VERBOSITY terse
SELECT periods.add_foreign_key('fkb_fk', '{uid,uid2}', 'validity', 'fkb_uk1');
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk2');
SELECT periods.add_foreign_key('fkb_fk', '{{uid,uid2}}', 'validity', 'fkb_uk1');
SELECT periods.add_foreign_key('fkb_fk', '{}', 'validity', 'fkb_uk1');
\set VERBOSITY default

/* Explicit NULL parameters must not reach the catalog inserts */
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk1', match_type => NULL);
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk1', update_action => NULL);

/* The supported shape keeps working and enforcing */
SELECT periods.add_foreign_key('fkb_fk', '{uid}', 'validity', 'fkb_uk1', update_action => 'RESTRICT', delete_action => 'RESTRICT', key_name => 'fkb_ok');
INSERT INTO fkb_fk VALUES (1, NULL, 10, 20);
INSERT INTO fkb_fk VALUES (99, NULL, 10, 20);
DELETE FROM fkb_fk;
SELECT periods.drop_foreign_key('fkb_fk', 'fkb_ok');

DROP TABLE fkb_fk;
DROP TABLE fkb_uk;

/*
 * sol.md F3 (reframed): update_portion_of() interpolated raw jsonb values into
 * the endpoint-comparison casts, so the JSON string quoting leaked into the
 * literal.  The datetime types survive by parser leniency, but any subtype
 * with a strict input function (e.g. uuid) failed outright, and a NULL bound
 * produced a nonsense cast error.
 */

CREATE TYPE bugfix_uuidrange AS RANGE (subtype = uuid);
CREATE TABLE fp_uuid (id integer, val text, s uuid, e uuid, PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_uuid', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_uuid', 'p');
INSERT INTO fp_uuid VALUES (1, 'a', '00000000-0000-0000-0000-000000000000',
                                    'ffffffff-ffff-ffff-ffff-ffffffffffff');
UPDATE fp_uuid__for_portion_of_p SET val = 'b',
    s = '30000000-0000-0000-0000-000000000000',
    e = '60000000-0000-0000-0000-000000000000';
SELECT id, val, s, e FROM fp_uuid ORDER BY s;
SELECT periods.drop_for_portion_view('fp_uuid', 'p');
SELECT periods.drop_period('fp_uuid', 'p');
DROP TABLE fp_uuid;
DROP TYPE bugfix_uuidrange;

/* The common date case worked before through parser leniency and must keep working */
CREATE TABLE fp_datep (id integer, val text, s date, e date, PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_datep', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_datep', 'p');
INSERT INTO fp_datep VALUES (1, 'a', '2020-01-01', '2021-01-01');
UPDATE fp_datep__for_portion_of_p SET val = 'b', s = '2020-03-01', e = '2020-06-01';
SELECT id, val, s, e FROM fp_datep ORDER BY s;

/* A NULL portion bound is an error, not a garbage cast */
UPDATE fp_datep__for_portion_of_p SET val = 'c', s = NULL, e = '2020-06-01';

SELECT periods.drop_for_portion_view('fp_datep', 'p');
SELECT periods.drop_period('fp_datep', 'p');
DROP TABLE fp_datep;

/* Container subtypes (JSON form is not the type's input form) are not
 * supported by FOR PORTION OF; the failure must stay the same, not worsen. */
CREATE TYPE bugfix_intarrrange AS RANGE (subtype = integer[]);
CREATE TABLE fp_arrp (id integer, val text, s integer[], e integer[], PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_arrp', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_arrp', 'p');
INSERT INTO fp_arrp VALUES (1, 'a', '{1}', '{9}');
\set VERBOSITY terse
UPDATE fp_arrp__for_portion_of_p SET val = 'b', s = '{3}', e = '{6}';
\set VERBOSITY default
SELECT id, val, s, e FROM fp_arrp ORDER BY s;
SELECT periods.drop_for_portion_view('fp_arrp', 'p');
SELECT periods.drop_period('fp_arrp', 'p');
DROP TABLE fp_arrp;
DROP TYPE bugfix_intarrrange;

/* Batch-review follow-up: a jsonb period subtype keeps its native JSON
 * rendering, so string endpoints stay quoted and the previously-working
 * sequence-backed-PK case still splits.  A JSON-null bound is cleanly
 * rejected: the jsonb_populate_record() slice machinery cannot represent a
 * jsonb null (JSON null in a record is SQL NULL), so accepting it would only
 * trade this error for a NOT NULL violation mid-split. */
CREATE TYPE bugfix_jsonbrange AS RANGE (subtype = jsonb);
CREATE TABLE fp_jb (id serial PRIMARY KEY, val text, s jsonb, e jsonb);
SELECT periods.add_period('fp_jb', 'p', 's', 'e');
SELECT periods.add_for_portion_view('fp_jb', 'p');
INSERT INTO fp_jb (val, s, e) VALUES ('a', '"a"', '"zz"');
UPDATE fp_jb__for_portion_of_p SET val = 'b', s = '"c"', e = '"m"';
SELECT val, s, e FROM fp_jb ORDER BY s;
UPDATE fp_jb__for_portion_of_p SET val = 'c', s = 'null', e = '"a"';
SELECT periods.drop_for_portion_view('fp_jb', 'p');
SELECT periods.drop_period('fp_jb', 'p');
DROP TABLE fp_jb;
DROP TYPE bugfix_jsonbrange;
/*
 * §3.2 (prerequisite): periods.periods.range_type is a regtype, and a regtype's
 * text form is already a correctly quoted — and, when the type is not visible on
 * the search_path, schema-qualified — identifier.  Wrapping it in %I quotes the
 * whole thing a second time, so a range type whose rendered name is not a bare
 * lowercase identifier breaks both the EXCLUDE constraint that add_unique_key
 * builds and the one rename_following re-derives after a rename.
 */

CREATE TYPE "MyRange" AS RANGE (SUBTYPE = integer);

/* add_unique_key building the constraint itself */
CREATE TABLE qr_make (id integer, s integer, e integer);
SELECT periods.add_period('qr_make', 'p', 's', 'e', '"MyRange"');
SELECT periods.add_unique_key('qr_make', ARRAY['id'], 'p', 'qr_make_k');

/* add_unique_key matching a constraint that already exists */
CREATE TABLE qr_match (id integer, s integer, e integer);
SELECT periods.add_period('qr_match', 'p', 's', 'e', '"MyRange"');
ALTER TABLE qr_match
    ADD CONSTRAINT qr_match_u UNIQUE (id, s, e),
    ADD CONSTRAINT qr_match_x EXCLUDE USING gist (id WITH =, "MyRange"(s, e, '[)') WITH &&);
SELECT periods.add_unique_key('qr_match', ARRAY['id'], 'p', 'qr_match_k', 'qr_match_u', 'qr_match_x');

/* rename_following re-derives the constraint text when it is renamed away */
ALTER TABLE qr_match RENAME CONSTRAINT qr_match_x TO qr_match_x2;
SELECT exclude_constraint FROM periods.unique_keys WHERE key_name = 'qr_match_k';

DROP TABLE qr_match;
DROP TABLE qr_make;
DROP TYPE "MyRange";

/*
 * §3.2: a SECURITY DEFINER function must not resolve unqualified names through
 * the caller's search_path.  add_period() runs lower(period_name) on a `name`
 * value, so an exact-signature lower(name) in any schema the caller can write to
 * beats pg_catalog.lower(text) — PostgreSQL prefers an exact argument-type match
 * over a coercion regardless of where pg_catalog sits in the path — and it then
 * runs with the definer's privileges.
 */

RESET ROLE;
CREATE SCHEMA b32_evil AUTHORIZATION periods_unprivileged_user;
CREATE TEMP TABLE b32_marker (ran_as_definer boolean);
GRANT INSERT, SELECT ON pg_temp.b32_marker TO periods_unprivileged_user;
SET ROLE TO periods_unprivileged_user;

CREATE FUNCTION b32_evil.lower(name) RETURNS name LANGUAGE sql VOLATILE AS
$$
    INSERT INTO pg_temp.b32_marker VALUES (current_user <> 'periods_unprivileged_user');
    SELECT pg_catalog.lower($1)::name;
$$;

CREATE TABLE b32 (id integer, s date, e date);
SET search_path TO b32_evil, public;
SELECT periods.add_period('public.b32', 'p', 's', 'e');
RESET search_path;

SELECT count(*) AS hijack_calls,
       coalesce(bool_or(ran_as_definer), false) AS ran_as_definer
FROM pg_temp.b32_marker;

DROP TABLE b32;
DROP FUNCTION b32_evil.lower(name);
RESET ROLE;
DROP SCHEMA b32_evil;
DROP TABLE b32_marker;
SET ROLE TO periods_unprivileged_user;

/*
 * §3.2 again, without needing CREATE anywhere: unless pg_temp is named in the
 * search_path it is searched *before* pg_catalog for relation names, so a plain
 * temporary view can capture an unqualified system-catalog reference inside a
 * SECURITY DEFINER function and get its own expressions evaluated with the
 * definer's privileges.  TEMPORARY on the database is granted to PUBLIC by
 * default, so every role can do this.
 */

CREATE TEMP TABLE b32t_marker (ran_as_definer boolean);

CREATE FUNCTION b32t_evil() RETURNS boolean LANGUAGE sql VOLATILE AS
$$
    INSERT INTO pg_temp.b32t_marker VALUES (current_user <> 'periods_unprivileged_user');
    SELECT true;
$$;

CREATE TEMP VIEW pg_class AS
    SELECT c.*, public.b32t_evil() AS hijacked FROM pg_catalog.pg_class AS c;
/* Cached plans still name pg_catalog.pg_class; an attacker just uses a fresh session. */
DISCARD PLANS;
CREATE TABLE b32t (id integer, s date, e date);
SELECT periods.add_period('public.b32t', 'p', 's', 'e');
DROP VIEW pg_temp.pg_class;

/* The call count depends on how many catalog scans ran, so only its sign matters. */
SELECT count(*) > 0 AS hijack_fired,
       coalesce(bool_or(ran_as_definer), false) AS ran_as_definer
FROM pg_temp.b32t_marker;

DROP TABLE b32t;
DROP FUNCTION b32t_evil();
DROP TABLE b32t_marker;

/* Every SECURITY DEFINER function in the extension must pin its search_path. */
SELECT count(*) AS security_definer_functions
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'periods' AND p.prosecdef;

SELECT p.proname AS security_definer_without_pinned_search_path
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'periods'
  AND p.prosecdef
  AND NOT coalesce(p.proconfig, '{}') @> ARRAY['search_path=pg_catalog, pg_temp']
ORDER BY p.proname;

/*
 * §3.3: the DDL entry points are SECURITY DEFINER and executable by PUBLIC, and
 * never check that the caller may reshape the table they are pointed at.  A
 * role with no privilege at all on someone else's table can add periods (and
 * with them CHECK constraints and SET NOT NULL), add SYSTEM_TIME — which adds
 * two columns — switch on SYSTEM VERSIONING, and tear any of it down again.
 */

RESET ROLE;
CREATE ROLE b33_victim;
CREATE ROLE b33_attacker;
CREATE ROLE b33_bystander;
CREATE SCHEMA b33 AUTHORIZATION b33_victim;
CREATE SCHEMA b33a AUTHORIZATION b33_attacker;
GRANT USAGE ON SCHEMA b33 TO b33_attacker;
GRANT USAGE, CREATE ON SCHEMA b33a TO b33_victim;

SET SESSION AUTHORIZATION b33_victim;
CREATE TABLE b33.vt (id integer PRIMARY KEY, s date NOT NULL, e date NOT NULL, val text);
SELECT periods.add_period('b33.vt', 'p', 's', 'e');
SELECT periods.add_unique_key('b33.vt', ARRAY['id'], 'p', 'b33_vt_k');
/* Same shape b33a.base will have once it is system-time versioned. */
CREATE TABLE b33a.spoils (id integer, val text, system_time_start timestamptz, system_time_end timestamptz);

/* b33_attacker has no privilege at all on b33.vt, not even SELECT. */
SET SESSION AUTHORIZATION b33_attacker;
SELECT count(*) FROM b33.vt;
SELECT periods.add_period('b33.vt', 'q', 's', 'e');
SELECT periods.add_system_time_period('b33.vt');
SELECT periods.set_system_time_period_excluded_columns('b33.vt', ARRAY['val']);
SELECT periods.add_system_versioning('b33.vt');
SELECT periods.add_for_portion_view('b33.vt', 'p');
SELECT periods.add_unique_key('b33.vt', ARRAY['id'], 'p', 'b33_stolen_k');
SELECT periods.drop_unique_key('b33.vt', 'b33_stolen_k');
SELECT periods.drop_for_portion_view('b33.vt', 'p');
SELECT periods.drop_system_versioning('b33.vt', drop_behavior => 'CASCADE', purge => true);
SELECT periods.drop_system_time_period('b33.vt');
SELECT periods.drop_period('b33.vt', 'q');

/* A foreign key puts triggers on the *referenced* table, which is the victim's. */
CREATE TABLE b33a.at (id integer, s date NOT NULL, e date NOT NULL);
SELECT periods.add_period('b33a.at', 'p', 's', 'e');
SELECT periods.add_foreign_key('b33a.at', ARRAY['id'], 'p', 'b33_vt_k', key_name => 'b33_fk');

/* add_system_versioning() adopts a matching history table and reassigns its owner. */
CREATE TABLE b33a.base (id integer PRIMARY KEY, val text);
SELECT periods.add_system_time_period('b33a.base');
SELECT periods.add_system_versioning('b33a.base', 'spoils');
SELECT relowner::regrole AS spoils_owner
FROM pg_catalog.pg_class WHERE oid = 'b33a.spoils'::regclass;

/* SET ROLE has to count: session_user here is still the superuser running the tests. */
RESET SESSION AUTHORIZATION;
SET ROLE b33_attacker;
SELECT periods.add_period('b33.vt', 'r', 's', 'e');
RESET ROLE;

/*
 * What must keep working: with REFERENCES granted the attacker may legitimately
 * reference the victim's key, and the victim may still cascade it away.
 */
SET SESSION AUTHORIZATION b33_victim;
GRANT REFERENCES ON TABLE b33.vt TO b33_attacker;
SET SESSION AUTHORIZATION b33_attacker;
SELECT periods.add_foreign_key('b33a.at', ARRAY['id'], 'p', 'b33_vt_k', key_name => 'b33_fk2');

/*
 * Naming no table at all is how drop_unique_key()'s CASCADE reaches a foreign
 * key, so it stays reachable; a role owning neither end still may not use it.
 */
SET SESSION AUTHORIZATION b33_bystander;
SELECT periods.drop_foreign_key(NULL, 'b33_fk2');
/* The owner of the referencing table may. */
SET SESSION AUTHORIZATION b33_attacker;
SELECT periods.drop_foreign_key(NULL, 'b33_fk2');
SELECT periods.add_foreign_key('b33a.at', ARRAY['id'], 'p', 'b33_vt_k', key_name => 'b33_fk3');

/* And the victim can still cascade away a key held by a table it does not own. */
SET SESSION AUTHORIZATION b33_victim;
SELECT periods.drop_unique_key('b33.vt', 'b33_vt_k', drop_behavior => 'CASCADE');
SELECT count(*) AS foreign_keys_left FROM periods.foreign_keys WHERE key_name LIKE 'b33_fk%';

RESET SESSION AUTHORIZATION;
SELECT periods.drop_system_versioning('b33a.base', drop_behavior => 'CASCADE', purge => true);
SELECT periods.drop_system_versioning('b33.vt', drop_behavior => 'CASCADE', purge => true);
DROP SCHEMA b33 CASCADE;
DROP SCHEMA b33a CASCADE;
DROP ROLE b33_victim;
DROP ROLE b33_attacker;
DROP ROLE b33_bystander;
SET ROLE TO periods_unprivileged_user;

/*
 * §3.3 follow-up: drop_for_portion_view(NULL, NULL) documents itself as "drop
 * the views everywhere", so the table argument cannot be what authorizes it.
 */

RESET ROLE;
CREATE ROLE b33_bulk;
SET ROLE TO periods_unprivileged_user;
CREATE TABLE b33_fpv (id integer PRIMARY KEY, s date NOT NULL, e date NOT NULL);
SELECT periods.add_period('b33_fpv', 'p', 's', 'e');
SELECT periods.add_for_portion_view('b33_fpv', 'p');
RESET ROLE;

SET SESSION AUTHORIZATION b33_bulk;
SELECT periods.drop_for_portion_view(NULL, NULL);
RESET SESSION AUTHORIZATION;
SELECT count(*) AS views_left FROM periods.for_portion_views WHERE table_name = 'b33_fpv'::regclass;

SET ROLE TO periods_unprivileged_user;
SELECT periods.drop_for_portion_view('b33_fpv', 'p');
DROP TABLE b33_fpv;
RESET ROLE;
DROP ROLE b33_bulk;

/*
 * §3.3 follow-up: dropping your own table has to keep working when the other
 * end of a temporal foreign key belongs to someone else.  The sql_drop event
 * trigger cleans the key up after the relation is already gone, so ownership
 * of the surviving opposite end cannot be what authorizes the cleanup.
 */

CREATE ROLE b33_p;
CREATE ROLE b33_c;
CREATE SCHEMA b33p AUTHORIZATION b33_p;
CREATE SCHEMA b33c AUTHORIZATION b33_c;
GRANT USAGE ON SCHEMA b33p TO b33_c;

SET SESSION AUTHORIZATION b33_p;
CREATE TABLE b33p.parent (id integer, s date NOT NULL, e date NOT NULL, PRIMARY KEY (id, s, e));
SELECT periods.add_period('b33p.parent', 'p', 's', 'e');
SELECT periods.add_unique_key('b33p.parent', ARRAY['id'], 'p', 'b33_puk');
GRANT REFERENCES ON TABLE b33p.parent TO b33_c;

SET SESSION AUTHORIZATION b33_c;
CREATE TABLE b33c.child (id integer, s date NOT NULL, e date NOT NULL);
SELECT periods.add_period('b33c.child', 'p', 's', 'e');
SELECT periods.add_foreign_key('b33c.child', ARRAY['id'], 'p', 'b33_puk', key_name => 'b33_cfk');
DROP TABLE b33c.child;
RESET SESSION AUTHORIZATION;
SELECT (to_regclass('b33c.child') IS NULL) AS child_dropped,
       count(*) AS foreign_keys_left
FROM periods.foreign_keys WHERE key_name = 'b33_cfk';

/* Same from the other side: the parent's owner drops the parent. */
SET SESSION AUTHORIZATION b33_c;
CREATE TABLE b33c.child (id integer, s date NOT NULL, e date NOT NULL);
SELECT periods.add_period('b33c.child', 'p', 's', 'e');
SELECT periods.add_foreign_key('b33c.child', ARRAY['id'], 'p', 'b33_puk', key_name => 'b33_cfk2');
SET SESSION AUTHORIZATION b33_p;
DROP TABLE b33p.parent;
RESET SESSION AUTHORIZATION;
SELECT (to_regclass('b33p.parent') IS NULL) AS parent_dropped,
       count(*) AS foreign_keys_left
FROM periods.foreign_keys WHERE key_name = 'b33_cfk2';

DROP SCHEMA b33p CASCADE;
DROP SCHEMA b33c CASCADE;
DROP ROLE b33_p;
DROP ROLE b33_c;
SET ROLE TO periods_unprivileged_user;

/*
 * §3.2 follow-up: the bounds check add_period() creates compares the period's
 * columns with the range type's own "less than" operator.  Pinning the
 * search_path hides that operator when it lives outside pg_catalog, so a range
 * type over a user-defined subtype could no longer get a period at all.  The
 * comparison text has to name the operator the way pg_get_constraintdef() will
 * render it back, because rename_following() re-discovers the constraint by
 * comparing the two.
 */

RESET ROLE;
CREATE SCHEMA b33ops;
GRANT USAGE ON SCHEMA b33ops TO PUBLIC;
/* the shell-type notices are rendered differently across versions */
SET client_min_messages TO warning;
CREATE TYPE b33ops.myint;
CREATE FUNCTION b33ops.myint_in(cstring) RETURNS b33ops.myint LANGUAGE internal IMMUTABLE STRICT AS 'int4in';
CREATE FUNCTION b33ops.myint_out(b33ops.myint) RETURNS cstring LANGUAGE internal IMMUTABLE STRICT AS 'int4out';
CREATE TYPE b33ops.myint (INPUT = b33ops.myint_in, OUTPUT = b33ops.myint_out, LIKE = int4);
CREATE FUNCTION b33ops.cmp(b33ops.myint, b33ops.myint) RETURNS integer LANGUAGE internal IMMUTABLE STRICT AS 'btint4cmp';
CREATE FUNCTION b33ops.lt(b33ops.myint, b33ops.myint) RETURNS boolean LANGUAGE internal IMMUTABLE STRICT AS 'int4lt';
CREATE FUNCTION b33ops.le(b33ops.myint, b33ops.myint) RETURNS boolean LANGUAGE internal IMMUTABLE STRICT AS 'int4le';
CREATE FUNCTION b33ops.eq(b33ops.myint, b33ops.myint) RETURNS boolean LANGUAGE internal IMMUTABLE STRICT AS 'int4eq';
CREATE FUNCTION b33ops.ge(b33ops.myint, b33ops.myint) RETURNS boolean LANGUAGE internal IMMUTABLE STRICT AS 'int4ge';
CREATE FUNCTION b33ops.gt(b33ops.myint, b33ops.myint) RETURNS boolean LANGUAGE internal IMMUTABLE STRICT AS 'int4gt';
CREATE OPERATOR b33ops.< (LEFTARG = b33ops.myint, RIGHTARG = b33ops.myint, FUNCTION = b33ops.lt);
CREATE OPERATOR b33ops.<= (LEFTARG = b33ops.myint, RIGHTARG = b33ops.myint, FUNCTION = b33ops.le);
CREATE OPERATOR b33ops.= (LEFTARG = b33ops.myint, RIGHTARG = b33ops.myint, FUNCTION = b33ops.eq);
CREATE OPERATOR b33ops.>= (LEFTARG = b33ops.myint, RIGHTARG = b33ops.myint, FUNCTION = b33ops.ge);
CREATE OPERATOR b33ops.> (LEFTARG = b33ops.myint, RIGHTARG = b33ops.myint, FUNCTION = b33ops.gt);
CREATE OPERATOR CLASS b33ops.myint_ops DEFAULT FOR TYPE b33ops.myint USING btree AS
    OPERATOR 1 b33ops.<, OPERATOR 2 b33ops.<=, OPERATOR 3 b33ops.=,
    OPERATOR 4 b33ops.>=, OPERATOR 5 b33ops.>,
    FUNCTION 1 b33ops.cmp(b33ops.myint, b33ops.myint);
CREATE TYPE b33ops.myrange AS RANGE (SUBTYPE = b33ops.myint);
RESET client_min_messages;

SET ROLE TO periods_unprivileged_user;
CREATE TABLE b33mt (id integer, s b33ops.myint NOT NULL, e b33ops.myint NOT NULL);
SELECT periods.add_period('b33mt', 'p', 's', 'e', 'b33ops.myrange');
SELECT pg_catalog.pg_get_constraintdef(c.oid) AS bounds_check
FROM pg_catalog.pg_constraint AS c
WHERE c.conrelid = 'b33mt'::regclass AND c.contype = 'c';

/* rename_following has to re-find it by rebuilding the same text */
ALTER TABLE b33mt RENAME CONSTRAINT b33mt_p_check TO b33mt_renamed;
SELECT bounds_check_constraint FROM periods.periods WHERE table_name = 'b33mt'::regclass;

SELECT periods.drop_period('b33mt', 'p', purge => true);
DROP TABLE b33mt;

/*
 * A range over a domain is served by the *base* type's opclass, so the operator
 * has to be looked up by the opclass's own input type; and a family whose
 * ordering operator is not spelled "<" (text_pattern_ops' "~<~") must keep the
 * bare "<" this has always emitted rather than quietly changing the constraint.
 */
CREATE DOMAIN b33_dint AS integer;
CREATE TYPE b33_dintrange AS RANGE (SUBTYPE = b33_dint);
CREATE TYPE b33_tprange AS RANGE (SUBTYPE = text, SUBTYPE_OPCLASS = text_pattern_ops);
SELECT periods._bounds_check_def('b33_dintrange'::regtype, 's', 'e') AS over_domain,
       periods._bounds_check_def('b33_tprange'::regtype, 's', 'e') AS text_pattern,
       periods._bounds_check_def('daterange'::regtype, 's', 'e') AS builtin;
CREATE TABLE b33_dt (id integer, s b33_dint NOT NULL, e b33_dint NOT NULL);
SELECT periods.add_period('b33_dt', 'p', 's', 'e', 'b33_dintrange');
SELECT periods.drop_period('b33_dt', 'p', purge => true);
DROP TABLE b33_dt;
DROP TYPE b33_tprange;
DROP TYPE b33_dintrange;
DROP DOMAIN b33_dint;

RESET ROLE;
/* the cascade list is long and its order is not ours to depend on */
SET client_min_messages TO warning;
DROP SCHEMA b33ops CASCADE;
RESET client_min_messages;
SET ROLE TO periods_unprivileged_user;

/* Rebase-review follow-up: the bounds check must use the range's own ordering
 * operator (btree strategy 1 of its subtype opclass), whatever its name, not
 * fall back to a bare '<' that may be invisible under the pinned search_path
 * or order differently than the range does. */
CREATE TYPE bugfix_patternrange AS RANGE (subtype = text, subtype_opclass = text_pattern_ops);
CREATE TABLE bc_pat (id integer, s text, e text);
SELECT periods.add_period('bc_pat', 'p', 's', 'e', range_type => 'bugfix_patternrange');
SELECT pg_catalog.pg_get_constraintdef(c.oid) AS bounds_def
FROM periods.periods AS p
JOIN pg_catalog.pg_constraint AS c ON (c.conrelid, c.conname) = (p.table_name, p.bounds_check_constraint)
WHERE p.table_name = 'bc_pat'::regclass;
/* rename_following() must rebuild the same text: renaming the constraint has
 * to be picked up, which only happens when the two derivations agree. */
ALTER TABLE bc_pat RENAME CONSTRAINT bc_pat_p_check TO bc_pat_p_check2;
SELECT p.bounds_check_constraint FROM periods.periods AS p WHERE p.table_name = 'bc_pat'::regclass;
SELECT periods.drop_period('bc_pat', 'p');
DROP TABLE bc_pat;
DROP TYPE bugfix_patternrange;

/*
 * FOR PORTION OF on a table with a temporal unique key — the standard's own
 * use case — never worked: the slices were inserted before the edited row was
 * shrunk to the portion, so the first slice overlapped the row and the unique
 * key's exclusion constraint, which is not deferrable, rejected it.  The row
 * is shrunk first now.  A child referencing the key sees only the final state
 * (its check is deferred), and a key change inside the portion that uncovers
 * it is still caught.
 */

CREATE TABLE fp_uk (id integer, val text, s integer, e integer, PRIMARY KEY (id, s, e));
SELECT periods.add_period('fp_uk', 'p', 's', 'e');
SELECT periods.add_unique_key('fp_uk', ARRAY['id'], 'p', key_name => 'fp_uk_id_p');
SELECT periods.add_for_portion_view('fp_uk', 'p');
CREATE TABLE fp_uk_child (id integer, parent_id integer, s integer, e integer);
SELECT periods.add_period('fp_uk_child', 'p', 's', 'e');
SELECT periods.add_foreign_key('fp_uk_child', ARRAY['parent_id'], 'p', 'fp_uk_id_p', key_name => 'fp_uk_child_parent_id_p');
INSERT INTO fp_uk VALUES (1, 'a', 10, 40);
INSERT INTO fp_uk_child VALUES (1, 1, 15, 35);
UPDATE fp_uk__for_portion_of_p SET val = 'b', s = 20, e = 30;
SELECT id, val, s, e FROM fp_uk ORDER BY s;
/* Re-keying the middle slice leaves the child uncovered on [20,30). */
UPDATE fp_uk__for_portion_of_p SET id = 2, s = 20, e = 30 WHERE id = 1;
SELECT id, val, s, e FROM fp_uk ORDER BY s;
SELECT periods.drop_period('fp_uk_child', 'p', 'CASCADE');
DROP TABLE fp_uk_child;
SELECT periods.drop_period('fp_uk', 'p', 'CASCADE');
DROP TABLE fp_uk;

/*
 * Temporal foreign key checks are deferred and describe the row as it was
 * written; what the table holds at COMMIT is what counts.  A batch of
 * siblings under one key with one of them uncovered is rejected whole.
 */

CREATE TABLE fkd_parent (id integer, s integer, e integer);
SELECT periods.add_period('fkd_parent', 'p', 's', 'e');
SELECT periods.add_unique_key('fkd_parent', ARRAY['id'], 'p', key_name => 'fkd_parent_id_p');
CREATE TABLE fkd_child (id integer, parent_id integer, s integer, e integer);
SELECT periods.add_period('fkd_child', 'p', 's', 'e');
SELECT periods.add_foreign_key('fkd_child', ARRAY['parent_id'], 'p', 'fkd_parent_id_p', key_name => 'fkd_child_parent_id_p');
INSERT INTO fkd_parent VALUES (1, 0, 50), (1, 50, 100);

INSERT INTO fkd_child
    SELECT g, 1, g, g + 1 FROM generate_series(1, 20) AS g
    UNION ALL SELECT 21, 1, 99, 101;
INSERT INTO fkd_child SELECT g, 1, g, g + 1 FROM generate_series(1, 20) AS g;
SELECT count(*) AS children FROM fkd_child;

BEGIN;
INSERT INTO fkd_child VALUES (40, 1, 99, 101);
DELETE FROM fkd_child WHERE id = 40;
COMMIT;
BEGIN;
UPDATE fkd_child SET parent_id = 999 WHERE id = 1;
UPDATE fkd_child SET parent_id = 1 WHERE id = 1;
COMMIT;
BEGIN;
INSERT INTO fkd_child VALUES (41, 1, 10, 11);
UPDATE fkd_child SET parent_id = 999 WHERE id = 41;
COMMIT;
SELECT count(*) AS children FROM fkd_child;

SELECT periods.drop_period('fkd_child', 'p', 'CASCADE');
DROP TABLE fkd_child;
SELECT periods.drop_period('fkd_parent', 'p', 'CASCADE');
DROP TABLE fkd_parent;

/* A unique key adopting the PRIMARY KEY keeps following column renames. */
CREATE TABLE ukpk (id integer, s integer, e integer, PRIMARY KEY (id, s, e));
SELECT periods.add_period('ukpk', 'p', 's', 'e');
SELECT periods.add_unique_key('ukpk', ARRAY['id'], 'p', key_name => 'ukpk_id_p', unique_constraint => 'ukpk_pkey');
ALTER TABLE ukpk RENAME COLUMN id TO ident;
SELECT column_names, unique_constraint FROM periods.unique_keys WHERE key_name = 'ukpk_id_p';
SELECT periods.drop_period('ukpk', 'p', 'CASCADE');
DROP TABLE ukpk;
