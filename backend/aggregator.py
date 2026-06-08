import uuid
import time
import logging
from typing import Dict, Any, List, Optional
from config import settings

logger = logging.getLogger("aggregator")

class FootprintCluster:
    def __init__(self, tick_size: float = 1.0):
        self.tick_size = tick_size
        self.cluster_id = str(uuid.uuid4())
        self.status = "active"
        self.open_time: Optional[int] = None
        self.close_reason: Optional[str] = None
        self.open_price: Optional[float] = None
        self.close_price: Optional[float] = None
        self.high: Optional[float] = None
        self.low: Optional[float] = None
        self.poc: Optional[float] = None
        self.total_delta: float = 0.0
        self.total_volume: float = 0.0
        self.total_ticks: int = 0
        self.close_time: Optional[int] = None
        
        # levels: price_float -> { 'ask': float, 'bid': float }
        # internally we keep float keys to make sorting and arithmetic easy
        self.levels: Dict[float, Dict[str, float]] = {}
        self.stacked: Dict[str, Any] = {
            "buy": False,
            "sell": False,
            "price_range": []
        }
        self.advanced_metrics: Dict[str, Any] = {
            "poc_position": None,
            "pattern": None,
            "top_extreme": None,
            "bottom_extreme": None
        }

    def add_tick(self, price: float, volume: float, is_buy: bool, timestamp_msc: int) -> None:
        if self.open_time is None:
            self.open_time = timestamp_msc
            self.open_price = price
            
        self.close_price = price
        self.close_time = timestamp_msc
        self.total_ticks += 1

        # Round price to the nearest tick_size to avoid float precision issues
        rounded_price = round(price / self.tick_size) * self.tick_size
        
        if rounded_price not in self.levels:
            self.levels[rounded_price] = {"ask": 0.0, "bid": 0.0, "ask_events": 0, "bid_events": 0}

        if is_buy:
            self.levels[rounded_price]["ask"] += volume
            self.levels[rounded_price]["ask_events"] += 1
        else:
            self.levels[rounded_price]["bid"] += volume
            self.levels[rounded_price]["bid_events"] += 1

        # Update High/Low
        if self.high is None or rounded_price > self.high:
            self.high = rounded_price
        if self.low is None or rounded_price < self.low:
            self.low = rounded_price
            
        # Recalculate totals, POC, imbalances and stacked imbalances
        self._recalculate()

    def _recalculate(self) -> None:
        if not self.levels:
            return

        self.total_volume = 0.0
        self.total_delta = 0.0
        
        # First pass: calc totals and delta per level
        for price, data in self.levels.items():
            ask = data["ask"]
            bid = data["bid"]
            lvl_delta = ask - bid
            lvl_total = ask + bid
            self.total_volume += lvl_total
            self.total_delta += lvl_delta

        # Find POC: level with the highest total volume. 
        # Tie-breaker: choose the highest price level.
        sorted_prices = sorted(self.levels.keys())
        best_price = sorted_prices[0]
        max_total = -1.0
        for price in sorted_prices:
            total_vol = self.levels[price]["ask"] + self.levels[price]["bid"]
            if total_vol > max_total:
                max_total = total_vol
                best_price = price
            elif total_vol == max_total:
                if price > best_price:
                    best_price = price
        self.poc = best_price

        # Second pass: calculate imbalances diagonal and stacked imbalances
        # To avoid division by zero:
        # imbalance_buy[i] is True if ask_vol[i] >= R * bid_vol[i - tick_size]
        # imbalance_sell[i] is True if bid_vol[i] >= R * ask_vol[i + tick_size]
        R = settings.IMBALANCE_RATIO
        
        imbalances_buy = {}
        imbalances_sell = {}
        
        # IMBALANCE DESATIVADO TEMPORARIAMENTE
        # Todas as abordagens testadas geraram dots em todos os levels.
        # Ver project_imbalance_research.md para histórico completo das tentativas.
        # Reativar quando encontrar a abordagem correta.
        for price in sorted_prices:
            imbalances_buy[price] = False
            imbalances_sell[price] = False

        # Detect stacked imbalances: 3+ consecutive levels with imbalance in the same direction
        # Let's check contiguous price levels in steps of tick_size
        stacked_buy = False
        stacked_sell = False
        stacked_buy_prices = []
        stacked_sell_prices = []
        
        min_consecutive = settings.STACKED_MIN_COUNT
        
        # We need to check all possible price steps from low to high
        if self.low is not None and self.high is not None:
            current_price = self.low
            consec_buy = []
            consec_sell = []
            
            while current_price <= self.high:
                rounded_p = round(current_price / self.tick_size) * self.tick_size
                
                # Check Buy
                if imbalances_buy.get(rounded_p, False):
                    consec_buy.append(rounded_p)
                else:
                    if len(consec_buy) >= min_consecutive:
                        stacked_buy = True
                        stacked_buy_prices.extend(consec_buy)
                    consec_buy = []
                    
                # Check Sell
                if imbalances_sell.get(rounded_p, False):
                    consec_sell.append(rounded_p)
                else:
                    if len(consec_sell) >= min_consecutive:
                        stacked_sell = True
                        stacked_sell_prices.extend(consec_sell)
                    consec_sell = []
                    
                current_price += self.tick_size
                
            # Final check at the end of the loop
            if len(consec_buy) >= min_consecutive:
                stacked_buy = True
                stacked_buy_prices.extend(consec_buy)
            if len(consec_sell) >= min_consecutive:
                stacked_sell = True
                stacked_sell_prices.extend(consec_sell)

        # Build output properties for stacked
        self.stacked = {
            "buy": stacked_buy,
            "sell": stacked_sell,
            "price_range": sorted(list(set(stacked_buy_prices + stacked_sell_prices)))
        }

        # Store imbalances back in levels for JSON output
        for price in sorted_prices:
            imb = None
            if imbalances_buy.get(price, False) and imbalances_sell.get(price, False):
                imb = "both"
            elif imbalances_buy.get(price, False):
                imb = "buy"
            elif imbalances_sell.get(price, False):
                imb = "sell"
                
            self.levels[price]["delta"] = self.levels[price]["ask"] - self.levels[price]["bid"]
            self.levels[price]["total"] = self.levels[price]["ask"] + self.levels[price]["bid"]
            self.levels[price]["imbalance"] = imb

        # Advanced Metrics Calculation
        if self.high is not None and self.low is not None and self.high > self.low and self.total_volume > 0:
            # 1. POC Position
            poc_percent = (self.poc - self.low) / (self.high - self.low)
            if poc_percent >= 0.65:
                self.advanced_metrics["poc_position"] = "top"
            elif poc_percent <= 0.35:
                self.advanced_metrics["poc_position"] = "bottom"
            else:
                self.advanced_metrics["poc_position"] = "middle"
                
            # 2. P and B Patterns
            mid_price = (self.high + self.low) / 2.0
            vol_above = sum(self.levels[p]["total"] for p in sorted_prices if p >= mid_price)
            vol_below = sum(self.levels[p]["total"] for p in sorted_prices if p < mid_price)
            
            if vol_above / self.total_volume > 0.65:
                self.advanced_metrics["pattern"] = "P"
            elif vol_below / self.total_volume > 0.65:
                self.advanced_metrics["pattern"] = "B"
            else:
                self.advanced_metrics["pattern"] = "normal"
                
            # 3. Extremes (Exhaustion / Absorption)
            top_vol = self.levels[self.high]["total"]
            next_top_price = round((self.high - self.tick_size) / self.tick_size) * self.tick_size
            next_top_vol = self.levels.get(next_top_price, {}).get("total", 0.0)
            avg_vol = self.total_volume / len(self.levels)
            
            if top_vol < avg_vol * 0.2 and next_top_vol > avg_vol * 0.5:
                self.advanced_metrics["top_extreme"] = "exhaustion"
            elif top_vol > avg_vol * 2.5:
                self.advanced_metrics["top_extreme"] = "absorption"
            else:
                self.advanced_metrics["top_extreme"] = "normal"
                
            bottom_vol = self.levels[self.low]["total"]
            next_bot_price = round((self.low + self.tick_size) / self.tick_size) * self.tick_size
            next_bot_vol = self.levels.get(next_bot_price, {}).get("total", 0.0)
            
            if bottom_vol < avg_vol * 0.2 and next_bot_vol > avg_vol * 0.5:
                self.advanced_metrics["bottom_extreme"] = "exhaustion"
            elif bottom_vol > avg_vol * 2.5:
                self.advanced_metrics["bottom_extreme"] = "absorption"
            else:
                self.advanced_metrics["bottom_extreme"] = "normal"
                
            # 4. Ratios (Exhaustion/Absorption quantification at extremes)
            if next_top_vol > 0:
                self.advanced_metrics["high_ratio"] = round(top_vol / next_top_vol, 2)
            else:
                self.advanced_metrics["high_ratio"] = round(top_vol, 2) if top_vol > 0 else 0.0
                
            if next_bot_vol > 0:
                self.advanced_metrics["low_ratio"] = round(bottom_vol / next_bot_vol, 2)
            else:
                self.advanced_metrics["low_ratio"] = round(bottom_vol, 2) if bottom_vol > 0 else 0.0
                
            # 5. Delta Divergence (Price direction vs Order Flow Delta)
            self.advanced_metrics["delta_divergence"] = False
            if self.open_price is not None and self.close_price is not None:
                is_bull = self.close_price > self.open_price
                is_bear = self.close_price < self.open_price
                if (is_bull and self.total_delta < 0) or (is_bear and self.total_delta > 0):
                    self.advanced_metrics["delta_divergence"] = True

    def should_close(self, current_time_msc: int) -> Optional[str]:
        mode = settings.CLUSTER_CLOSE_MODE

        # Volume safety cap — always applied (prevents runaway cluster if market halts)
        if self.total_volume >= settings.CLUSTER_VOLUME_MAX:
            return "volume"

        # Primary closing condition based on configured mode
        if mode == "delta":
            if abs(self.total_delta) >= settings.CLUSTER_DELTA_MAX:
                return "delta"

        elif mode == "range":
            if self.high is not None and self.low is not None:
                if (self.high - self.low) >= settings.CLUSTER_RANGE_POINTS:
                    return "range"

        elif mode == "time":
            if self.open_time is not None:
                elapsed = (current_time_msc - self.open_time) / 1000.0
                if elapsed >= settings.CLUSTER_TIME_SECONDS:
                    return "time"

        elif mode == "volume":
            if self.total_volume >= settings.CLUSTER_VOLUME_MAX:
                return "volume"

        return None

    def close(self, reason: str) -> None:
        self.status = "closed"
        self.close_reason = reason

    def to_json(self) -> Dict[str, Any]:
        # Convert keys in levels to string for JSON compatibility
        levels_str = {}
        for price, data in sorted(self.levels.items(), reverse=True):
            levels_str[f"{price:.5f}"] = {
                "ask": float(data.get("ask", 0.0)),
                "bid": float(data.get("bid", 0.0)),
                "delta": float(data.get("delta", 0.0)),
                "total": float(data.get("total", 0.0)),
                "imbalance": data.get("imbalance", None)
            }
            
        return {
            "cluster_id": self.cluster_id,
            "tick_size": self.tick_size,
            "status": self.status,
            "open_time": int(self.open_time) if self.open_time is not None else None,
            "close_reason": self.close_reason,
            "open_price": float(self.open_price) if self.open_price is not None else None,
            "close_price": float(self.close_price) if self.close_price is not None else None,
            "high": float(self.high) if self.high is not None else None,
            "low": float(self.low) if self.low is not None else None,
            "poc": float(self.poc) if self.poc is not None else None,
            "close_time": int(self.close_time) if self.close_time is not None else None,
            "total_delta": float(self.total_delta),
            "total_volume": float(self.total_volume),
            "total_ticks": int(self.total_ticks),
            "bar_volume": None,
            "levels": levels_str,
            "stacked": {
                "buy": bool(self.stacked.get("buy", False)),
                "sell": bool(self.stacked.get("sell", False)),
                "price_range": [float(p) for p in self.stacked.get("price_range", [])]
            },
            "advanced_metrics": self.advanced_metrics
        }


