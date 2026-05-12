from fastapi import FastAPI

from app.api.routes import router
from app.core.database import Base, engine

Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="Light Winter Technologies Retail API",
    version="0.1.0",
    description="Activation, licensing, sync, inventory, POS, and fiscal orchestration backend.",
)
app.include_router(router, prefix="/api")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "brand": "Light Winter Technologies"}
