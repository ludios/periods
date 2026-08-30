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

        /* Remove from catalog */
        DELETE FROM periods.periods AS p
        WHERE (p.table_name, p.period_name) = (table_name, period_name);

        /*
         * Delete the bounds check constraint if purging, unless a recursive
         * call already removed this period, or another period still uses the
         * same constraint (add_period adopts a matching pre-existing one).
         */
        IF FOUND AND NOT is_dropped AND purge AND NOT EXISTS (
            SELECT FROM periods.periods AS p
            WHERE (p.table_name, p.bounds_check_constraint) = (table_name, period_row.bounds_check_constraint))
        THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
                table_name, period_row.bounds_check_constraint);
        END IF;

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

    /* Remove from catalog */
    DELETE FROM periods.periods AS p
    WHERE (p.table_name, p.period_name) = (table_name, period_name);

    /*
     * Delete the bounds check constraint if purging, unless a recursive
     * call already removed this period, or another period still uses the
     * same constraint (add_period adopts a matching pre-existing one).
     */
    IF FOUND AND NOT is_dropped AND purge AND NOT EXISTS (
        SELECT FROM periods.periods AS p
        WHERE (p.table_name, p.bounds_check_constraint) = (table_name, period_row.bounds_check_constraint))
    THEN
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
            table_name, period_row.bounds_check_constraint);
    END IF;

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
    changed_row jsonb;

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
        '  AND a.attname NOT IN ($2, $3) '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR (EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '                WHERE _c.conrelid = a.attrelid '
        '                  AND _c.contype = ''p'' '
        '                  AND _c.conkey @> ARRAY[a.attnum]) '
        '        AND (a.atthasdef OR EXISTS (SELECT FROM pg_catalog.pg_type AS _t '
        '                                    WHERE _t.oid = a.atttypid '
        '                                      AND _t.typdefault IS NOT NULL))) '
        '    OR EXISTS (SELECT FROM periods.periods AS _p '
        '               WHERE (_p.table_name, _p.period_name) = (a.attrelid, ''system_time'') '
        '                 AND a.attname IN (_p.start_column_name, _p.end_column_name)))';

    GENERATED_COLUMNS_SQL_PRE_12 CONSTANT text :=
        'SELECT array_agg(a.attname) '
        'FROM pg_catalog.pg_attribute AS a '
        'WHERE a.attrelid = $1 '
        '  AND a.attnum > 0 '
        '  AND NOT a.attisdropped '
        '  AND a.attname NOT IN ($2, $3) '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR a.attidentity <> '''' '
        '    OR (EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '                WHERE _c.conrelid = a.attrelid '
        '                  AND _c.contype = ''p'' '
        '                  AND _c.conkey @> ARRAY[a.attnum]) '
        '        AND (a.atthasdef OR EXISTS (SELECT FROM pg_catalog.pg_type AS _t '
        '                                    WHERE _t.oid = a.atttypid '
        '                                      AND _t.typdefault IS NOT NULL))) '
        '    OR EXISTS (SELECT FROM periods.periods AS _p '
        '               WHERE (_p.table_name, _p.period_name) = (a.attrelid, ''system_time'') '
        '                 AND a.attname IN (_p.start_column_name, _p.end_column_name)))';

    GENERATED_COLUMNS_SQL_CURRENT CONSTANT text :=
        'SELECT array_agg(a.attname) '
        'FROM pg_catalog.pg_attribute AS a '
        'WHERE a.attrelid = $1 '
        '  AND a.attnum > 0 '
        '  AND NOT a.attisdropped '
        '  AND a.attname NOT IN ($2, $3) '
        '  AND (pg_catalog.pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) IS NOT NULL '
        '    OR a.attidentity <> '''' '
        '    OR a.attgenerated <> '''' '
        '    OR (EXISTS (SELECT FROM pg_catalog.pg_constraint AS _c '
        '                WHERE _c.conrelid = a.attrelid '
        '                  AND _c.contype = ''p'' '
        '                  AND _c.conkey @> ARRAY[a.attnum]) '
        '        AND (a.atthasdef OR EXISTS (SELECT FROM pg_catalog.pg_type AS _t '
        '                                    WHERE _t.oid = a.atttypid '
        '                                      AND _t.typdefault IS NOT NULL))) '
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
         * columns belonging to primary keys — but only if a column or domain
         * DEFAULT can regenerate them.  One without any default (say the id
         * of a temporal PRIMARY KEY (id, start, end)) cannot regenerate, so
         * the slices must keep its value.  And the period's own bound columns
         * are never removed: the slices carry freshly computed bounds, which
         * no DEFAULT could know.
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
        USING info.table_name, info.start_column_name, info.end_column_name;

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
        /*
         * Insert through jsonb_populate_record() so that arrays, composites,
         * and friends are converted from their JSON form to their real types
         * instead of being quoted as JSON text.  The explicit column list
         * keeps the stripped generated columns out of the INSERT so they
         * regenerate.  (JSON keeps no array bounds, so a non-1-based array's
         * copies are renumbered from 1.)
         */
        EXECUTE format('INSERT INTO %1$s (%2$s) SELECT %3$s FROM pg_catalog.jsonb_populate_record(NULL::%1$s, %4$L) AS r',
            info.table_name,
            (SELECT string_agg(quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(pre_row) AS u (k)),
            (SELECT string_agg('r.' || quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(pre_row) AS u (k)),
            pre_row);
    END IF;

    /*
     * Collect the changed columns and their new values.  Which columns
     * changed is still decided on the jsonb text representations, as before.
     */
    SELECT jsonb_object_agg(c.key, new_row -> c.key)
    INTO changed_row
    FROM (SELECT key, value FROM jsonb_each_text(new_row)
          EXCEPT ALL
          SELECT key, value FROM jsonb_each_text(jold)
         ) AS c;

    /*
     * Assign them from a jsonb_populate_record() of just those columns, for
     * the same complex-type reasons as the slice INSERTs around this.  Only
     * the changed columns go into the record: converting the whole row would
     * choke on unchanged columns of types whose JSON form cannot be read
     * back (hstore, for one).
     */
    EXECUTE format('UPDATE %1$s SET (%2$s) = (SELECT %3$s FROM pg_catalog.jsonb_populate_record(NULL::%1$s, %4$L) AS r) WHERE %5$s AND %6$I > %7$L AND %8$I < %9$L',
                   info.table_name,
                   (SELECT string_agg(quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(changed_row) AS u (k)),
                   (SELECT string_agg('r.' || quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(changed_row) AS u (k)),
                   changed_row,
                   where_clause,
                   info.end_column_name,
                   fromval,
                   info.start_column_name,
                   toval
                  );

    IF post_assigned THEN
        /* Same jsonb_populate_record() dance as the pre_assigned INSERT. */
        EXECUTE format('INSERT INTO %1$s (%2$s) SELECT %3$s FROM pg_catalog.jsonb_populate_record(NULL::%1$s, %4$L) AS r',
            info.table_name,
            (SELECT string_agg(quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(post_row) AS u (k)),
            (SELECT string_agg('r.' || quote_ident(k), ', ' ORDER BY k) FROM jsonb_object_keys(post_row) AS u (k)),
            post_row);
    END IF;

    RETURN NEW;
END;
$function$;

/*
 * validate_foreign_key_new_row() correlated the parent and child key columns
 * without table qualification.  With same-named columns (child.id referencing
 * parent.id), "id = id" resolved entirely to the inner uk relation - a
 * tautology - so the key filter vanished: orphans of other keys were accepted
 * and valid rows were spuriously rejected when different keys' periods
 * overlapped.  Qualify both sides.  The violation errors also now carry
 * SQLSTATE 23503 (foreign_key_violation) like native foreign keys.
 */
CREATE OR REPLACE FUNCTION periods.validate_foreign_key_new_row(foreign_key_name name, row_data jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
AS
$function$
#variable_conflict use_variable
DECLARE
    foreign_key_info record;
    row_clause text DEFAULT 'true';
    violation boolean;

	QSQL CONSTANT text :=
        'SELECT EXISTS ( '
        '    SELECT FROM %5$I.%6$I AS fk '
        '    WHERE NOT EXISTS ( '
        '        SELECT FROM (SELECT uk.uk_start_value, '
        '                            uk.uk_end_value, '
        '                            nullif(lag(uk.uk_end_value) OVER (ORDER BY uk.uk_start_value), uk.uk_start_value) AS x '
        '                     FROM (SELECT uk.%3$I AS uk_start_value, '
        '                                  uk.%4$I AS uk_end_value '
        '                           FROM %1$I.%2$I AS uk '
        '                           WHERE %9$s '
        '                             AND uk.%3$I <= fk.%8$I '
        '                             AND uk.%4$I >= fk.%7$I '
        '                           FOR KEY SHARE '
        '                          ) AS uk '
        '                    ) AS uk '
        '        WHERE uk.uk_start_value < fk.%8$I '
        '          AND uk.uk_end_value >= fk.%7$I '
        '        HAVING min(uk.uk_start_value) <= fk.%7$I '
        '           AND max(uk.uk_end_value) >= fk.%8$I '
        '           AND array_agg(uk.x) FILTER (WHERE uk.x IS NOT NULL) IS NULL '
        '    ) AND %10$s '
        ')';

BEGIN
    SELECT fc.oid AS fk_table_oid,
           fn.nspname AS fk_schema_name,
           fc.relname AS fk_table_name,
           fk.column_names AS fk_column_names,
           fp.period_name AS fk_period_name,
           fp.start_column_name AS fk_start_column_name,
           fp.end_column_name AS fk_end_column_name,

           un.nspname AS uk_schema_name,
           uc.relname AS uk_table_name,
           uk.column_names AS uk_column_names,
           up.period_name AS uk_period_name,
           up.start_column_name AS uk_start_column_name,
           up.end_column_name AS uk_end_column_name,

           fk.match_type,
           fk.update_action,
           fk.delete_action
    INTO foreign_key_info
    FROM periods.foreign_keys AS fk
    JOIN periods.periods AS fp ON (fp.table_name, fp.period_name) = (fk.table_name, fk.period_name)
    JOIN pg_catalog.pg_class AS fc ON fc.oid = fk.table_name
    JOIN pg_catalog.pg_namespace AS fn ON fn.oid = fc.relnamespace
    JOIN periods.unique_keys AS uk ON uk.key_name = fk.unique_key
    JOIN periods.periods AS up ON (up.table_name, up.period_name) = (uk.table_name, uk.period_name)
    JOIN pg_catalog.pg_class AS uc ON uc.oid = uk.table_name
    JOIN pg_catalog.pg_namespace AS un ON un.oid = uc.relnamespace
    WHERE fk.key_name = foreign_key_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'foreign key "%" not found', foreign_key_name;
    END IF;

    /*
     * Now that we have all of our names, we can see if there are any nulls in
     * the row we were given (if we were given one).
     */
    IF row_data IS NOT NULL THEN
        DECLARE
            column_name name;
            has_nulls boolean;
            all_nulls boolean;
            cols text[] DEFAULT '{}';
            vals text[] DEFAULT '{}';
        BEGIN
            FOREACH column_name IN ARRAY foreign_key_info.fk_column_names LOOP
                has_nulls := has_nulls OR row_data->>column_name IS NULL;
                all_nulls := all_nulls IS NOT false AND row_data->>column_name IS NULL;
                cols := cols || ('fk.' || quote_ident(column_name));
                vals := vals || quote_literal(row_data->>column_name);
            END LOOP;

            IF all_nulls THEN
                /*
                 * If there are no values at all, all three types pass.
                 *
                 * Period columns are by definition NOT NULL so the FULL MATCH
                 * type is only concerned with the non-period columns of the
                 * constraint.  SQL:2016 4.23.3.3
                 */
                RETURN true;
            END IF;

            IF has_nulls THEN
                CASE foreign_key_info.match_type
                    WHEN 'SIMPLE' THEN
                        RETURN true;
                    WHEN 'PARTIAL' THEN
                        RAISE EXCEPTION 'partial not implemented';
                    WHEN 'FULL' THEN
                        RAISE EXCEPTION 'foreign key violated (nulls in FULL)' USING ERRCODE = 'foreign_key_violation';
                END CASE;
            END IF;

            row_clause := format(' (%s) = (%s)', array_to_string(cols, ', '), array_to_string(vals, ', '));
        END;
    END IF;

    EXECUTE format(QSQL, foreign_key_info.uk_schema_name,
                         foreign_key_info.uk_table_name,
                         foreign_key_info.uk_start_column_name,
                         foreign_key_info.uk_end_column_name,
                         foreign_key_info.fk_schema_name,
                         foreign_key_info.fk_table_name,
                         foreign_key_info.fk_start_column_name,
                         foreign_key_info.fk_end_column_name,
                         (SELECT string_agg(format('uk.%I = fk.%I', ukc, fkc), ' AND ')
                          FROM unnest(foreign_key_info.uk_column_names,
                                      foreign_key_info.fk_column_names) AS u (ukc, fkc)
                         ),
                         row_clause)
    INTO violation;

    IF violation THEN
        IF row_data IS NULL THEN
            RAISE EXCEPTION 'foreign key violated by some row' USING ERRCODE = 'foreign_key_violation';
        ELSE
            RAISE EXCEPTION 'insert or update on table "%" violates foreign key constraint "%"',
                foreign_key_info.fk_table_oid::regclass,
                foreign_key_name USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;

    RETURN true;
END;
$function$;

/*
 * The parent-side foreign key check looked for a child whose period contained
 * the entire removed parent interval, so children lying strictly inside it
 * were silently orphaned by parent DELETEs and period-shrinking or
 * key-changing UPDATEs (github issue #27).  Re-check the affected children
 * with the same aggregated-coverage logic used on the child side.
 */
CREATE OR REPLACE FUNCTION periods.validate_foreign_key_old_row(foreign_key_name name, row_data jsonb, is_update boolean)
 RETURNS boolean
 LANGUAGE plpgsql
AS
$function$
#variable_conflict use_variable
DECLARE
    foreign_key_info record;
    column_name name;
    has_nulls boolean;
    uk_column_names text[];
    uk_column_values text[];
    fk_column_names text;
    violation boolean;
    still_matches boolean;

    QSQL CONSTANT text :=
        'SELECT EXISTS ( '
        '    SELECT FROM %1$I.%2$I AS t '
        '    WHERE ROW(%3$s) = ROW(%6$s) '
        '      AND t.%4$I <= %7$L '
        '      AND t.%5$I >= %8$L '
        '%9$s'
        ')';

    /*
     * Keep this in sync with QSQL in validate_foreign_key_new_row(); it is the
     * same aggregated-coverage test, here applied to the children of the
     * removed or updated referenced row.  No plpgsql BEGIN/EXCEPTION may be
     * used around it: these checks also run from deferred constraint triggers
     * during COMMIT, where starting a subtransaction is not allowed.
     */
    COVERAGE_SQL CONSTANT text :=
        'SELECT EXISTS ( '
        '    SELECT FROM %5$I.%6$I AS fk '
        '    WHERE NOT EXISTS ( '
        '        SELECT FROM (SELECT uk.uk_start_value, '
        '                            uk.uk_end_value, '
        '                            nullif(lag(uk.uk_end_value) OVER (ORDER BY uk.uk_start_value), uk.uk_start_value) AS x '
        '                     FROM (SELECT uk.%3$I AS uk_start_value, '
        '                                  uk.%4$I AS uk_end_value '
        '                           FROM %1$I.%2$I AS uk '
        '                           WHERE %9$s '
        '                             AND uk.%3$I <= fk.%8$I '
        '                             AND uk.%4$I >= fk.%7$I '
        '                           FOR KEY SHARE '
        '                          ) AS uk '
        '                    ) AS uk '
        '        WHERE uk.uk_start_value < fk.%8$I '
        '          AND uk.uk_end_value >= fk.%7$I '
        '        HAVING min(uk.uk_start_value) <= fk.%7$I '
        '           AND max(uk.uk_end_value) >= fk.%8$I '
        '           AND array_agg(uk.x) FILTER (WHERE uk.x IS NOT NULL) IS NULL '
        '    ) AND %10$s '
        ')';

BEGIN
    SELECT fc.oid AS fk_table_oid,
           fn.nspname AS fk_schema_name,
           fc.relname AS fk_table_name,
           fk.column_names AS fk_column_names,
           fp.period_name AS fk_period_name,
           fp.start_column_name AS fk_start_column_name,
           fp.end_column_name AS fk_end_column_name,

           uc.oid AS uk_table_oid,
           un.nspname AS uk_schema_name,
           uc.relname AS uk_table_name,
           uk.column_names AS uk_column_names,
           up.period_name AS uk_period_name,
           up.start_column_name AS uk_start_column_name,
           up.end_column_name AS uk_end_column_name,

           fk.match_type,
           fk.update_action,
           fk.delete_action
    INTO foreign_key_info
    FROM periods.foreign_keys AS fk
    JOIN periods.periods AS fp ON (fp.table_name, fp.period_name) = (fk.table_name, fk.period_name)
    JOIN pg_catalog.pg_class AS fc ON fc.oid = fk.table_name
    JOIN pg_catalog.pg_namespace AS fn ON fn.oid = fc.relnamespace
    JOIN periods.unique_keys AS uk ON uk.key_name = fk.unique_key
    JOIN periods.periods AS up ON (up.table_name, up.period_name) = (uk.table_name, uk.period_name)
    JOIN pg_catalog.pg_class AS uc ON uc.oid = uk.table_name
    JOIN pg_catalog.pg_namespace AS un ON un.oid = uc.relnamespace
    WHERE fk.key_name = foreign_key_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'foreign key "%" not found', foreign_key_name;
    END IF;

    FOREACH column_name IN ARRAY foreign_key_info.uk_column_names LOOP
        IF row_data->>column_name IS NULL THEN
            /*
             * If the deleted row had nulls in the referenced columns then
             * there was no possible referencing row (until we implement
             * PARTIAL) so we can just stop here.
             */
            RETURN true;
        END IF;
        uk_column_names := uk_column_names || ('t.' || quote_ident(column_name));
        uk_column_values := uk_column_values || quote_literal(row_data->>column_name);
    END LOOP;

    IF is_update AND foreign_key_info.update_action = 'NO ACTION' THEN
        EXECUTE format(QSQL, foreign_key_info.uk_schema_name,
                             foreign_key_info.uk_table_name,
                             array_to_string(uk_column_names, ', '),
                             foreign_key_info.uk_start_column_name,
                             foreign_key_info.uk_end_column_name,
                             array_to_string(uk_column_values, ', '),
                             row_data->>foreign_key_info.uk_start_column_name,
                             row_data->>foreign_key_info.uk_end_column_name,
                             'FOR KEY SHARE')
        INTO still_matches;

        IF still_matches THEN
            RETURN true;
        END IF;
    END IF;

    /*
     * Otherwise, every child row referencing this key must still be fully
     * covered by the remaining rows of the referenced table, so re-check the
     * affected children with the same aggregated-coverage logic that is used
     * for the child side, restricted to this key's values.  (The old code
     * here looked only for a child whose period contained the entire old
     * parent period, so children lying strictly inside it were silently
     * orphaned; github issue #27.)
     *
     * For RESTRICT this still permits changes that leave every child covered:
     * in this extension RESTRICT differs from NO ACTION only in the timing of
     * the check, per the comments in uk_update_check()/uk_delete_check().
     */
    SELECT string_agg('fk.' || quote_ident(u.c), ', ' ORDER BY u.ordinality)
    INTO fk_column_names
    FROM unnest(foreign_key_info.fk_column_names) WITH ORDINALITY AS u (c, ordinality);

    EXECUTE format(COVERAGE_SQL,
                         foreign_key_info.uk_schema_name,
                         foreign_key_info.uk_table_name,
                         foreign_key_info.uk_start_column_name,
                         foreign_key_info.uk_end_column_name,
                         foreign_key_info.fk_schema_name,
                         foreign_key_info.fk_table_name,
                         foreign_key_info.fk_start_column_name,
                         foreign_key_info.fk_end_column_name,
                         (SELECT string_agg(format('uk.%I = fk.%I', ukc, fkc), ' AND ')
                          FROM unnest(foreign_key_info.uk_column_names,
                                      foreign_key_info.fk_column_names) AS u (ukc, fkc)),
                         format('(%s) = (%s)', fk_column_names, array_to_string(uk_column_values, ', ')))
    INTO violation;

    IF violation THEN
        RAISE EXCEPTION 'update or delete on table "%" violates foreign key constraint "%" on table "%"',
            foreign_key_info.uk_table_oid::regclass,
            foreign_key_name,
            foreign_key_info.fk_table_oid::regclass
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN true;
END;
$function$;

/*
 * drop_protection guarded the system_time infinity constraint but not any
 * period's bounds CHECK constraint, so the latter could be dropped out from
 * under a period (sql/drop_protection.sql even marked that "-- fails").
 */
CREATE OR REPLACE FUNCTION periods.drop_protection()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS
$function$
#variable_conflict use_variable
DECLARE
    r record;
    table_name regclass;
    period_name name;
BEGIN
    /*
     * This function is called after the fact, so we have to just look to see
     * if anything is missing in the catalogs if we just store the name and not
     * a reg* type.
     */

    ---
    --- periods
    ---

    /* If one of our tables is being dropped, remove references to it */
    FOR table_name, period_name IN
        SELECT p.table_name, p.period_name
        FROM periods.periods AS p
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = p.table_name
        WHERE dobj.object_type = 'table'
        ORDER BY dobj.ordinality
    LOOP
        PERFORM periods.drop_period(table_name, period_name, 'CASCADE', true);
    END LOOP;

    /*
     * If a column belonging to one of our periods is dropped, we need to reject that.
     * SQL:2016 11.23 SR 6
     */
    FOR r IN
        SELECT dobj.object_identity, p.period_name
        FROM periods.periods AS p
        JOIN pg_catalog.pg_attribute AS sa ON (sa.attrelid, sa.attname) = (p.table_name, p.start_column_name)
        JOIN pg_catalog.pg_attribute AS ea ON (ea.attrelid, ea.attname) = (p.table_name, p.end_column_name)
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = p.table_name AND dobj.objsubid IN (sa.attnum, ea.attnum)
        WHERE dobj.object_type = 'table column'
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop column "%" because it is part of the period "%"',
            r.object_identity, r.period_name;
    END LOOP;

    /* Also reject dropping the rangetype */
    FOR r IN
        SELECT dobj.object_identity, p.table_name, p.period_name
        FROM periods.periods AS p
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = p.range_type
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop rangetype "%" because it is used in period "%" on table "%"',
            r.object_identity, r.period_name, r.table_name;
    END LOOP;

    ---
    --- system_time_periods
    ---

    /* Complain if the infinity CHECK constraint is missing. */
    FOR r IN
        SELECT p.table_name, p.infinity_check_constraint
        FROM periods.system_time_periods AS p
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_constraint AS c
            WHERE (c.conrelid, c.conname) = (p.table_name, p.infinity_check_constraint))
    LOOP
        RAISE EXCEPTION 'cannot drop constraint "%" on table "%" because it is used in SYSTEM_TIME period',
            r.infinity_check_constraint, r.table_name;
    END LOOP;

    /* Complain if the GENERATED ALWAYS AS ROW START/END trigger is missing. */
    FOR r IN
        SELECT p.table_name, p.generated_always_trigger
        FROM periods.system_time_periods AS p
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (p.table_name, p.generated_always_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in SYSTEM_TIME period',
            r.generated_always_trigger, r.table_name;
    END LOOP;

    /* Complain if the write_history trigger is missing. */
    FOR r IN
        SELECT p.table_name, p.write_history_trigger
        FROM periods.system_time_periods AS p
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (p.table_name, p.write_history_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in SYSTEM_TIME period',
            r.write_history_trigger, r.table_name;
    END LOOP;

    /* Complain if the TRUNCATE trigger is missing. */
    FOR r IN
        SELECT p.table_name, p.truncate_trigger
        FROM periods.system_time_periods AS p
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (p.table_name, p.truncate_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in SYSTEM_TIME period',
            r.truncate_trigger, r.table_name;
    END LOOP;

    /*
     * We can't reliably find out what a column was renamed to, so just error
     * out in this case.
     */
    FOR r IN
        SELECT stp.table_name, u.column_name
        FROM periods.system_time_periods AS stp
        CROSS JOIN LATERAL unnest(stp.excluded_column_names) AS u (column_name)
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_attribute AS a
            WHERE (a.attrelid, a.attname) = (stp.table_name, u.column_name))
    LOOP
        RAISE EXCEPTION 'cannot drop or rename column "%" on table "%" because it is excluded from SYSTEM VERSIONING',
            r.column_name, r.table_name;
    END LOOP;

    ---
    --- for_portion_views
    ---

    /* Reject dropping the FOR PORTION OF view. */
    FOR r IN
        SELECT dobj.object_identity
        FROM periods.for_portion_views AS fpv
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = fpv.view_name
        WHERE dobj.object_type = 'view'
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop view "%", call "periods.drop_for_portion_view()" instead',
            r.object_identity;
    END LOOP;

    /* Complain if the FOR PORTION OF trigger is missing. */
    FOR r IN
        SELECT fpv.table_name, fpv.period_name, fpv.view_name, fpv.trigger_name
        FROM periods.for_portion_views AS fpv
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (fpv.view_name, fpv.trigger_name))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on view "%" because it is used in FOR PORTION OF view for period "%" on table "%"',
            r.trigger_name, r.view_name, r.period_name, r.table_name;
    END LOOP;

    /* Complain if the table's primary key has been dropped. */
    FOR r IN
        SELECT fpv.table_name, fpv.period_name
        FROM periods.for_portion_views AS fpv
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_constraint AS c
            WHERE (c.conrelid, c.contype) = (fpv.table_name, 'p'))
    LOOP
        RAISE EXCEPTION 'cannot drop primary key on table "%" because it has a FOR PORTION OF view for period "%"',
            r.table_name, r.period_name;
    END LOOP;

    ---
    --- unique_keys
    ---

    /*
     * We don't need to protect the individual columns as long as we protect
     * the indexes.  PostgreSQL will make sure they stick around.
     */

    /* Complain if the indexes implementing our unique indexes are missing. */
    FOR r IN
        SELECT uk.key_name, uk.table_name, uk.unique_constraint
        FROM periods.unique_keys AS uk
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_constraint AS c
            WHERE (c.conrelid, c.conname) = (uk.table_name, uk.unique_constraint))
    LOOP
        RAISE EXCEPTION 'cannot drop constraint "%" on table "%" because it is used in period unique key "%"',
            r.unique_constraint, r.table_name, r.key_name;
    END LOOP;

    FOR r IN
        SELECT uk.key_name, uk.table_name, uk.exclude_constraint
        FROM periods.unique_keys AS uk
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_constraint AS c
            WHERE (c.conrelid, c.conname) = (uk.table_name, uk.exclude_constraint))
    LOOP
        RAISE EXCEPTION 'cannot drop constraint "%" on table "%" because it is used in period unique key "%"',
            r.exclude_constraint, r.table_name, r.key_name;
    END LOOP;

    ---
    --- foreign_keys
    ---

    /* Complain if any of the triggers are missing */
    FOR r IN
        SELECT fk.key_name, fk.table_name, fk.fk_insert_trigger
        FROM periods.foreign_keys AS fk
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (fk.table_name, fk.fk_insert_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in period foreign key "%"',
            r.fk_insert_trigger, r.table_name, r.key_name;
    END LOOP;

    FOR r IN
        SELECT fk.key_name, fk.table_name, fk.fk_update_trigger
        FROM periods.foreign_keys AS fk
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (fk.table_name, fk.fk_update_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in period foreign key "%"',
            r.fk_update_trigger, r.table_name, r.key_name;
    END LOOP;

    FOR r IN
        SELECT fk.key_name, uk.table_name, fk.uk_update_trigger
        FROM periods.foreign_keys AS fk
        JOIN periods.unique_keys AS uk ON uk.key_name = fk.unique_key
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (uk.table_name, fk.uk_update_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in period foreign key "%"',
            r.uk_update_trigger, r.table_name, r.key_name;
    END LOOP;

    FOR r IN
        SELECT fk.key_name, uk.table_name, fk.uk_delete_trigger
        FROM periods.foreign_keys AS fk
        JOIN periods.unique_keys AS uk ON uk.key_name = fk.unique_key
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_trigger AS t
            WHERE (t.tgrelid, t.tgname) = (uk.table_name, fk.uk_delete_trigger))
    LOOP
        RAISE EXCEPTION 'cannot drop trigger "%" on table "%" because it is used in period foreign key "%"',
            r.uk_delete_trigger, r.table_name, r.key_name;
    END LOOP;

    ---
    --- system_versioning
    ---

    FOR r IN
        SELECT dobj.object_identity, sv.table_name
        FROM periods.system_versioning AS sv
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = sv.history_table_name
        WHERE dobj.object_type = 'table'
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop table "%" because it is used in SYSTEM VERSIONING for table "%"',
            r.object_identity, r.table_name;
    END LOOP;

    FOR r IN
        SELECT dobj.object_identity, sv.table_name
        FROM periods.system_versioning AS sv
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.objid = sv.view_name
        WHERE dobj.object_type = 'view'
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop view "%" because it is used in SYSTEM VERSIONING for table "%"',
            r.object_identity, r.table_name;
    END LOOP;

    FOR r IN
        SELECT dobj.object_identity, sv.table_name
        FROM periods.system_versioning AS sv
        JOIN pg_catalog.pg_event_trigger_dropped_objects() WITH ORDINALITY AS dobj
                ON dobj.object_identity = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to])
        WHERE dobj.object_type = 'function'
        ORDER BY dobj.ordinality
    LOOP
        RAISE EXCEPTION 'cannot drop function "%" because it is used in SYSTEM VERSIONING for table "%"',
            r.object_identity, r.table_name;
    END LOOP;

    /*
     * Complain if a period's bounds CHECK constraint is missing.  This lives
     * at the end of the function so that the RAISE statements above keep
     * their line numbers (they appear in error CONTEXT in the tests).
     */
    FOR r IN
        SELECT p.table_name, p.period_name, p.bounds_check_constraint
        FROM periods.periods AS p
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_constraint AS c
            WHERE (c.conrelid, c.conname) = (p.table_name, p.bounds_check_constraint))
    LOOP
        RAISE EXCEPTION 'cannot drop constraint "%" on table "%" because it is used in period "%"',
            r.bounds_check_constraint, r.table_name, r.period_name;
    END LOOP;
END;
$function$;

/*
 * health_checks() never re-validated that period bound columns stay NOT NULL,
 * so ALTER COLUMN ... DROP NOT NULL let NULL bounds slip past the bounds
 * CHECK constraint (NULL is not false).
 */
CREATE OR REPLACE FUNCTION periods.health_checks()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS
$function$
#variable_conflict use_variable
DECLARE
    cmd text;
    r record;
    save_search_path text;
BEGIN
    /* Make sure that all of our tables are still persistent */
    FOR r IN
        SELECT p.table_name
        FROM periods.periods AS p
        JOIN pg_catalog.pg_class AS c ON c.oid = p.table_name
        WHERE c.relpersistence <> 'p'
    LOOP
        RAISE EXCEPTION 'table "%" must remain persistent because it has periods',
            r.table_name;
    END LOOP;

    /* And the history tables, too */
    FOR r IN
        SELECT sv.table_name
        FROM periods.system_versioning AS sv
        JOIN pg_catalog.pg_class AS c ON c.oid = sv.history_table_name
        WHERE c.relpersistence <> 'p'
    LOOP
        RAISE EXCEPTION 'history table "%" must remain persistent because it has periods',
            r.table_name;
    END LOOP;

    /* Check that our system versioning functions are still here */
    save_search_path := pg_catalog.current_setting('search_path');
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);
    FOR r IN
        SELECT *
        FROM periods.system_versioning AS sv
        CROSS JOIN LATERAL UNNEST(ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]) AS u (fn)
        WHERE NOT EXISTS (
            SELECT FROM pg_catalog.pg_proc AS p
            WHERE p.oid::regprocedure::text = u.fn
        )
    LOOP
        RAISE EXCEPTION 'cannot drop or rename function "%" because it is used in SYSTEM VERSIONING for table "%"',
            r.fn, r.table_name;
    END LOOP;
    PERFORM pg_catalog.set_config('search_path', save_search_path, true);

    /* Fix up history and for-portion objects ownership */
    FOR cmd IN
        SELECT format('ALTER %s %s OWNER TO %I',
            CASE ht.relkind
                WHEN 'r' THEN 'TABLE'
                WHEN 'v' THEN 'VIEW'
            END,
            ht.oid::regclass, t.relowner::regrole)
        FROM periods.system_versioning AS sv
        JOIN pg_class AS t ON t.oid = sv.table_name
        JOIN pg_class AS ht ON ht.oid IN (sv.history_table_name, sv.view_name)
        WHERE t.relowner <> ht.relowner

        UNION ALL

        SELECT format('ALTER VIEW %s OWNER TO %I', fpt.oid::regclass, t.relowner::regrole)
        FROM periods.for_portion_views AS fpv
        JOIN pg_class AS t ON t.oid = fpv.table_name
        JOIN pg_class AS fpt ON fpt.oid = fpv.view_name
        WHERE t.relowner <> fpt.relowner

        UNION ALL

        SELECT format('ALTER FUNCTION %s OWNER TO %I', p.oid::regprocedure, t.relowner::regrole)
        FROM periods.system_versioning AS sv
        JOIN pg_class AS t ON t.oid = sv.table_name
        JOIN pg_proc AS p ON p.oid = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]::regprocedure[])
        WHERE t.relowner <> p.proowner
    LOOP
        EXECUTE cmd;
    END LOOP;

    /* Check GRANTs */
    IF EXISTS (
        SELECT FROM pg_event_trigger_ddl_commands() AS ev_ddl
        WHERE ev_ddl.command_tag = 'GRANT')
    THEN
        FOR r IN
            SELECT *,
                   EXISTS (
                       SELECT
                       FROM pg_class AS _c
                       CROSS JOIN LATERAL aclexplode(COALESCE(_c.relacl, acldefault('r', _c.relowner))) AS _acl
                       WHERE _c.oid = objects.table_name
                         AND _acl.grantee = objects.grantee
                         AND _acl.privilege_type = 'SELECT'
                   ) AS on_base_table
            FROM (
                SELECT sv.table_name,
                       c.oid::regclass::text AS object_name,
                       c.relkind AS object_type,
                       acl.privilege_type,
                       acl.privilege_type AS base_privilege_type,
                       acl.grantee,
                       'h' AS history_or_portion
                FROM periods.system_versioning AS sv
                JOIN pg_class AS c ON c.oid IN (sv.history_table_name, sv.view_name)
                CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl

                UNION ALL

                SELECT fpv.table_name,
                       c.oid::regclass::text,
                       c.relkind,
                       acl.privilege_type,
                       acl.privilege_type,
                       acl.grantee,
                       'p' AS history_or_portion
                FROM periods.for_portion_views AS fpv
                JOIN pg_class AS c ON c.oid = fpv.view_name
                CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl

                UNION ALL

                SELECT sv.table_name,
                       p.oid::regprocedure::text,
                       'f',
                       acl.privilege_type,
                       'SELECT',
                       acl.grantee,
                       'h'
                FROM periods.system_versioning AS sv
                JOIN pg_proc AS p ON p.oid = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]::regprocedure[])
                CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
            ) AS objects
            ORDER BY object_name, object_type, privilege_type
        LOOP
            IF
                r.history_or_portion = 'h' AND
                (r.object_type, r.privilege_type) NOT IN (('r', 'SELECT'), ('v', 'SELECT'), ('f', 'EXECUTE'))
            THEN
                RAISE EXCEPTION 'cannot grant % to "%"; history objects are read-only',
                    r.privilege_type, r.object_name;
            END IF;

            IF NOT r.on_base_table THEN
                RAISE EXCEPTION 'cannot grant % directly to "%"; grant % to "%" instead',
                    r.privilege_type, r.object_name, r.base_privilege_type, r.table_name;
            END IF;
        END LOOP;

        /* Propagate GRANTs */
        FOR cmd IN
            SELECT format('GRANT %s ON %s %s TO %s',
                          string_agg(DISTINCT privilege_type, ', '),
                          object_type,
                          string_agg(DISTINCT object_name, ', '),
                          string_agg(DISTINCT COALESCE(a.rolname, 'public'), ', '))
            FROM (
                SELECT 'TABLE' AS object_type,
                       hc.oid::regclass::text AS object_name,
                       'SELECT' AS privilege_type,
                       acl.grantee
                FROM periods.system_versioning AS sv
                JOIN pg_class AS c ON c.oid = sv.table_name
                CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
                JOIN pg_class AS hc ON hc.oid IN (sv.history_table_name, sv.view_name)
                WHERE acl.privilege_type = 'SELECT'
                  AND NOT has_table_privilege(acl.grantee, hc.oid, 'SELECT')

                UNION ALL

                SELECT 'TABLE',
                       fpc.oid::regclass::text,
                       acl.privilege_type,
                       acl.grantee
                FROM periods.for_portion_views AS fpv
                JOIN pg_class AS c ON c.oid = fpv.table_name
                CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
                JOIN pg_class AS fpc ON fpc.oid = fpv.view_name
                WHERE NOT has_table_privilege(acl.grantee, fpc.oid, acl.privilege_type)

                UNION ALL

                SELECT 'FUNCTION',
                       hp.oid::regprocedure::text,
                       'EXECUTE',
                       acl.grantee
                FROM periods.system_versioning AS sv
                JOIN pg_class AS c ON c.oid = sv.table_name
                CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
                JOIN pg_proc AS hp ON hp.oid = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]::regprocedure[])
                WHERE acl.privilege_type = 'SELECT'
                  AND NOT has_function_privilege(acl.grantee, hp.oid, 'EXECUTE')
            ) AS objects
            LEFT JOIN pg_authid AS a ON a.oid = objects.grantee
            GROUP BY object_type
        LOOP
            EXECUTE cmd;
        END LOOP;
    END IF;

    /* Check REVOKEs */
    IF EXISTS (
        SELECT FROM pg_event_trigger_ddl_commands() AS ev_ddl
        WHERE ev_ddl.command_tag = 'REVOKE')
    THEN
        FOR r IN
            SELECT sv.table_name,
                   hc.oid::regclass::text AS object_name,
                   acl.privilege_type,
                   acl.privilege_type AS base_privilege_type
            FROM periods.system_versioning AS sv
            JOIN pg_class AS c ON c.oid = sv.table_name
            CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
            JOIN pg_class AS hc ON hc.oid IN (sv.history_table_name, sv.view_name)
            WHERE acl.privilege_type = 'SELECT'
              AND NOT EXISTS (
                SELECT
                FROM aclexplode(COALESCE(hc.relacl, acldefault('r', hc.relowner))) AS _acl
                WHERE _acl.privilege_type = 'SELECT'
                  AND _acl.grantee = acl.grantee)

            UNION ALL

            SELECT fpv.table_name,
                   hc.oid::regclass::text,
                   acl.privilege_type,
                   acl.privilege_type
            FROM periods.for_portion_views AS fpv
            JOIN pg_class AS c ON c.oid = fpv.table_name
            CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
            JOIN pg_class AS hc ON hc.oid = fpv.view_name
            WHERE NOT EXISTS (
                SELECT
                FROM aclexplode(COALESCE(hc.relacl, acldefault('r', hc.relowner))) AS _acl
                WHERE _acl.privilege_type = acl.privilege_type
                  AND _acl.grantee = acl.grantee)

            UNION ALL

            SELECT sv.table_name,
                   hp.oid::regprocedure::text,
                   'EXECUTE',
                   'SELECT'
            FROM periods.system_versioning AS sv
            JOIN pg_class AS c ON c.oid = sv.table_name
            CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
            JOIN pg_proc AS hp ON hp.oid = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]::regprocedure[])
            WHERE acl.privilege_type = 'SELECT'
              AND NOT EXISTS (
                SELECT
                FROM aclexplode(COALESCE(hp.proacl, acldefault('f', hp.proowner))) AS _acl
                WHERE _acl.privilege_type = 'EXECUTE'
                  AND _acl.grantee = acl.grantee)

            ORDER BY table_name, object_name
        LOOP
            RAISE EXCEPTION 'cannot revoke % directly from "%", revoke % from "%" instead',
                r.privilege_type, r.object_name, r.base_privilege_type, r.table_name;
        END LOOP;

        /* Propagate REVOKEs */
        FOR cmd IN
            SELECT format('REVOKE %s ON %s %s FROM %s',
                          string_agg(DISTINCT privilege_type, ', '),
                          object_type,
                          string_agg(DISTINCT object_name, ', '),
                          string_agg(DISTINCT COALESCE(a.rolname, 'public'), ', '))
            FROM (
                SELECT 'TABLE' AS object_type,
                       hc.oid::regclass::text AS object_name,
                       'SELECT' AS privilege_type,
                       hacl.grantee
                FROM periods.system_versioning AS sv
                JOIN pg_class AS hc ON hc.oid IN (sv.history_table_name, sv.view_name)
                CROSS JOIN LATERAL aclexplode(COALESCE(hc.relacl, acldefault('r', hc.relowner))) AS hacl
                WHERE hacl.privilege_type = 'SELECT'
                  AND NOT has_table_privilege(hacl.grantee, sv.table_name, 'SELECT')

                UNION ALL

                SELECT 'TABLE' AS object_type,
                       hc.oid::regclass::text AS object_name,
                       hacl.privilege_type,
                       hacl.grantee
                FROM periods.for_portion_views AS fpv
                JOIN pg_class AS hc ON hc.oid = fpv.view_name
                CROSS JOIN LATERAL aclexplode(COALESCE(hc.relacl, acldefault('r', hc.relowner))) AS hacl
                WHERE NOT has_table_privilege(hacl.grantee, fpv.table_name, hacl.privilege_type)

                UNION ALL

                SELECT 'FUNCTION' AS object_type,
                       hp.oid::regprocedure::text AS object_name,
                       'EXECUTE' AS privilege_type,
                       hacl.grantee
                FROM periods.system_versioning AS sv
                JOIN pg_proc AS hp ON hp.oid = ANY (ARRAY[sv.func_as_of, sv.func_between, sv.func_between_symmetric, sv.func_from_to]::regprocedure[])
                CROSS JOIN LATERAL aclexplode(COALESCE(hp.proacl, acldefault('f', hp.proowner))) AS hacl
                WHERE hacl.privilege_type = 'EXECUTE'
                  AND NOT has_table_privilege(hacl.grantee, sv.table_name, 'SELECT')
            ) AS objects
            LEFT JOIN pg_authid AS a ON a.oid = objects.grantee
            GROUP BY object_type
        LOOP
            EXECUTE cmd;
        END LOOP;
    END IF;

    /*
     * Verify that period bound columns are still NOT NULL; everything else
     * assumes they are.  This lives at the end of the function so that the
     * RAISE statements above keep their line numbers (they appear in error
     * CONTEXT in the tests).
     */
    FOR r IN
        SELECT p.table_name, p.period_name, u.column_name
        FROM periods.periods AS p
        CROSS JOIN LATERAL unnest(ARRAY[p.start_column_name, p.end_column_name]) AS u (column_name)
        JOIN pg_catalog.pg_attribute AS a ON (a.attrelid, a.attname) = (p.table_name, u.column_name)
        WHERE NOT a.attnotnull
    LOOP
        RAISE EXCEPTION 'cannot drop NOT NULL from column "%" of table "%" because it is part of the period "%"',
            r.column_name, r.table_name, r.period_name;
    END LOOP;
END;
$function$;

/*
 * truncate_system_versioning() read the history table's regclass into a
 * name-typed variable, truncating the qualified form at 63 bytes; TRUNCATE
 * then failed (or could hit an unrelated relation of the truncated name).
 */
CREATE OR REPLACE FUNCTION periods.truncate_system_versioning()
 RETURNS trigger
 LANGUAGE plpgsql
 STRICT
 SECURITY DEFINER
AS
$function$
#variable_conflict use_variable
DECLARE
    history_table_name regclass;
BEGIN
    SELECT sv.history_table_name
    INTO history_table_name
    FROM periods.system_versioning AS sv
    WHERE sv.table_name = TG_RELID;

    IF FOUND THEN
        EXECUTE format('TRUNCATE %s', history_table_name);
    END IF;

    RETURN NULL;
END;
$function$;
