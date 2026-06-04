import sys
import os
import unittest

# Add root folder to path so we can import config and backend
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from config import settings
from backend.aggregator import Aggregator, FootprintCluster, classify_tick

class TestAggregator(unittest.TestCase):
    def test_tick_classification(self):
        # TICK_FLAG_BUY = 0x2
        # TICK_FLAG_SELL = 0x4
        
        # 1. With flags
        self.assertTrue(classify_tick(last=10.0, bid=9.0, ask=11.0, flags=0x2))   # Buy flag
        self.assertFalse(classify_tick(last=10.0, bid=9.0, ask=11.0, flags=0x4))  # Sell flag
        # Buy flag should take priority even if last <= bid
        self.assertTrue(classify_tick(last=8.0, bid=9.0, ask=11.0, flags=0x2))
        
        # 2. Fallbacks (no flags or flag=0)
        self.assertTrue(classify_tick(last=11.5, bid=9.0, ask=11.0, flags=0))   # last >= ask
        self.assertFalse(classify_tick(last=8.5, bid=9.0, ask=11.0, flags=0))   # last <= bid
        
        # Mid-spread fallbacks
        self.assertTrue(classify_tick(last=10.5, bid=9.0, ask=11.0, flags=0))   # closer to ask
        self.assertFalse(classify_tick(last=9.5, bid=9.0, ask=11.0, flags=0))   # closer to bid

    def test_poc_calculation_and_tie(self):
        cluster = FootprintCluster(tick_size=1.0)
        
        # Add ticks
        cluster.add_tick(price=10.0, volume=100.0, is_buy=True, timestamp_msc=1000)
        cluster.add_tick(price=11.0, volume=150.0, is_buy=False, timestamp_msc=1100)
        cluster.add_tick(price=12.0, volume=50.0, is_buy=True, timestamp_msc=1200)
        
        # POC should be 11.0 (highest volume 150)
        self.assertEqual(cluster.poc, 11.0)
        
        # Add more volume to 10.0 to create a tie of 150.0 with 11.0
        cluster.add_tick(price=10.0, volume=50.0, is_buy=True, timestamp_msc=1300)
        # 10.0 total = 150.0. 11.0 total = 150.0.
        # Tie breaker rule: highest price level wins, so 11.0 should still be POC
        self.assertEqual(cluster.poc, 11.0)
        
        # Now let 12.0 tie with 150.0 (currently 50.0, add 100.0)
        cluster.add_tick(price=12.0, volume=100.0, is_buy=False, timestamp_msc=1400)
        # Tie between 10.0, 11.0, and 12.0. Highest price level is 12.0
        self.assertEqual(cluster.poc, 12.0)

    def test_diagonal_imbalances(self):
        cluster = FootprintCluster(tick_size=1.0)
        
        # Let's seed level 10.0 and 11.0
        # At level 10.0, bid_vol = 10.0
        # At level 11.0, ask_vol = 30.0
        # ask_vol[11.0] (30.0) >= 3.0 * bid_vol[10.0] (10.0) -> Buy imbalance at 11.0!
        cluster.add_tick(price=10.0, volume=10.0, is_buy=False, timestamp_msc=1000)
        cluster.add_tick(price=11.0, volume=30.0, is_buy=True, timestamp_msc=1010)
        
        levels_data = cluster.to_json()["levels"]
        self.assertEqual(levels_data["11.00"]["imbalance"], "buy")
        
        # At level 12.0, ask_vol = 50.0
        # At level 11.0, bid_vol = 150.0
        # bid_vol[11.0] (150.0) >= 3.0 * ask_vol[12.0] (50.0) -> Sell imbalance at 11.0!
        cluster.add_tick(price=12.0, volume=50.0, is_buy=True, timestamp_msc=1020)
        cluster.add_tick(price=11.0, volume=150.0, is_buy=False, timestamp_msc=1030)
        
        levels_data = cluster.to_json()["levels"]
        self.assertEqual(levels_data["11.00"]["imbalance"], "both")

    def test_stacked_imbalances(self):
        cluster = FootprintCluster(tick_size=1.0)
        
        # Seed bid levels
        cluster.add_tick(price=9.0, volume=10.0, is_buy=False, timestamp_msc=1000)
        cluster.add_tick(price=10.0, volume=10.0, is_buy=False, timestamp_msc=1000)
        cluster.add_tick(price=11.0, volume=10.0, is_buy=False, timestamp_msc=1000)
        
        # Seed ask levels to trigger buy imbalances at 10.0, 11.0, 12.0
        # ask[10.0] >= 3 * bid[9.0] -> ask[10.0] >= 30
        cluster.add_tick(price=10.0, volume=30.0, is_buy=True, timestamp_msc=1000)
        # ask[11.0] >= 3 * bid[10.0] -> ask[11.0] >= 30
        cluster.add_tick(price=11.0, volume=30.0, is_buy=True, timestamp_msc=1000)
        # ask[12.0] >= 3 * bid[11.0] -> ask[12.0] >= 30
        cluster.add_tick(price=12.0, volume=30.0, is_buy=True, timestamp_msc=1000)
        
        res = cluster.to_json()
        self.assertTrue(res["stacked"]["buy"])
        self.assertIn(10.0, res["stacked"]["price_range"])
        self.assertIn(11.0, res["stacked"]["price_range"])
        self.assertIn(12.0, res["stacked"]["price_range"])

    def test_closure_criteria(self):
        # Override settings programmatically
        settings.CLUSTER_RANGE_POINTS = 10
        settings.CLUSTER_VOLUME_MAX = 1000
        settings.CLUSTER_DELTA_MAX = 500
        settings.CLUSTER_TIME_SECONDS = 60
        
        agg = Aggregator(tick_size=1.0)
        
        # 1. Test closure by range
        active, closed = agg.process_tick(price=100.0, volume=1.0, is_buy=True, timestamp_msc=1000)
        self.assertIsNone(closed)
        
        active, closed = agg.process_tick(price=110.0, volume=1.0, is_buy=True, timestamp_msc=1050)
        self.assertIsNotNone(closed)
        self.assertEqual(closed["close_reason"], "range")
        
        # 2. Test closure by volume
        agg = Aggregator(tick_size=1.0)
        # Add 400 buy (delta=400, vol=400)
        active, closed = agg.process_tick(price=100.0, volume=400.0, is_buy=True, timestamp_msc=1000)
        self.assertIsNone(closed)
        # Add 400 sell (delta=0, vol=800)
        active, closed = agg.process_tick(price=100.0, volume=400.0, is_buy=False, timestamp_msc=1010)
        self.assertIsNone(closed)
        # Add 200 buy (delta=200, vol=1000) -> Should close due to volume
        active, closed = agg.process_tick(price=100.0, volume=200.0, is_buy=True, timestamp_msc=1020)
        self.assertIsNotNone(closed)
        self.assertEqual(closed["close_reason"], "volume")
        
        # 3. Test closure by delta
        agg = Aggregator(tick_size=1.0)
        active, closed = agg.process_tick(price=100.0, volume=499.0, is_buy=True, timestamp_msc=1000)
        self.assertIsNone(closed)
        active, closed = agg.process_tick(price=100.0, volume=1.0, is_buy=True, timestamp_msc=1010)
        self.assertIsNotNone(closed)
        self.assertEqual(closed["close_reason"], "delta")
        
        # 4. Test closure by time
        agg = Aggregator(tick_size=1.0)
        active, closed = agg.process_tick(price=100.0, volume=1.0, is_buy=True, timestamp_msc=1000)
        self.assertIsNone(closed)
        active, closed = agg.process_tick(price=100.0, volume=1.0, is_buy=True, timestamp_msc=1000 + 60000)
        self.assertIsNotNone(closed)
        self.assertEqual(closed["close_reason"], "time")

if __name__ == "__main__":
    unittest.main()
