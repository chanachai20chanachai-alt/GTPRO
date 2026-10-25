"""Gold AI local bridge — prototype. Binds to localhost, never sends broker orders."""
import hmac
import json
import os
import re
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from openai import OpenAI

HOST = "127.0.0.1"
PORT = int(os.environ.get("BRIDGE_PORT", "80"))
MODEL = os.environ.get("OPENAI_MODEL", "gpt-5-mini")
TOKEN = os.environ.get("BRIDGE_TOKEN", "")
REQUIRE_NEWS = os.environ.get("REQUIRE_NEWS", "1") == "1"

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "decision": {"type": "string", "enum": ["BUY", "SELL", "NO_TRADE"]},
        "strategy": {"type": "string", "enum": ["PULLBACK", "BREAKOUT_RETEST", "NONE"]},
        "trend_h1": {"type": "string", "enum": ["UP", "DOWN", "RANGE"]},
        "entry_low": {"type": ["number", "null"]},
        "entry_high": {"type": ["number", "null"]},
        "entry_reference": {"type": ["number", "null"]},
        "raw_sl": {"type": ["number", "null"]},
        "raw_tp": {"type": ["number", "null"]},
        "reason_th": {"type": "string"},
    },
    "required": [
        "decision", "strategy", "trend_h1", "entry_low", "entry_high",
        "entry_reference", "raw_sl", "raw_tp", "reason_th"
    ],
}

INSTRUCTIONS = """
คุณเป็นผู้วิเคราะห์ XAUUSD สำหรับระบบเทรดอัตโนมัติที่ระมัดระวัง
วิเคราะห์ H1 เป็นแนวโน้ม, M15 เป็นโซน, M5 เป็นข้อมูลเสริมเท่านั้น
ใช้เฉพาะแท่งที่ปิดแล้วที่ส่งมา ห้ามอ้างราคา ข่าว หรืออินดิเคเตอร์ที่ไม่มีใน input
เลือกได้เพียง PULLBACK ตามเทรนด์ หรือ BREAKOUT_RETEST ที่ต้องรอราคารีเทสต์
สร้างแผน BUY/SELL เฉพาะเมื่อแนวโน้มและ swing ที่ยืนยันแล้วชัดเจน
AI แค่ส่งแผน; MQL5 เป็นผู้ตรวจแท่ง M5 ที่ปิดแล้วอีกครั้งก่อนเข้า
ราคาจุดเข้าเป็นโซนที่ยังรออยู่ ห้ามไล่ราคา ระบุ SL หลัง swing, TP โครงสร้างถัดไป
หากสัญญาณไม่ชัด, sideway, RR ไม่ดี หรือข้อมูลไม่พอ: decision=NO_TRADE
เมื่อ NO_TRADE ให้ strategy=NONE และราคาทั้งหมดเป็น null
ไม่มีเป้าหมายจำนวนเทรดขั้นต่ำ และห้ามประดิษฐ์ความแน่นอน
ตอบเป็น JSON ตาม schema เท่านั้น
""".strip()


def no_trade(reason: str) -> bytes:
    # Wire format consumed by MQL5; never return a tradable plan after any error.
    clean = re.sub(r"[|\r\n]", " ", str(reason))[:180]
    return ("NO_TRADE|" + clean).encode("utf-8")


def validate_market(market: dict) -> None:
    if not isinstance(market, dict):
        raise ValueError("market must be object")
    sym = market.get("symbol")
    if not isinstance(sym, str) or not sym.upper().startswith("XAUUSD"):
        raise ValueError("only XAUUSD supported")
    for tf, count in (("h1", 40), ("m15", 60), ("m5", 80)):
        candles = market.get(tf)
        if not isinstance(candles, list) or len(candles) < count:
            raise ValueError("insufficient closed candles for " + tf)
        for candle in candles:
            if not isinstance(candle, dict):
                raise ValueError("malformed candle")
            for key in ("t", "o", "h", "l", "c"):
                if not isinstance(candle.get(key), (int, float)):
                    raise ValueError("malformed candle values")


def validate_plan(plan: dict, market: dict) -> tuple:
    direction = plan["decision"]
    if direction == "NO_TRADE":
        return None
    if plan["strategy"] not in ("PULLBACK", "BREAKOUT_RETEST"):
        raise ValueError("invalid strategy")
    vals = [plan[k] for k in ("entry_low", "entry_high", "entry_reference", "raw_sl", "raw_tp")]
    if any(v is None or not isinstance(v, (int, float)) or not 1000 < v < 20000 for v in vals):
        raise ValueError("invalid prices")
    lo, hi, ref, sl, tp = vals
    if not (lo <= ref <= hi and hi - lo <= 25):
        raise ValueError("invalid entry zone")
    if direction == "BUY" and not (sl < lo <= hi < tp):
        raise ValueError("invalid BUY structure")
    if direction == "SELL" and not (tp < lo <= hi < sl):
        raise ValueError("invalid SELL structure")
    if abs(ref - sl) < .5 or abs(ref - tp) < .5:
        raise ValueError("distances too short")
    # Block wildly stale or nonsensical proposals.
    last = market["m5"][-1]["c"]
    if abs(ref - last) > 40:
        raise ValueError("entry too far from last close")
    return lo, hi, ref, sl, tp


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, payload: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:
        if self.path != "/analyze":
            self._reply(404, no_trade("unknown endpoint"))
            return
        supplied = self.headers.get("X-Bridge-Token", "")
        if not TOKEN or not hmac.compare_digest(supplied, TOKEN):
            self._reply(403, no_trade("unauthorized bridge"))
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 350_000:
                raise ValueError("invalid body size")
            market = json.loads(self.rfile.read(size))
            validate_market(market)
            if REQUIRE_NEWS and not market.get("news_verified", False):
                self._reply(200, no_trade("news feed not verified: fail closed"))
                return
            if not os.environ.get("OPENAI_API_KEY"):
                self._reply(503, no_trade("OPENAI_API_KEY missing"))
                return

            result = OpenAI(timeout=18.0, max_retries=0).responses.create(
                model=MODEL,
                instructions=INSTRUCTIONS,
                input=json.dumps(market, ensure_ascii=False, separators=(",", ":")),
                text={"format": {"type": "json_schema", "name": "xau_trade_plan",
                                 "strict": True, "schema": SCHEMA}},
            )
            plan = json.loads(result.output_text)
            parsed = validate_plan(plan, market)
            if parsed is None:
                self._reply(200, no_trade(plan["reason_th"]))
                return
            lo, hi, ref, sl, tp = parsed
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M")
            plan_id = stamp + "_" + plan["decision"][0] + "_" + plan["strategy"][0]
            expires = int(time.time()) + 3600
            reason = re.sub(r"[|\r\n]", " ", plan["reason_th"])[:180]
            fields = [
                "PLAN", plan_id, plan["decision"], plan["strategy"],
                f"{lo:.3f}", f"{hi:.3f}", f"{ref:.3f}", f"{sl:.3f}",
                f"{tp:.3f}", str(expires), reason
            ]
            self._reply(200, "|".join(fields).encode("utf-8"))
        except Exception as exc:
            # Log exception type, not API token, request content, or secrets.
            print("Analysis failed:", type(exc).__name__, flush=True)
            self._reply(200, no_trade("analysis error: " + type(exc).__name__))

    def log_message(self, fmt: str, *args) -> None:
        # Avoid logging request body or headers.
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("Set BRIDGE_TOKEN before starting")
    print(f"Bridge listening on http://{HOST}:{PORT}; news_required={REQUIRE_NEWS}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
