"""Runtime configuration from environment variables (plan Section 9)."""

from psycopg.conninfo import make_conninfo
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False, extra="ignore")

    app_env: str = "dev"
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "adpulse"
    db_user: str = "adpulse"
    db_password: str = ""
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str = ""
    cache_ttl_seconds: int = 60
    chaos_enabled: bool = False
    chaos_token: str = ""
    git_sha: str = "dev"
    log_level: str = "INFO"
    broken_release: bool = False

    # Internal tuning (not in the plan's list; defaults keep the serving path
    # well inside nginx's 2s upstream timeout even when dependencies hang).
    db_timeout_seconds: float = Field(default=0.5, gt=0)
    redis_timeout_seconds: float = Field(default=0.2, gt=0)
    db_pool_max_size: int = Field(default=5, ge=1)
    impression_queue_size: int = Field(default=1000, ge=1)

    @property
    def db_conninfo(self) -> str:
        return make_conninfo(
            host=self.db_host,
            port=self.db_port,
            dbname=self.db_name,
            user=self.db_user,
            password=self.db_password,
            connect_timeout=2,
            application_name="adpulse-api",
        )
