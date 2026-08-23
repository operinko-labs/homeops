"""FastAPI application entry point for Tempest MCP Server."""

import logging
import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request

from . import __version__
from .config import settings
from .mcp_server import mcp, security_settings

# Configure logging
logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    logger.info(f"Starting Tempest MCP Server v{__version__}...")
    # Start MCP session manager
    async with mcp.session_manager.run():
        logger.info("MCP server initialized")
        yield
    logger.info("Shutting down Tempest MCP Server...")



class N8nValidationFixMiddleware:
    """
    Pure ASGI Middleware to fix n8n MCP client requests and log incoming traffic.

    Replaces BaseHTTPMiddleware which crashes with SSE streaming (RuntimeError).
    Intercepts `initialize` requests to inject missing `clientInfo.version`.
    """
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # Simple request logging
        if scope["path"] != "/healthz":
            logger.info(f"Incoming Request Request: {scope['method']} {scope['path']}")

        # Only intercept POST /mcp for patching
        if scope["method"] == "POST" and scope["path"].rstrip("/") == "/mcp":
            try:
                # We need to read the full body to patch it
                body_chunks = []
                more_body = True

                # We interpret the first receive() call chain
                async def read_original_body():
                    nonlocal more_body
                    while more_body:
                        msg = await receive()
                        body_chunks.append(msg.get("body", b""))
                        more_body = msg.get("more_body", False)
                        if msg["type"] == "http.disconnect":
                            raise RuntimeError("Client disconnected during body read")

                await read_original_body()
                full_body = b"".join(body_chunks)

                # Attempt to patch
                try:
                    data = json.loads(full_body)
                    if (
                        isinstance(data, dict)
                        and data.get("method") == "initialize"
                        and "params" in data
                        and "clientInfo" in data["params"]
                        and "version" not in data["params"]["clientInfo"]
                    ):
                        logger.warning("Patching missing clientInfo.version for n8n compatibility")
                        data["params"]["clientInfo"]["version"] = "1.0.0"
                        full_body = json.dumps(data).encode("utf-8")
                except Exception:
                    pass

                # Create a new receive loop that sends our body first, then listens for disconnects
                body_sent = False

                async def new_receive():
                    nonlocal body_sent
                    if not body_sent:
                        body_sent = True
                        return {
                            "type": "http.request",
                            "body": full_body,
                            "more_body": False
                        }
                    return await receive()

                await self.app(scope, new_receive, send)
                return

            except Exception as e:
                logger.error(f"Error in validation middleware: {e}")
                # Fallback to original handling if something breaks
                await self.app(scope, receive, send)
                return

        # Normal handling for other routes
        await self.app(scope, receive, send)


app = FastAPI(
    title="Tempest MCP Server",
    description="MCP Server for WeatherFlow Tempest weather data",
    version=__version__,
    lifespan=lifespan,
)

# Add middleware
app.add_middleware(N8nValidationFixMiddleware)



@app.get("/healthz")
async def health_check() -> dict:
    """Health check endpoint."""
    return {
        "status": "ok",
        "version": __version__,
    }


@app.get("/")
async def root() -> dict:
    """Root endpoint with server info."""
    return {
        "name": "Tempest MCP Server",
        "version": __version__,
        "mcp_endpoint": "/mcp",
        "health_endpoint": "/healthz",
    }


# Mount MCP server at root (it handles /mcp path internally)
# MUST be mounted after other routes to avoid capturing them (since root matching catches everything)
# Transport options moved here from the constructor in mcp 2.0
app.mount(
    "/",
    mcp.streamable_http_app(
        stateless_http=True,
        streamable_http_path="/mcp",
        transport_security=security_settings,
    ),
)


def main() -> None:
    """Run the application."""
    import uvicorn

    uvicorn.run(
        "tempest_mcp.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
    )


if __name__ == "__main__":
    main()
