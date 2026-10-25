import unittest
import time
from unittest.mock import patch
import sys

try:
    from openai import OpenAI
except ImportError:
    raise unittest.SkipTest("Install bridge requirements before running tests")

from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server


def make_market():
    def candles(n, start=4100.0):
        return [{"t": i*300, "o": start+i*.01, "h": start+i*.01+.2,
                 "l": start+i*.01-.2, "c": start+i*.01+.04}
                for i in range(n)]
    return {"symbol": "XAUUSD.v",
            "h1": candles(80), "m15": candles(100), "m5": candles(100),
            "news_verified": True, "timestamp_utc": int(time.time())}


def plan():
    return {"decision": "BUY", "strategy": "PULLBACK", "trend_h1": "UP",
            "entry_low": 4100.5, "entry_high": 4101.5, "entry_reference": 4101.0,
            "raw_sl": 4098.0, "raw_tp": 4110.0, "reason_th": "setup"}


class BridgeChecks(unittest.TestCase):
    def test_market_valid(self):
        server.validate_market(make_market())

    def test_stale_snapshot_rejected(self):
        d = make_market()
        d["timestamp_utc"] -= 3600
        with self.assertRaises(ValueError):
            server.validate_market(d)

    def test_missing_candles_rejected(self):
        d = make_market()
        d["m15"] = []
        with self.assertRaises(ValueError):
            server.validate_market(d)

    def test_wrong_symbol_rejected(self):
        d = make_market()
        d["symbol"] = "BTCUSD"
        with self.assertRaises(ValueError):
            server.validate_market(d)

    def test_valid_buy(self):
        p = plan()
        vals = server.validate_plan(p, make_market())
        self.assertEqual(vals[2], 4101.0)

    def test_reversed_sl_rejected(self):
        p = plan()
        p["raw_sl"] = 4105.0
        with self.assertRaises(ValueError):
            server.validate_plan(p, make_market())

    def test_no_trade(self):
        p = plan()
        p["decision"] = "NO_TRADE"
        self.assertIsNone(server.validate_plan(p, make_market()))

    def test_wire_injection_sanitized(self):
        self.assertEqual(server.no_trade("hello|world\nmore"), b"NO_TRADE|hello world more")


if __name__ == "__main__":
    unittest.main()
