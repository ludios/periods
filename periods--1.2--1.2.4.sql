-- Model-output: Claude Fable 5
/* periods--1.2--1.2.4.sql: bug fixes on top of the 1.2 schema (no catalog changes) */

/*
 * drop_period() used to DELETE from periods.system_time_periods filtering on
 * table_name alone, so dropping an application-time period also tore down the
 * system_time period' triggers and infinity constraint, silently breaking
 * SYSTEM VERSIONING.  Filter on the period name too.
 */
CREATE OR REPLACE FUNCTION periods.drop_period(table_name regclass, period_name name, drop_behavior periods.drop_behavior DEFAULT 'RESTRICT', purge boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS
$function$
#variable_conflict use_variable
DECLARE
    period_row periods.periods;
    system_time_period_row periods.system_time_periods;
    system_versioning_row periods.system_versioning;
    portion_view regclass;
    is_dropped boolean;
BEGIN
    IF table_name IS NULL THEN
        RAISE EXCEPTION 'no table name specified';
    END IF;

    IF period_name IS NULL THEN
        RAISE EXCEPTION 'no period name specified';
    END IF;

    /* Always serialize operations on our catalogs */
    PERFORM periods._serialize(table_name);

    /*
     * Has the table been dropped already?  This could happen if the period is
     * being dropped by the drop_protection event trigger or through a DROP
     * CASCADE.
     */
    is_dropped := NOT EXISTS (SELECT FROM pg_catalog.pg_class AS c WHERE c.oid = table_name);

    SELECT p.*
    INTO period_row
    FROM periods.periods AS p
    WHERE (p.table_name, p.period_name) = (table_name, period_name);

    IF NOT FOUND THEN
        RAISE NOTICE 'period % not found on table %', period_name, table_name;
        RETURN false;
    END IF;

    /* Drop the "for portion" view if it hasn't been dropped already */
    PERFORM periods.drop_for_portion_view(table_name, period_name, drop_behavior, purge);

    /* If this is a system_time period, get rid of the triggers */
    DELETE FROM periods.system_time_periods AS stp
    WHERE (stp.table_name, stp.period_name) = (table_name, period_name)
    RETURNING stp.* INTO system_time_period_row;

    IF FOUND AND NOT is_dropped THEN
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', table_name, system_time_period_row.infinity_check_constraint);
        EXECUTE format('DROP TRIGGER %I ON %s', system_time_period_row.generated_always_trigger, table_name);
        EXECUTE format('DROP TRIGGER %I ON %s', system_time_period_row.write_history_trigger, table_name);
        EXECUTE format('DROP TRIGGER %I ON %s', system_time_period_row.truncate_trigger, table_name);
    END IF;

    IF drop_behavior = 'RESTRICT' THEN
        /* Check for UNIQUE or PRIMARY KEYs */
        IF EXISTS (
            SELECT FROM periods.unique_keys AS uk
            WHERE (uk.table_name, uk.period_name) = (table_name, period_name))
        THEN
            RAISE EXCEPTION 'period % is part of a UNIQUE or PRIMARY KEY', period_name;
        END IF;

        /* Check for FOREIGN KEYs */
        IF EXISTS (
            SELECT FROM periods.foreign_keys AS fk
            WHERE (fk.table_name, fk.period_name) = (table_name, period_name))
        THEN
            RAISE EXCEPTION 'period % is part of a FOREIGN KEY', period_name;
        END IF;

        /* Check for SYSTEM VERSIONING */
        IF EXISTS (
            SELECT FROM periods.system_versioning AS sv
            WHERE (sv.table_name, sv.period_name) = (table_name, period_name))
        THEN
            RAISE EXCEPTION 'table % has SYSTEM VERSIONING', table_name;
        END IF;

        /* Delete bounds check constraint if purging */
        IF NOT is_dropped AND purge THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
                table_name, period_row.bounds_check_constraint);
        END IF;

        /* Remove from catalog */
        DELETE FROM periods.periods AS p
        WHERE (p.table_name, p.period_name) = (table_name, period_name);

        RETURN true;
    END IF;

    /* We must be in CASCADE mode now */

    PERFORM periods.drop_foreign_key(table_name, fk.key_name)
    FROM periods.foreign_keys AS fk
    WHERE (fk.table_name, fk.period_name) = (table_name, period_name);

    PERFORM periods.drop_unique_key(table_name, uk.key_name, drop_behavior, purge)
    FROM periods.unique_keys AS uk
    WHERE (uk.table_name, uk.period_name) = (table_name, period_name);

    /*
     * Save ourselves the NOTICE if this table doesn't have SYSTEM
     * VERSIONING.
     *
     * We don't do like above because the purge is different.  We don't want
     * dropping SYSTEM VERSIONING to drop our infinity constraint; only
     * dropping the PERIOD should do that.
     */
    IF EXISTS (
        SELECT FROM periods.system_versioning AS sv
        WHERE (sv.table_name, sv.period_name) = (table_name, period_name))
    THEN
        PERFORM periods.drop_system_versioning(table_name, drop_behavior, purge);
    END IF;

    /* Delete bounds check constraint if purging */
    IF NOT is_dropped AND purge THEN
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
            table_name, period_row.bounds_check_constraint);
    END IF;

    /* Remove from catalog */
    DELETE FROM periods.periods AS p
    WHERE (p.table_name, p.period_name) = (table_name, period_name);

    RETURN true;
END;
$function$;
