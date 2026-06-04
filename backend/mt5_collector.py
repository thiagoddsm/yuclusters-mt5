import asyncio
import logging
import time
import sys
import os
from typing import Callable, Optional, Any

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import MetaTrader5 as mt5
from config import settings
from backend.aggregator import Aggregator, classify_tick

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("mt5_collector")

class MT5Collector:
    def __init__(self, aggregator: Aggregator, on_update_callback: Callable[[dict, Optional[dict]], Any]):
        self.aggregator = aggregator
        self.on_update_callback = on_update_callback
        self.symbol = settings.MT5_SYMBOL
        self.running = False
        self.connected = False
        self.last_tick_time_msc = 0
        self.seen_ticks_buffer = set()

    async def connect_mt5(self) -> bool:
        """
        Attempts to initialize and login to the MetaTrader 5 terminal.
        All MT5 calls are blocking, so they run in a thread executor.
        """
        try:
            mt5_path = r"C:\Program Files\MetaTrader 5\terminal64.exe"
            initialized = await asyncio.to_thread(mt5.initialize, path=mt5_path)
            if not initialized:
                err = await asyncio.to_thread(mt5.last_error)
                logger.error(f"MT5 initialize failed: {err}")
                return False

            if settings.MT5_LOGIN > 0:
                login_success = await asyncio.to_thread(
                    mt5.login,
                    settings.MT5_LOGIN,
                    password=settings.MT5_PASSWORD,
                    server=settings.MT5_SERVER,
                )
                if not login_success:
                    err = await asyncio.to_thread(mt5.last_error)
                    logger.error(f"MT5 login failed: {err}")
                    await asyncio.to_thread(mt5.shutdown)
                    return False

            symbol_info = await asyncio.to_thread(mt5.symbol_info, self.symbol)
            if symbol_info is None:
                logger.error(f"Symbol {self.symbol} not found.")
                await asyncio.to_thread(mt5.shutdown)
                return False

            if not symbol_info.visible:
                selected = await asyncio.to_thread(mt5.symbol_select, self.symbol, True)
                if not selected:
                    logger.error(f"Failed to select/make visible symbol {self.symbol}.")
                    await asyncio.to_thread(mt5.shutdown)
                    return False

            tick_size = symbol_info.trade_tick_size
            if tick_size > 0:
                self.aggregator.tick_size = tick_size
                self.aggregator.active_cluster.tick_size = tick_size
                logger.info(f"Set aggregator tick size to {tick_size}")

            logger.info("Successfully connected to MetaTrader 5 and logged in.")
            self.connected = True
            return True
        except Exception as e:
            logger.error(f"Exception during MT5 connection: {e}")
            return False

    async def disconnect_mt5(self):
        try:
            await asyncio.to_thread(mt5.shutdown)
        except Exception as e:
            logger.error(f"Error during MT5 shutdown: {e}")
        self.connected = False

    async def start(self):
        self.running = True
        backoff = 1.0

        while self.running:
            if not self.connected:
                success = await self.connect_mt5()
                if not success:
                    logger.info(f"Reconnecting to MT5 in {backoff:.1f}s...")
                    await asyncio.sleep(backoff)
                    backoff = min(backoff * 2, 60.0)
                    continue
                else:
                    backoff = 1.0

                    # Fetch from 6 hours ago so the chart isn't empty when started
                    from datetime import datetime, timedelta
                    start_time_dt = datetime.now() - timedelta(hours=6)
                    ticks = await asyncio.to_thread(
                        mt5.copy_ticks_from, self.symbol, start_time_dt, 100000, mt5.COPY_TICKS_ALL
                    )
                    if ticks is not None and len(ticks) > 0:
                        self.last_tick_time_msc = ticks[0]['time_msc']
                    else:
                        self.last_tick_time_msc = int(start_time_dt.timestamp() * 1000)

            # Polling loop
            try:
                from datetime import datetime
                polling_dt = datetime.fromtimestamp(self.last_tick_time_msc / 1000.0)
                ticks = await asyncio.to_thread(
                    mt5.copy_ticks_from,
                    self.symbol,
                    polling_dt,
                    1000,
                    mt5.COPY_TICKS_ALL,
                )

                if ticks is None:
                    err = await asyncio.to_thread(mt5.last_error)
                    logger.error(f"MT5 copy_ticks_from returned None: {err}")
                    self.connected = False
                    await self.disconnect_mt5()
                    continue

                if len(ticks) > 0:
                    logger.info(f"Fetched {len(ticks)} ticks starting at {ticks[0]['time_msc']}")
                    for tick in ticks:
                        msc = tick['time_msc']

                        if msc < self.last_tick_time_msc:
                            continue

                        tick_id = (msc, tick['bid'], tick['ask'], tick['last'], tick['volume_real'], tick['flags'])
                        if msc == self.last_tick_time_msc and tick_id in self.seen_ticks_buffer:
                            continue

                        if msc > self.last_tick_time_msc:
                            self.seen_ticks_buffer.clear()
                            self.last_tick_time_msc = msc

                        self.seen_ticks_buffer.add(tick_id)

                        price = tick['last'] if tick['last'] > 0 else (tick['bid'] if tick['bid'] > 0 else tick['ask'])
                        volume = tick['volume_real'] if tick['volume_real'] > 0 else float(tick['volume'])
                        flags = tick['flags']

                        # Forex ticks often have volume=0 (they are just quote updates). 
                        # We count each quote update as 1 unit of tick volume to build the footprint.
                        if volume == 0:
                            volume = 1.0

                        is_buy = classify_tick(price, tick['bid'], tick['ask'], flags)

                        active_json, closed_json = self.aggregator.process_tick(price, volume, is_buy, msc)

                        self.on_update_callback(active_json, closed_json)

                await asyncio.sleep(0.1)

            except Exception as e:
                logger.error(f"Error during tick polling loop: {e}")
                self.connected = False
                await self.disconnect_mt5()
                await asyncio.sleep(2.0)

    async def stop(self):
        self.running = False
        await self.disconnect_mt5()
        logger.info("MT5 Collector stopped.")
