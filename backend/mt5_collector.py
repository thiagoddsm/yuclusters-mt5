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
        self.last_mid_price = 0.0
        self.last_is_buy = True

    async def connect_mt5(self) -> bool:
        """
        Attempts to initialize and login to the MetaTrader 5 terminal.
        All MT5 calls are blocking, so they run in a thread executor.
        """
        try:
            # Try to connect to any running MT5 terminal without specifying path
            initialized = await asyncio.to_thread(mt5.initialize)
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

                    # Fetch from 48 hours ago so the chart isn't empty when started (covers weekends)
                    from datetime import datetime, timedelta
                    start_time_dt = datetime.now() - timedelta(hours=48)
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

                        flags = int(tick['flags'])
                        bid_price = float(tick['bid'])
                        ask_price = float(tick['ask'])
                        last_price = float(tick['last'])

                        mid_price = (bid_price + ask_price) / 2.0 if (bid_price > 0 and ask_price > 0) else 0.0
                        prev_mid = self.last_mid_price

                        # Update direction tracker from mid movement
                        if mid_price > 0:
                            if mid_price > self.last_mid_price:
                                self.last_is_buy = True
                            elif mid_price < self.last_mid_price:
                                self.last_is_buy = False
                            self.last_mid_price = mid_price

                        # Determine price (use mid as best proxy for CFD quote feed)
                        price = last_price if last_price > 0 else (mid_price if mid_price > 0 else (bid_price if bid_price > 0 else ask_price))

                        # Volume = price movement in tick-size units (how the YuCluster measures activity)
                        tick_sz = self.aggregator.tick_size if self.aggregator.tick_size > 0 else 0.01
                        if prev_mid > 0 and mid_price > 0:
                            price_steps = abs(mid_price - prev_mid) / tick_sz
                            volume = max(price_steps, 1.0)
                        else:
                            volume = 1.0

                        # Determine direction
                        if flags & 32:
                            is_buy = True
                        elif flags & 64:
                            is_buy = False
                        else:
                            is_buy = self.last_is_buy

                        active_json, closed_json = self.aggregator.process_tick(price, volume, is_buy, msc)

                        # Only broadcast during live trading (within 10s of now) to avoid
                        # flooding the WebSocket during historical replay
                        import time as _time
                        is_live = ((_time.time() * 1000) - msc) < 10_000
                        if is_live:
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
