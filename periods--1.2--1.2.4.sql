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

/*
 * update_portion_of() used to rebuild its row-matching WHERE clause from the
 * columns of every constraint on the table (CHECK, UNIQUE, FOREIGN KEY,
 * exclusion, and on PostgreSQL 18 the catalogued NOT NULLs).  A NULL in any
 * such column produced a "col = NULL" predicate: the central UPDATE matched
 * nothing while the pre/post slices were still inserted, silently losing the
 * edit and leaving overlapping periods.  Match on the primary key columns
 * alone, and refuse to run if they cannot all be matched by name.
 */
CREATE OR REPLACE FUNCTION periods.update_portion_of()
 RETURNS trigger
 LANGUAGE plpgsql
AS
$function$
#variable_conflict use_variable
DECLARE
    info record;
    test boolean;
    generated_columns_sql text;
    generated_columns text[];

    jnew jsonb;
    fromval jsonb;
    toval jsonb;

    jold jsonb;
    bstartval jsonb;
    bendval jsonb;

    pre_row jsonb;
    new_row jsonb;
    post_row jsonb;
    pre_assigned boolean;
    post_assigned boolean;

    where_clause text;
    missing_pk_columns bigint;

    SERVER_VERSION CONSTANT integer := current_setting('server_version_num')::integer;

    TEST_SQL CONSTANT text :=
        'VALUES (CAST(%2$L AS %1$s) < CAST(%3$L AS %1$s) AND '
        '        CAST(%3$L AS %1$s) < CAST(%4$L AS %1$s))';

    GENERATED_COLUMNS_SQL_PRE_10 CONSTANT text :=
        'SELECT array_agg(a.attname) '
        'FROM pg_catalog.pg_attribute AS a '
        'WHERE a.attrelid = $1 '
        '  AND a.attnum > 0 '
        '  AND NOT a.attisdropped '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '               WHERE _c.conrelid = a.attrelid '
        '                 AND _c.contype = ''p'' '
        '                 AND _c.conkey @> ARRAY[a.attnum]) '
        '    OR EXISTS (SELECT FROM periods.periods AS _p '
        '               WHERE (_p.table_name, _p.period_name) = (a.attrelid, ''system_time'') '
        '                 AND a.attname IN (_p.start_column_name, _p.end_column_name)))';

    GENERATED_COLUMNS_SQL_PRE_12 CONSTANT text :=
        'SELECT array_agg(a.attname) '
        'FROM pg_catalog.pg_attribute AS a '
        'WHERE a.attrelid = $1 '
        '  AND a.attnum > 0 '
        '  AND NOT a.attisdropped '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR a.attidentity <> '''' '
        '    OR EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '               WHERE _c.conrelid = a.attrelid '
        '                 AND _c.contype = ''p'' '
        '                 AND _c.conkey @> ARRAY[a.attnum]) '
        '    OR EXISTS (SELECT FROM periods.periods AS _p '
        '               WHERE (_p.table_name, _p.period_name) = (a.attrelid, ''system_time'') '
        '                 AND a.attname IN (_p.start_column_name, _p.end_column_name)))';

    GENERATED_COLUMNS_SQL_CURRENT CONSTANT text :=
        'SELECT array_agg(a.attname) '
        'FROM pg_catalog.pg_attribute AS a '
        'WHERE a.attrelid = $1 '
        '  AND a.attnum > 0 '
        '  AND NOT a.attisdropped '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR a.attidentity <> '''' '
        '    OR a.attgenerated <> '''' '
        '    OR EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '               WHERE _c.conrelid = a.attrelid '
        '                 AND _c.contype = ''p'' '
        '                 AND _c.conkey @> ARRAY[a.attnum]) '
        '    OR EXISTS (SELECT FROM periods.periods AS _p '
        '               WHERE (_p.table_name, _p.period_name) = (a.attrelid, ''system_time'') '
        '                 AND a.attname IN (_p.start_column_name, _p.end_column_name)))';

BEGIN
    /*
     * REFERENCES:
     *     SQL:2016 15.13 GR 10
     */

    /* Get the table information from this view */
    SELECT p.table_name, p.period_name,
           p.start_column_name, p.end_column_name,
           format_type(a.atttypid, a.atttypmod) AS datatype
    INTO info
    FROM periods.for_portion_views AS fpv
    JOIN periods.periods AS p ON (p.table_name, p.period_name) = (fpv.table_name, fpv.period_name)
    JOIN pg_catalog.pg_attribute AS a ON (a.attrelid, a.attname) = (p.table_name, p.start_column_name)
    WHERE fpv.view_name = TG_RELID;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'table and period information not found for view "%"', TG_RELID::regclass;
    END IF;

    jnew := row_to_json(NEW);
    fromval := jnew->info.start_column_name;
    toval := jnew->info.end_column_name;

    jold := row_to_json(OLD);
    bstartval := jold->info.start_column_name;
    bendval := jold->info.end_column_name;

    pre_row := jold;
    new_row := jnew;
    post_row := jold;

    /* Reset the period columns */
    new_row := jsonb_set(new_row, ARRAY[info.start_column_name], bstartval);
    new_row := jsonb_set(new_row, ARRAY[info.end_column_name], bendval);

    /* If the period is the only thing changed, do nothing */
    IF new_row = jold THEN
        RETURN NULL;
    END IF;

    pre_assigned := false;
    EXECUTE format(TEST_SQL, info.datatype, bstartval, fromval, bendval) INTO test;
    IF test THEN
        pre_assigned := true;
        pre_row := jsonb_set(pre_row, ARRAY[info.end_column_name], fromval);
        new_row := jsonb_set(new_row, ARRAY[info.start_column_name], fromval);
    END IF;

    post_assigned := false;
    EXECUTE format(TEST_SQL, info.datatype, bstartval, toval, bendval) INTO test;
    IF test THEN
        post_assigned := true;
        new_row := jsonb_set(new_row, ARRAY[info.end_column_name], toval::jsonb);
        post_row := jsonb_set(post_row, ARRAY[info.start_column_name], toval::jsonb);
    END IF;

    IF pre_assigned OR post_assigned THEN
        /* Don't validate foreign keys until all this is done */
        SET CONSTRAINTS ALL DEFERRED;

        /*
         * Find and remove all generated columns from pre_row and post_row.
         * SQL:2016 15.13 GR 10)b)i)
         *
         * We also remove columns that own a sequence as those are a form of
         * generated column.  We do not, however, remove columns that default
         * to nextval() without owning the underlying sequence.
         *
         * Columns belonging to a SYSTEM_TIME period are also removed.
         *
         * In addition to what the standard calls for, we also remove any
         * columns belonging to primary keys.
         */
        IF SERVER_VERSION < 100000 THEN
            generated_columns_sql := GENERATED_COLUMNS_SQL_PRE_10;
        ELSIF SERVER_VERSION < 120000 THEN
            generated_columns_sql := GENERATED_COLUMNS_SQL_PRE_12;
        ELSE
            generated_columns_sql := GENERATED_COLUMNS_SQL_CURRENT;
        END IF;

        EXECUTE generated_columns_sql
        INTO generated_columns
        USING info.table_name;

        /* There may not be any generated columns. */
        IF generated_columns IS NOT NULL THEN
            IF SERVER_VERSION < 100000 THEN
                SELECT jsonb_object_agg(e.key, e.value)
                INTO pre_row
                FROM jsonb_each(pre_row) AS e (key, value)
                WHERE e.key <> ALL (generated_columns);

                SELECT jsonb_object_agg(e.key, e.value)
                INTO post_row
                FROM jsonb_each(post_row) AS e (key, value)
                WHERE e.key <> ALL (generated_columns);
            ELSE
                pre_row := pre_row - generated_columns;
                post_row := post_row - generated_columns;
            END IF;
        END IF;
    END IF;

    /*
     * Match the old row by its primary key.  add_for_portion_view() requires
     * the table to have one and drop_protection prevents dropping it while the
     * view exists.  If any primary key column cannot be found by name in the
     * old view row (for example because it was renamed or added underneath the
     * view), refuse to guess rather than risk touching the wrong rows.
     */
    SELECT string_agg(format('%I = %L', a.attname, j.value), ' AND '),
           count(*) FILTER (WHERE j.key IS NULL)
    INTO where_clause, missing_pk_columns
    FROM pg_catalog.pg_constraint AS c
    JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
    LEFT JOIN pg_catalog.jsonb_each_text(jold) AS j ON j.key = a.attname
    WHERE c.conrelid = info.table_name
      AND c.contype = 'p';

    IF where_clause IS NULL OR missing_pk_columns > 0 THEN
        RAISE EXCEPTION 'could not match the primary key columns of table "%" in view "%"',
            info.table_name, TG_RELID::regclass;
    END IF;

    IF pre_assigned THEN
        EXECUTE format('INSERT INTO %s (%s) VALUES (%s)',
            info.table_name,
            (SELECT string_agg(quote_ident(key), ', ' ORDER BY key) FROM jsonb_each_text(pre_row)),
            (SELECT string_agg(quote_nullable(value), ', ' ORDER BY key) FROM jsonb_each_text(pre_row)));
    END IF;

    EXECUTE format('UPDATE %s SET %s WHERE %s AND %I > %L AND %I < %L',
                   info.table_name,
                   (SELECT string_agg(format('%I = %L', j.key, j.value), ', ')
                    FROM (SELECT key, value FROM jsonb_each_text(new_row)
                          EXCEPT ALL
                          SELECT key, value FROM jsonb_each_text(jold)
                         ) AS j
                   ),
                   where_clause,
                   info.end_column_name,
                   fromval,
                   info.start_column_name,
                   toval
                  );

    IF post_assigned THEN
        EXECUTE format('INSERT INTO %s (%s) VALUES (%s)',
            info.table_name,
            (SELECT string_agg(quote_ident(key), ', ' ORDER BY key) FROM jsonb_each_text(post_row)),
            (SELECT string_agg(quote_nullable(value), ', ' ORDER BY key) FROM jsonb_each_text(post_row)));
    END IF;

    RETURN NEW;
END;
$function$;
