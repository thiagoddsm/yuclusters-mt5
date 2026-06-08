import asyncio
import logging
import sys
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Set, Dict, Any, Optional

# Add project root to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from config import settings
from backend.aggregator import Aggregator
from backend.mt5_collector import MT5Collector

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("server")

# Shared state
aggregator = Aggregator(tick_size=1.0)
active_connections: Set[WebSocket] = set()
collector_task: Optional[asyncio.Task] = None

def broadcast_update(active_json: dict, closed_json: Optional[dict]):
    """
    Callback executed by MT5Collector on every live tick.
    Always broadcasts the active cluster state so the frontend updates in real-time.
    closed_json is None between cluster closes — frontend handles that gracefully.
    """
    if not active_connections:
        return
    message = {
        "type": "tick",
        "active": active_json,
        "closed": closed_json
    }
    async def safe_send(ws: WebSocket, msg: dict):
        try:
            await ws.send_json(msg)
        except Exception:
            active_connections.discard(ws)
    for connection in list(active_connections):
        asyncio.create_task(safe_send(connection, message))

def broadcast_history_ready():
    """Notify all clients that historical replay is complete — they should refetch /history."""
    if not active_connections:
        return
    async def _send():
        for ws in list(active_connections):
            try:
                await ws.send_json({"type": "history_ready"})
            except Exception:
                active_connections.discard(ws)
    asyncio.create_task(_send())

# Initialize MT5 Collector
collector = MT5Collector(aggregator, on_update_callback=broadcast_update, on_history_ready_callback=broadcast_history_ready)

async def _start_collector_delayed():
    """Wait a moment for the server to fully start, then begin polling MT5."""
    await asyncio.sleep(1)
    logger.info("Starting MT5 collector background task...")
    await collector.start()

@asynccontextmanager
async def lifespan(app: FastAPI):
    global collector_task
    # Fire-and-forget: start collector AFTER yielding so uvicorn is ready
    collector_task = asyncio.create_task(_start_collector_delayed())
    logger.info("Server is starting up...")
    yield
    # Shutdown
    logger.info("Stopping MT5 collector task...")
    collector.running = False
    collector_task.cancel()
    try:
        await collector_task
    except asyncio.CancelledError:
        pass
    await collector.disconnect_mt5()

app = FastAPI(title="YuClusters Local Server", lifespan=lifespan)

# Add CORS Middleware so local frontend can query history
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class ConfigUpdate(BaseModel):
    close_mode: Optional[str] = None
    delta_max: Optional[float] = None
    volume_max: Optional[float] = None
    range_points: Optional[float] = None
    time_seconds: Optional[float] = None

@app.get("/config")
async def get_config():
    return {
        "close_mode": settings.CLUSTER_CLOSE_MODE,
        "delta_max": settings.CLUSTER_DELTA_MAX,
        "volume_max": settings.CLUSTER_VOLUME_MAX,
        "range_points": settings.CLUSTER_RANGE_POINTS,
        "time_seconds": settings.CLUSTER_TIME_SECONDS,
    }

@app.post("/config")
async def update_config(update: ConfigUpdate):
    if update.close_mode is not None:
        settings.CLUSTER_CLOSE_MODE = update.close_mode
    if update.delta_max is not None:
        settings.CLUSTER_DELTA_MAX = update.delta_max
    if update.volume_max is not None:
        settings.CLUSTER_VOLUME_MAX = update.volume_max
    if update.range_points is not None:
        settings.CLUSTER_RANGE_POINTS = update.range_points
    if update.time_seconds is not None:
        settings.CLUSTER_TIME_SECONDS = update.time_seconds
    logger.info(f"Config updated: mode={settings.CLUSTER_CLOSE_MODE}, delta_max={settings.CLUSTER_DELTA_MAX}")
    return {"ok": True}

@app.get("/history")
async def get_history():
    """Returns the buffer of historical closed clusters."""
    return aggregator.history

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    active_connections.add(websocket)
    logger.info(f"Client connected. Active connections: {len(active_connections)}")

    try:
        await websocket.send_json({
            "type": "init",
            "active": aggregator.active_cluster.to_json()
        })
    except Exception as e:
        logger.error(f"Error sending init state: {e}")

    async def heartbeat():
        """Ping every 20s to keep the connection alive through proxies/browsers."""
        try:
            while True:
                await asyncio.sleep(20)
                await websocket.send_json({"type": "ping"})
        except Exception:
            pass

    ping_task = asyncio.create_task(heartbeat())
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        active_connections.discard(websocket)
        logger.info(f"Client disconnected. Active connections: {len(active_connections)}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        active_connections.discard(websocket)
    finally:
        ping_task.cancel()

if __name__ == "__main__":
    import uvicorn
    logger.info(f"Starting YuClusters server on port {settings.WS_PORT}...")
    uvicorn.run(
        "backend.server:app",
        host="0.0.0.0",
        port=settings.WS_PORT,
        log_level="info",
    )
