import asyncio
import logging
import sys
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
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
    Callback executed by MT5Collector when a new tick is processed.
    Schedules WebSocket sends on the event loop.
    """
    message = {
        "type": "tick",
        "active": active_json,
        "closed": closed_json
    }
    for connection in list(active_connections):
        try:
            asyncio.create_task(connection.send_json(message))
        except Exception as e:
            logger.error(f"Error sending update to client: {e}")

# Initialize MT5 Collector
collector = MT5Collector(aggregator, on_update_callback=broadcast_update)

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
