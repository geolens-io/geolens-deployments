"""Prepare a fresh Flexible Server database for the GeoLens migrations.

Alembic assumes the extensions, the `catalog` and `data` schemas and the
`geolens_reader` role already exist; without them the first revision fails with
`schema "data" does not exist`. The api image has no psql, so this runs through
asyncpg, which is already in the image's virtualenv. The four extensions must be
in the server's azure.extensions allow-list first, which data.tf sets.

The Flexible Server administrator is not a superuser, so it also lends the
tenant provisioner role the two privileges GeoLens' RUNBOOK (step 2b) gives a
non-superuser migrator: migrations 0019 and 0024 hand that role ownership of
the tenant boundary functions, which PostgreSQL refuses unless the role may
CREATE in `catalog` and the caller may SET ROLE to it. `--hand-back` takes both
back afterwards (RUNBOOK step 2g), so neither outlives the migration.
"""

import asyncio
import os
import sys

import asyncpg

STATEMENTS = [
    "CREATE EXTENSION IF NOT EXISTS postgis",
    "CREATE EXTENSION IF NOT EXISTS pg_trgm",
    "CREATE EXTENSION IF NOT EXISTS vector",
    "CREATE EXTENSION IF NOT EXISTS unaccent",
    "CREATE SCHEMA IF NOT EXISTS catalog",
    "CREATE SCHEMA IF NOT EXISTS data",
    """
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'geolens_reader') THEN
            CREATE ROLE geolens_reader NOLOGIN;
        END IF;
    END
    $$
    """,
    "GRANT USAGE ON SCHEMA data TO geolens_reader",
    "GRANT SELECT ON ALL TABLES IN SCHEMA data TO geolens_reader",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA data GRANT SELECT ON TABLES TO geolens_reader",
    # On a fresh database 0019 creates this role and then re-owns the functions
    # in the same step, so it has to exist beforehand to be lent anything. These
    # are the attributes 0019 checks an existing role for.
    """
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'geolens_tenant_provisioner') THEN
            CREATE ROLE geolens_tenant_provisioner NOLOGIN NOSUPERUSER NOCREATEDB
                CREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
        END IF;
    END
    $$
    """,
    "GRANT CREATE ON SCHEMA catalog TO geolens_tenant_provisioner",
    "GRANT geolens_tenant_provisioner TO CURRENT_USER WITH INHERIT TRUE, SET TRUE",
]

HAND_BACK = [
    "REVOKE CREATE ON SCHEMA catalog FROM geolens_tenant_provisioner",
    "REVOKE geolens_tenant_provisioner FROM CURRENT_USER",
]


async def main() -> None:
    dsn = os.environ["DATABASE_URL_OVERRIDE"].replace(
        "postgresql+asyncpg://", "postgresql://", 1
    )
    conn = await asyncpg.connect(dsn, ssl="require")
    try:
        for statement in HAND_BACK if "--hand-back" in sys.argv else STATEMENTS:
            await conn.execute(statement)
            print("ok:", " ".join(statement.split())[:70], flush=True)
    finally:
        await conn.close()


asyncio.run(main())
