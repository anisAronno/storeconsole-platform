#!/bin/sh
set -eu

psql_cmd() {
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}

create_role() {
  role_name="$1"
  role_pass="$2"
  psql_cmd <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role_name}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', '${role_name}', '${role_pass}');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', '${role_name}', '${role_pass}');
  END IF;
END
\$\$;
SQL
}

create_db_and_grants() {
  db_name="$1"
  owner_role="$2"

  psql_cmd <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db_name}') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', '${db_name}', '${owner_role}');
  END IF;
END
\$\$;
SQL

  psql_cmd <<SQL
REVOKE ALL ON DATABASE "${db_name}" FROM PUBLIC;
GRANT CONNECT, TEMP ON DATABASE "${db_name}" TO "${owner_role}";
SQL

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db_name" <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO "${owner_role}";
ALTER SCHEMA public OWNER TO "${owner_role}";
GRANT CREATE ON SCHEMA public TO "${owner_role}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${owner_role}" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${owner_role}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${owner_role}" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${owner_role}";
SQL
}

create_role "$STORECONSOLE_PROD_USER" "$STORECONSOLE_PROD_PASSWORD"
create_role "$STORECONSOLE_STAGING_USER" "$STORECONSOLE_STAGING_PASSWORD"
create_role "$STORECONSOLE_DEV_USER" "$STORECONSOLE_DEV_PASSWORD"
create_role "$PULSE_PROD_USER" "$PULSE_PROD_PASSWORD"
create_role "$PULSE_STAGING_USER" "$PULSE_STAGING_PASSWORD"
create_role "$PULSE_DEV_USER" "$PULSE_DEV_PASSWORD"

create_db_and_grants "$STORECONSOLE_PROD_DB" "$STORECONSOLE_PROD_USER"
create_db_and_grants "$STORECONSOLE_STAGING_DB" "$STORECONSOLE_STAGING_USER"
create_db_and_grants "$STORECONSOLE_DEV_DB" "$STORECONSOLE_DEV_USER"
create_db_and_grants "$PULSE_PROD_DB" "$PULSE_PROD_USER"
create_db_and_grants "$PULSE_STAGING_DB" "$PULSE_STAGING_USER"
create_db_and_grants "$PULSE_DEV_DB" "$PULSE_DEV_USER"
