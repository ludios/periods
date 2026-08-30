-- Model-output: Claude Fable 5
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
