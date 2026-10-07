"""Apply SQL migrations in order, once each (python -m adpulse.migrate).

Applied versions are tracked in schema_migrations. A Postgres advisory lock
stops two migrators (e.g. two deploys) from running at the same time.
"""

import json
import os
import sys
import time
from pathlib import Path

import psycopg

from .config import Settings

LOCK_ID = 7_272_001
DEFAULT_DIR = Path(__file__).resolve().parent.parent / "migrations"


def emit(event: str, **fields) -> None:
    print(json.dumps({"event": event, **fields}), flush=True)


def connect(settings: Settings, wait_seconds: float) -> psycopg.Connection:
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            return psycopg.connect(settings.db_conninfo, autocommit=True)
        except psycopg.OperationalError as exc:
            if time.monotonic() >= deadline:
                raise
            emit("waiting_for_db", error=type(exc).__name__)
            time.sleep(2)


def migrate(settings: Settings, migrations_dir: Path, wait_seconds: float = 60) -> list[str]:
    files = sorted(migrations_dir.glob("*.sql"))
    if not files:
        raise SystemExit(f"no migrations found in {migrations_dir}")
    applied_now: list[str] = []
    with connect(settings, wait_seconds) as conn:
        conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_ID,))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations "
                "(version text PRIMARY KEY, applied_at timestamptz DEFAULT now())"
            )
            done = {r[0] for r in conn.execute("SELECT version FROM schema_migrations").fetchall()}
            for f in files:
                version = f.stem
                if version in done:
                    emit("skip", version=version)
                    continue
                with conn.transaction():
                    conn.execute(f.read_text())
                    conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (version,))
                applied_now.append(version)
                emit("applied", version=version)
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_ID,))
    emit("done", applied=applied_now)
    return applied_now


def main() -> int:
    settings = Settings()
    migrations_dir = Path(os.environ.get("MIGRATIONS_DIR", DEFAULT_DIR))
    try:
        migrate(settings, migrations_dir, float(os.environ.get("MIGRATE_WAIT_SECONDS", "60")))
    except Exception as exc:
        emit("failed", error=f"{type(exc).__name__}: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
