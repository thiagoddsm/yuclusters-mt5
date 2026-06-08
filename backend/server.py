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
from backend.trading import send_buy_signal, send_sell_signal

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("server")

# Shared state
aggregator = Aggregator(tick_size=1.0)
active_connections: Set[WebSocket] = set()
collector_task: Optional[asyncio.Task] = None

def broadcast_update(active_json: dict, closed_json: Optional[dict], dom_data: Optional[list] = None):
    """
    Callback executed by MT5Collector when a new tick is processed.
    Only broadcasts when a cluster closes (not every tick) to avoid flooding during replay.
    Removes dead connections automatically.
    """
    if not active_connections or closed_json is None:
        return
    message = {
        "type": "tick",
        "active": active_json,
        "closed": closed_json,
        "dom": dom_data
    }
    async def safe_send(ws: WebSocket, msg: dict):
        try:
            await ws.send_json(msg)
        except Exception:
            active_connections.discard(ws)
    for connection in list(active_connections):
        asyncio.create_task(safe_send(connection, message))

def broadcast_big_trade(trade_data: dict):
    if not active_connections:
        return
    message = {
        "type": "big_trade",
        "data": trade_data
    }
    async def safe_send(ws: WebSocket, msg: dict):
        try:
            await ws.send_json(msg)
        except Exception:
            active_connections.discard(ws)
    for connection in list(active_connections):
        asyncio.create_task(safe_send(connection, message))

# Initialize MT5 Collector
collector = MT5Collector(aggregator, on_update_callback=broadcast_update, on_big_trade_callback=broadcast_big_trade)

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
        "symbol": settings.MT5_SYMBOL,
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

@app.post("/trade/buy")
async def trade_buy():
    success = send_buy_signal()
    return {"success": success}

@app.post("/trade/sell")
async def trade_sell():
    success = send_sell_signal()
    return {"success": success}

class HistoryLoadRequest(BaseModel):
    start_time: str
    end_time: str

@app.post("/history/load")
async def load_history(req: HistoryLoadRequest):
    from datetime import datetime
    try:
        start_dt = datetime.fromisoformat(req.start_time)
        end_dt = datetime.fromisoformat(req.end_time)
        await collector.load_historical_range(start_dt, end_dt)
        return {"success": True}
    except Exception as e:
        logger.error(f"Error loading history: {e}")
        return {"success": False, "error": str(e)}

@app.post("/history/live")
async def return_to_live():
    collector.return_to_live()
    return {"success": True}

@app.get("/history")
async def get_history():
    """Returns the buffer of historical closed clusters."""
    return aggregator.history

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    active_connections.add(websocket)
    logger.info(f"Client connected. Active connections: {len(active_connections)}")

    # Send the current active cluster state on connection
    try:
        await websocket.send_json({
            "type": "init",
            "active": aggregator.active_cluster.to_json()
        })
    except Exception as e:
        logger.error(f"Error sending init state: {e}")

    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        active_connections.discard(websocket)
        logger.info(f"Client disconnected. Active connections: {len(active_connections)}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        active_connections.discard(websocket)

if __name__ == "__main__":
    import uvicorn
    logger.info(f"Starting YuClusters server on port {settings.WS_PORT}...")
    uvicorn.run(
        "backend.server:app",
        host="0.0.0.0",
        port=settings.WS_PORT,
        log_level="info",
    )
