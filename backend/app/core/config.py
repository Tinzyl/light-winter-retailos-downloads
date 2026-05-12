from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Light Winter Retail Platform"
    app_env: str = "development"
    database_url: str = "sqlite:///./light_winter_dev.db"
    token_bytes: int = 8
    jwt_secret: str = "change-this-light-winter-dev-secret"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 720

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


@lru_cache
def get_settings() -> Settings:
    return Settings()
