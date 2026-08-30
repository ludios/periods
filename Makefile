MODULES = periods
EXTENSION = periods
DOCS = README.periods

DATA = periods--1.0.sql \
	   periods--1.0--1.1.sql \
	   periods--1.1.sql \
	   periods--1.1--1.2.sql \
	   periods--1.2.sql \
	   periods--1.2--1.2.4.sql \
	   periods--1.2.4.sql

EXTRA_CLEAN = periods--1.2.4.sql

REGRESS = install \
		  periods \
		  system_time_periods \
		  system_versioning \
		  excluded_columns \
		  unique_foreign \
		  for_portion_of \
		  predicates \
		  drop_protection \
		  rename_following \
		  health_checks \
		  acl \
		  issues \
		  beeswax \
		  bugfixes \
		  uninstall

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Full install script for 1.2.4, so that servers older than PostgreSQL 10
# (which cannot install a version by chaining update scripts) can still
# CREATE EXTENSION.  The later CREATE OR REPLACEs override the 1.2 bodies.
periods--1.2.4.sql: periods--1.2.sql periods--1.2--1.2.4.sql
	cat $^ > $@

all: periods--1.2.4.sql
install: periods--1.2.4.sql
