"""Prepare a fresh RDS database for the GeoLens migrations.

Alembic assumes the extensions, the `catalog` and `data` schemas and the
`geolens_reader` role already exist; without them the first revision fails with
`schema "data" does not exist`. The api image has no psql, so this runs through
asyncpg, which is already in the image's virtualenv.
"""

import asyncio
import os

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
]


async def main() -> None:
    dsn = os.environ["DATABASE_URL_OVERRIDE"].replace(
        "postgresql+asyncpg://", "postgresql://", 1
    )
    conn = await asyncpg.connect(dsn, ssl="require")
    try:
        for statement in STATEMENTS:
            await conn.execute(statement)
            print("ok:", " ".join(statement.split())[:70], flush=True)
    finally:
        await conn.close()


asyncio.run(main())
