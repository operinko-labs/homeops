"""MCP Server for WeatherFlow Tempest weather data."""

import logging
import os
from typing import Annotated, Any

from cachetools import TTLCache
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import Field
from weatherflow4py.api import WeatherFlowRestAPI

from .config import settings

logger = logging.getLogger(__name__)

# Configure security to allow Kubernetes service hostnames
security_settings = TransportSecuritySettings(
    enable_dns_rebinding_protection=False,  # Disable for internal K8s traffic
)

# Create MCP server instance
mcp = FastMCP(
    "Tempest Weather",
    stateless_http=True,  # No session persistence - prevents memory leaks
    transport_security=security_settings,
)

# Response cache
cache: TTLCache[str, Any] = TTLCache(
    maxsize=settings.cache_size,
    ttl=settings.cache_ttl,
)


def _get_api_token() -> str:
    """Get the WeatherFlow API token from environment."""
    token = settings.api_token
    if not token:
        raise ValueError(
            "WEATHERFLOW_API_TOKEN not configured. "
            "Get a token from https://tempestwx.com/settings/tokens"
        )
    return token


@mcp.tool()
async def get_stations(
    use_cache: Annotated[
        bool,
        Field(
            default=True,
            description="Whether to use cached data (default: True)",
        ),
    ] = True,
) -> dict[str, Any]:
    """Get a list of all weather stations accessible with your API token.

    This is typically the first function to call to discover available stations.
    Each station contains devices that collect weather data.

    Returns:
        Dictionary with stations list including name, location, and device info
    """
    if use_cache and "stations" in cache:
        logger.debug("Using cached station data")
        return cache["stations"]

    token = _get_api_token()
    async with WeatherFlowRestAPI(token) as api:
        stations = await api.async_get_stations()
        result = stations.to_dict()

    cache["stations"] = result
    return result


@mcp.tool()
async def get_station(
    station_id: Annotated[
        int,
        Field(description="The station ID to get information for", ge=1),
    ],
    use_cache: Annotated[
        bool,
        Field(
            default=True,
            description="Whether to use cached data (default: True)",
        ),
    ] = True,
) -> dict[str, Any]:
    """Get comprehensive details for a specific weather station.

    Includes station metadata, connected devices, and configuration settings.

    Args:
        station_id: The numeric ID of the station (from get_stations)
        use_cache: Whether to use cached data

    Returns:
        Dictionary with station metadata, devices, and settings
    """
    cache_key = f"station_{station_id}"

    if use_cache and cache_key in cache:
        logger.debug(f"Using cached station data for {station_id}")
        return cache[cache_key]

    token = _get_api_token()
    async with WeatherFlowRestAPI(token) as api:
        station = await api.async_get_station(station_id=station_id)
        result = station[0].to_dict()

    cache[cache_key] = result
    return result


@mcp.tool()
async def get_observation(
    station_id: Annotated[
        int,
        Field(description="The station ID to get observations for", ge=1),
    ],
    use_cache: Annotated[
        bool,
        Field(
            default=True,
            description="Whether to use cached data (default: True)",
        ),
    ] = True,
) -> dict[str, Any]:
    """Get the most recent weather observations from a station.

    Includes temperature, humidity, pressure, wind, precipitation,
    solar radiation, UV index, and lightning detection data.

    Args:
        station_id: The numeric ID of the station
        use_cache: Whether to use cached data

    Returns:
        Dictionary with current weather observations
    """
    cache_key = f"observation_{station_id}"

    if use_cache and cache_key in cache:
        logger.debug(f"Using cached observation data for {station_id}")
        return cache[cache_key]

    token = _get_api_token()
    async with WeatherFlowRestAPI(token) as api:
        observation = await api.async_get_observation(station_id=station_id)
        result = observation.to_dict()

    cache[cache_key] = result
    return result


@mcp.tool()
async def get_forecast(
    station_id: Annotated[
        int,
        Field(description="The station ID to get forecast for", ge=1),
    ],
    use_cache: Annotated[
        bool,
        Field(
            default=True,
            description="Whether to use cached data (default: True)",
        ),
    ] = True,
) -> dict[str, Any]:
    """Get weather forecast for a specific station.

    Includes current conditions and daily forecasts (7-10 days).
    Hourly forecasts are excluded to conserve tokens.

    Args:
        station_id: The numeric ID of the station
        use_cache: Whether to use cached data

    Returns:
        Dictionary with current conditions and forecast data
    """
    cache_key = f"forecast_{station_id}"

    if use_cache and cache_key in cache:
        logger.debug(f"Using cached forecast data for {station_id}")
        return cache[cache_key]

    token = _get_api_token()
    async with WeatherFlowRestAPI(token) as api:
        forecast = await api.async_get_forecast(station_id=station_id)
        result = forecast.to_dict()

        # Optimize response size by removing hourly data (saves tokens)
        if "forecast" in result and "hourly" in result["forecast"]:
            del result["forecast"]["hourly"]

    cache[cache_key] = result
    return result


@mcp.tool()
async def clear_cache() -> str:
    """Clear the weather data cache.

    Use this to force fresh data retrieval on next request.

    Returns:
        Confirmation message
    """
    cache.clear()
    return "Cache cleared successfully"
