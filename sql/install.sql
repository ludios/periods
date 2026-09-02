CREATE EXTENSION periods CASCADE;

SELECT extversion
FROM pg_extension
WHERE extname = 'periods';

DROP ROLE periods_unprivileged_user;
CREATE ROLE periods_unprivileged_user;

/* Make tests work on PG 15+ */
GRANT CREATE ON SCHEMA public TO PUBLIC;
