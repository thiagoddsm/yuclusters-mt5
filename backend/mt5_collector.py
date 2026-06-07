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
        self.last_bid_price = 0.0
        self.last_is_buy = True
        self.last_bid = 0.0
        self.last_ask = 0.0
        self._history_annotated = False

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

    async def _find_last_session_open(self):
        """
        Detecta o início da última sessão de mercado buscando o maior gap
        nos últimos N bars M1. Um gap > 30min indica fechamento de sessão.
        Retorna o datetime do primeiro bar após o gap (abertura de sessão).
        """
        from datetime import datetime, timedelta
        SESSION_GAP_MINUTES = 30
        LOOKBACK_BARS = 3000  # ~50h de M1

        rates = await asyncio.to_thread(
            mt5.copy_rates_from_pos, self.symbol, mt5.TIMEFRAME_M1, 0, LOOKBACK_BARS
        )

        if rates is None or len(rates) < 2:
            logger.warning("_find_last_session_open: sem bars M1, usando HISTORY_HOURS")
            return datetime.now() - timedelta(hours=settings.HISTORY_HOURS)

        # Percorre de trás para frente procurando o maior gap (fechamento de sessão)
        best_gap = 0
        session_open_ts = None
        for i in range(len(rates) - 1, 0, -1):
            gap_sec = int(rates[i]['time']) - int(rates[i - 1]['time'])
            if gap_sec > best_gap:
                best_gap = gap_sec
                session_open_ts = int(rates[i]['time'])

        if session_open_ts and best_gap >= SESSION_GAP_MINUTES * 60:
            dt = datetime.fromtimestamp(session_open_ts)
            logger.info(f"Última abertura de sessão detectada: {dt} (gap de {best_gap//60}min)")
            return dt
        else:
            logger.warning("Nenhum gap de sessão encontrado, usando HISTORY_HOURS")
            return datetime.now() - timedelta(hours=settings.HISTORY_HOURS)

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

                    from datetime import datetime, timedelta
                    if settings.HISTORY_FROM_DATE:
                        start_time_dt = datetime.strptime(settings.HISTORY_FROM_DATE, "%Y.%m.%d")
                    elif settings.HISTORY_SESSION_START:
                        start_time_dt = await self._find_last_session_open()
                    else:
                        start_time_dt = datetime.now() - timedelta(hours=settings.HISTORY_HOURS)
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

                # Annotate history once replay is complete (first under-full batch = caught up)
                if not self._history_annotated and len(ticks) < 1000:
                    self._history_annotated = True
                    await self.annotate_history_bar_volume()

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

                        if bid_price > 0: self.last_bid = bid_price
                        if ask_price > 0: self.last_ask = ask_price
                        mid_price = (bid_price + ask_price) / 2.0 if (bid_price > 0 and ask_price > 0) else 0.0
                        prev_mid = self.last_mid_price
                        prev_bid = self.last_bid_price

                        # Update direction tracker from bid movement (YuCluster uses Bid as price reference)
                        if bid_price > 0:
                            if bid_price > self.last_bid_price:
                                self.last_is_buy = True
                            elif bid_price < self.last_bid_price:
                                self.last_is_buy = False
                            self.last_bid_price = bid_price
                        elif mid_price > 0:
                            if mid_price > self.last_mid_price:
                                self.last_is_buy = True
                            elif mid_price < self.last_mid_price:
                                self.last_is_buy = False
                        if mid_price > 0:
                            self.last_mid_price = mid_price

                        # Determine price (use mid as best proxy for CFD quote feed)
                        price = last_price if last_price > 0 else (mid_price if mid_price > 0 else (bid_price if bid_price > 0 else ask_price))

                        # Volume = bid price movement in tick-size units (YuCluster: "Ticks & Bid")
                        tick_sz = self.aggregator.tick_size if self.aggregator.tick_size > 0 else 0.01
                        if prev_bid > 0 and bid_price > 0:
                            price_steps = abs(bid_price - prev_bid) / tick_sz
                            volume = max(price_steps, 1.0)
                        elif prev_mid > 0 and mid_price > 0:
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

                        # Annotate live closed clusters with M1 bar volume
                        if is_live and closed_json and closed_json.get('open_time') and closed_json.get('close_time'):
                            bar_vol = await self.fetch_bar_volume(
                                closed_json['open_time'], closed_json['close_time']
                            )
                            closed_json['bar_volume'] = bar_vol
                            # Sync back to history buffer
                            for h in self.aggregator.history:
                                if h['cluster_id'] == closed_json['cluster_id']:
                                    h['bar_volume'] = bar_vol
                                    break

                        if is_live:
                            active_json['bid'] = self.last_bid
                            active_json['ask'] = self.last_ask
                            self.on_update_callback(active_json, closed_json)

                await asyncio.sleep(0.1)

            except Exception as e:
                logger.error(f"Error during tick polling loop: {e}")
                self.connected = False
                await self.disconnect_mt5()
                await asyncio.sleep(2.0)

    async def fetch_bar_volume(self, open_time_msc: int, close_time_msc: int) -> int:
        """Sum tick_volume of M1 bars that overlap with the cluster's time range."""
        from datetime import datetime
        # Expand range by 1 minute on each side to capture partial bars
        open_dt  = datetime.fromtimestamp((open_time_msc  - 60_000) / 1000.0)
        close_dt = datetime.fromtimestamp((close_time_msc + 60_000) / 1000.0)
        rates = await asyncio.to_thread(
            mt5.copy_rates_range, self.symbol, mt5.TIMEFRAME_M1, open_dt, close_dt
        )
        if rates is None or len(rates) == 0:
            return 0
        total = 0
        for r in rates:
            bar_start_msc = int(r['time']) * 1000
            bar_end_msc   = bar_start_msc + 60_000
            # Count bar if it overlaps with cluster period
            if bar_start_msc < close_time_msc and bar_end_msc > open_time_msc:
                total += int(r['tick_volume'])
        return total

    async def annotate_history_bar_volume(self):
        """Batch-fetch M1 bars and annotate all history clusters with bar_volume."""
        if not self.aggregator.history:
            return
        first_open  = self.aggregator.history[0].get('open_time') or 0
        last_close  = self.aggregator.history[-1].get('close_time') or self.aggregator.history[-1].get('open_time') or 0
        if not first_open or not last_close:
            return
        from datetime import datetime
        open_dt  = datetime.fromtimestamp((first_open  - 60_000) / 1000.0)
        close_dt = datetime.fromtimestamp((last_close  + 60_000) / 1000.0)
        all_rates = await asyncio.to_thread(
            mt5.copy_rates_range, self.symbol, mt5.TIMEFRAME_M1, open_dt, close_dt
        )
        if all_rates is None or len(all_rates) == 0:
            logger.warning("annotate_history_bar_volume: no M1 bars returned")
            return
        for cluster in self.aggregator.history:
            c_open  = cluster.get('open_time')  or 0
            c_close = cluster.get('close_time') or c_open
            total = 0
            for r in all_rates:
                bar_start_msc = int(r['time']) * 1000
                bar_end_msc   = bar_start_msc + 60_000
                if bar_start_msc < c_close and bar_end_msc > c_open:
                    total += int(r['tick_volume'])
            cluster['bar_volume'] = total
        logger.info(f"annotate_history_bar_volume: annotated {len(self.aggregator.history)} clusters")

    async def stop(self):
        self.running = False
        await self.disconnect_mt5()
        logger.info("MT5 Collector stopped.")
