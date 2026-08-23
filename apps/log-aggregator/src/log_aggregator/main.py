"""FastAPI application entry point."""

import contextlib
import logging
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException
from fastapi.routing import Mount
from sqlalchemy.ext.asyncio import AsyncSession

from . import __version__
from .clients import KubernetesClient, LokiClient, PrometheusClient
from .config import settings
from .database import get_session, init_db
from .mcp_server import mcp, security_settings
from .models import (
    AlertContextResponse,
    AlertmanagerWebhook,
    DailySummaryResponse,
    HealthResponse,
)
from .services import AlertService

# Configure logging
logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Clients (singleton)
loki_client = LokiClient()
prometheus_client = PrometheusClient()
kubernetes_client = KubernetesClient()

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    logger.info("Starting Log Aggregator...")
    await init_db()
    logger.info("Database initialized")
    # Start MCP session manager
    async with mcp.session_manager.run():
        logger.info("MCP server initialized")
        yield
    logger.info("Shutting down Log Aggregator...")
    await loki_client.close()
    await prometheus_client.close()
    await kubernetes_client.close()


app = FastAPI(
    title="Log Aggregator",
    description="Middleware for aggregating Kubernetes logs and alerts for LLM summarization",
    version=__version__,
    lifespan=lifespan,
)

# Mount MCP server at /mcp (transport options moved here from the
# constructor in mcp 2.0; path "/" puts the endpoint at the mount root)
app.mount(
    "/mcp",
    mcp.streamable_http_app(
        stateless_http=True,
        streamable_http_path="/",
        transport_security=security_settings,
    ),
)


# Dependencies
async def get_alert_service(
    session: Annotated[AsyncSession, Depends(get_session)],
) -> AlertService:
    """Get AlertService instance with dependencies."""
    return AlertService(
        session=session,
        loki=loki_client,
        prometheus=prometheus_client,
        kubernetes=kubernetes_client,
    )


@app.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """Health check endpoint."""
    loki_status = "ok" if await loki_client.health_check() else "error"
    prometheus_status = "ok" if await prometheus_client.health_check() else "error"

    # Database check is implicit - if we get here, DB is working
    return HealthResponse(
        status="ok",
        version=__version__,
        database="ok",
        loki=loki_status,
        prometheus=prometheus_status,
    )


@app.post("/api/alert", response_model=list[AlertContextResponse])
async def receive_alert(
    webhook: AlertmanagerWebhook,
    service: Annotated[AlertService, Depends(get_alert_service)],
) -> list[AlertContextResponse]:
    """Receive Alertmanager webhook and collect context."""
    logger.info(f"Received webhook with {len(webhook.alerts)} alerts")

    try:
        contexts = await service.process_webhook(webhook)
        logger.info(f"Processed {len(contexts)} alert contexts")
        return [AlertContextResponse.model_validate(c) for c in contexts]
    except Exception as e:
        logger.error(f"Error processing webhook: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/daily-summary", response_model=DailySummaryResponse)
async def get_daily_summary(
    service: Annotated[AlertService, Depends(get_alert_service)],
    date: str | None = None,
) -> DailySummaryResponse:
    """Get daily summary of alerts for n8n workflow."""
    try:
        target_date = datetime.fromisoformat(date) if date else None
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

    summary = await service.get_daily_summary(target_date)
    return DailySummaryResponse(
        date=summary["date"],
        total_alerts=summary["total_alerts"],
        alerts_by_severity=summary["alerts_by_severity"],
        alerts_by_namespace=summary["alerts_by_namespace"],
        alerts=[AlertContextResponse.model_validate(a) for a in summary["alerts"]],
    )


@app.post("/api/complete")
async def mark_day_complete(
    service: Annotated[AlertService, Depends(get_alert_service)],
    date: str | None = None,
) -> dict[str, Any]:
    """Mark a day as complete and delete processed alerts.

    Called by n8n after successfully completing a workflow run.
    Deletes all alerts for the specified day (or today if not specified).
    """
    try:
        target_date = datetime.fromisoformat(date) if date else None
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")

    deleted = await service.mark_day_complete(target_date)
    target = target_date.strftime("%Y-%m-%d") if target_date else datetime.now().strftime("%Y-%m-%d")
    logger.info(f"Day {target} marked complete, deleted {deleted} alerts")
    return {"date": target, "deleted": deleted, "status": "complete"}


@app.post("/api/cleanup")
async def cleanup_old_alerts(
    service: Annotated[AlertService, Depends(get_alert_service)],
) -> dict[str, Any]:
    """Cleanup old alert contexts."""
    deleted = await service.cleanup_old_alerts()
    return {"deleted": deleted, "retention_days": settings.alert_retention_days}


def main() -> None:
    """Run the application."""
    import uvicorn

    uvicorn.run(
        "log_aggregator.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
    )


if __name__ == "__main__":
    main()

