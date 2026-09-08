-- setup.sql
--
-- Creates the bl8 database and two least-privilege roles. Does NOT create
-- links/click_events/users/status_checks — ui/ owns that schema and applies
-- it itself (`pnpm exec drizzle-kit push`). This only creates the database
-- and the two roles apps connect as: ui/ (owns everything, runs migrations)
-- and redirect/ (SELECT on links, INSERT on click_events only — matching
-- what handler/redirect.go and internal/linkcache/linkstore.go actually do).
--
-- Run with psql, passing five variables (db/role names and two freshly
-- generated passwords):
--
--   sudo -u postgres psql -v ON_ERROR_STOP=1 \
--     -v db_name=bl8 \
--     -v ui_role=bl8_ui \
--     -v redirect_role=bl8_redirect \
--     -v ui_password="$(openssl rand -base64 24)" \
--     -v redirect_password="$(openssl rand -base64 24)" \
--     -f setup.sql
--
-- Safe to re-run: existing roles get their password reset instead of
-- erroring, and grants are idempotent.
--
-- IMPORTANT: psql's :'name'/:"name" variable substitution does NOT happen
-- inside DO $$ ... $$ dollar-quoted bodies — psql treats dollar-quoting as
-- a protected literal region, same as single quotes, so this file avoids
-- DO blocks entirely wherever a variable needs to appear. Instead it uses
-- the \gexec pattern throughout: build the target statement as a string
-- with a plain SELECT (where substitution works normally), then execute
-- whatever that SELECT produced. A WHERE clause that matches zero rows
-- means \gexec has nothing to run — a clean, error-free no-op, which is
-- also how the "skip if it already exists" / "skip if the table doesn't
-- exist yet" conditions below are implemented.

\set ON_ERROR_STOP on

-- Postgres has no CREATE DATABASE IF NOT EXISTS, so build and run it
-- conditionally.
SELECT 'CREATE DATABASE ' || quote_ident(:'db_name')
WHERE NOT EXISTS (
	SELECT FROM pg_database WHERE datname = :'db_name'
)\gexec

-- Create or update each role's password, whichever applies.
SELECT CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'ui_role')
	THEN 'ALTER ROLE ' || quote_ident(:'ui_role') || ' PASSWORD ' || quote_literal(:'ui_password')
	ELSE 'CREATE ROLE ' || quote_ident(:'ui_role') || ' LOGIN PASSWORD ' || quote_literal(:'ui_password')
END\gexec

SELECT CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'redirect_role')
	THEN 'ALTER ROLE ' || quote_ident(:'redirect_role') || ' PASSWORD ' || quote_literal(:'redirect_password')
	ELSE 'CREATE ROLE ' || quote_ident(:'redirect_role') || ' LOGIN PASSWORD ' || quote_literal(:'redirect_password')
END\gexec

GRANT ALL PRIVILEGES ON DATABASE :"db_name" TO :"ui_role";
ALTER DATABASE :"db_name" OWNER TO :"ui_role";

\connect :db_name

-- links/click_events don't exist yet on a fresh run — ALTER DEFAULT
-- PRIVILEGES makes redirect/'s grants apply automatically the moment ui/
-- runs its migration, with no second manual step needed afterward.
GRANT CONNECT ON DATABASE :"db_name" TO :"redirect_role";
GRANT USAGE ON SCHEMA public TO :"redirect_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"ui_role" IN SCHEMA public
	GRANT SELECT ON TABLES TO :"redirect_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"ui_role" IN SCHEMA public
	GRANT INSERT ON TABLES TO :"redirect_role";

-- If the schema already exists (re-running this after ui/'s migration
-- already ran), grant on what's there right now too. Safe even with zero
-- tables — GRANT ... ON ALL TABLES IN SCHEMA is a no-op, not an error, when
-- there are no tables yet.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"redirect_role";

-- Narrow click_events back down to INSERT-only for redirect/ (the blanket
-- SELECT above is the simplest way to cover "whatever tables exist right
-- now"; redirect/ never reads click_events). Only runs if click_events
-- actually exists yet — a plain REVOKE/GRANT on a nonexistent table would
-- error, so these are built conditionally via \gexec instead.
SELECT 'REVOKE SELECT ON click_events FROM ' || quote_ident(:'redirect_role')
WHERE EXISTS (
	SELECT FROM information_schema.tables
	WHERE table_schema = 'public' AND table_name = 'click_events'
)\gexec

SELECT 'GRANT INSERT ON click_events TO ' || quote_ident(:'redirect_role')
WHERE EXISTS (
	SELECT FROM information_schema.tables
	WHERE table_schema = 'public' AND table_name = 'click_events'
)\gexec