class Aggregator:
    def __init__(self, tick_size: float = 1.0):
        self.tick_size = tick_size
        self.active_cluster = FootprintCluster(tick_size=self.tick_size)
        self.history: List[Dict[str, Any]] = []

    def _close_active(self, reason: str) -> Dict[str, Any]:
        self.active_cluster.close(reason)
        closed = self.active_cluster.to_json()
        from datetime import datetime
        ts = closed.get('close_time') or closed.get('open_time') or 0
        dt = datetime.fromtimestamp(ts / 1000.0).strftime("%H:%M:%S") if ts else "?"
        logger.info(f"CLUSTER CLOSED [{dt}] vol={closed['total_volume']:.0f} delta={closed['total_delta']:.0f} reason={reason}")
        self.history.append(closed)
        if len(self.history) > settings.HISTORY_BUFFER_SIZE:
            self.history.pop(0)
        self.active_cluster = FootprintCluster(tick_size=self.tick_size)
        return closed

    def process_tick(self, price: float, volume: float, is_buy: bool, timestamp_msc: int) -> tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
        """
        Process a single tick.
        In delta mode, splits ticks (via while loop) so no cluster ever overshoots ±CLUSTER_DELTA_MAX.
        Returns:
            (active_cluster_json, closed_cluster_json_if_just_closed)
        """
        last_closed = None

        if settings.CLUSTER_CLOSE_MODE != "delta":
            self.active_cluster.add_tick(price, volume, is_buy, timestamp_msc)
            close_reason = self.active_cluster.should_close(timestamp_msc)
            if close_reason:
                last_closed = self._close_active(close_reason)
            return self.active_cluster.to_json(), last_closed

        remaining = volume

        while remaining > 0:
            current_delta = self.active_cluster.total_delta

            # If cluster is already at/beyond threshold (from a previous leftover), close it first
            if self.active_cluster.total_ticks > 0 and abs(current_delta) >= settings.CLUSTER_DELTA_MAX:
                last_closed = self._close_active("delta")
                continue

            contribution = remaining if is_buy else -remaining
            projected = current_delta + contribution

            if abs(projected) <= settings.CLUSTER_DELTA_MAX:
                # Remaining fits — add and check for any close condition
                self.active_cluster.add_tick(price, remaining, is_buy, timestamp_msc)
                close_reason = self.active_cluster.should_close(timestamp_msc)
                if close_reason:
                    last_closed = self._close_active(close_reason)
                break

            # Split exactly at CLUSTER_DELTA_MAX
            if is_buy:
                capacity = settings.CLUSTER_DELTA_MAX - current_delta
            else:
                capacity = current_delta + settings.CLUSTER_DELTA_MAX

            capacity = max(capacity, 0.0)

            if capacity > 0:
                self.active_cluster.add_tick(price, capacity, is_buy, timestamp_msc)

            last_closed = self._close_active("delta")
            remaining -= capacity

        return self.active_cluster.to_json(), last_closed


def classify_tick(last: float, bid: float, ask: float, flags: int) -> bool:
    """
    Classify tick aggressiveness.
    TICK_FLAG_BUY = 32 -> BUY (True)
    TICK_FLAG_SELL = 64 -> SELL (False)
    TICK_FLAG_ASK = 4 -> ASK (True)
    TICK_FLAG_BID = 2 -> BID (False)
    """
    if flags & 32:
        return True
    elif flags & 64:
        return False
    
    if last > 0:
        if last >= ask:
            return True
        elif last <= bid:
            return False
            
    # Forex quote ticks fallback
    if flags & 4:
        return True
    elif flags & 2:
        return False
        
    # Standard fallback if between spread: closer to ask is BUY
    if ask > bid and last > 0:
        return (last - bid) >= (ask - last)
    return True

