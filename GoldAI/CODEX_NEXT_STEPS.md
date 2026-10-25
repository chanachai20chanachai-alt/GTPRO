# Codex task — Gold AI Auto Trader V1.1

**Repository**: chanachai20chanachai-alt/GTPRO  
**Branch**: feature/gold-ai-auto-trader-v1-1  
**Scope**: GoldAI/ only; DO NOT touch existing MQL5/Experts/GTPro_Style_EA/  
**Status**: DRAFT / DEMO-ONLY. No actual MetaEditor compile or live backtest has been confirmed.

## User's requested trading behavior

- XAUUSD / XAUUSD.v, FixedLot 0.10
- OpenAI generates H1 + M15 + M5 plan every closed H1 candle (roughly 60 minutes)
- MT5 EA verifies entry on *closed* M5 candles, using either Trend Pullback or Breakout-Retest
- TPPlanPercent 110%, SLPlanPercent 100%
- Up to **14 filled entries per Bangkok day**, preferred experiment rate **8–14/day** (do not force minimum)
- Max 1 open position on symbol, max 2 *extra* entries in same plan after a **broker-confirmed TP**, not after a manual/SL close; re-test the zone and fresh candle confirmation every time
- Net **3,000–6,000 gold-points/day** is an experimental target: $1 price change = 100 gold points. Not guaranteed or used to force risky entries.
- **NO_TRADE** if setup unconfirmed, news unavailable, broker spec unknown, API errors, or risk limit triggered.
- Preserve 0.5% equity per trade cap, 2% daily loss, 10% peak-equity drawdown protection unless explicitly configured otherwise by owner
- Record all trades, reasons, plan IDs, SL/TP, RR, potential re-entry and exit reasons

## Exact next steps for Codex (priorities)

1. On Windows, **open the .mq5 in MetaEditor and fix all compilation errors** (0 errors). Report actual Build and file hash. Do not claim compile succeeded if no MetaEditor access.
2. Run Python bridge unit tests and PR CI. Correct API SDK model access and JSON schema validation errors.
3. Implement a rigorous server-time vs UTC reconciliation including broker UTC offset/DST and a persistent Bangkok-day trade counter.
4. Add durable idempotency and re-entry reconstruction after crashes, partial fills, MT5 reconnects and multiple terminal instances. Test broker TP vs manual close.
5. Implement a **true** dry-run/signal-only mode that evaluates full entry and risk rules but never sends orders; create event log including reason for NO_TRADE.
6. Validate H1/M15/M5 swing calculations with fixtures; ensure breakouts verified without look-ahead and retest against zone.
7. Add simulation/replay mode for Strategy Tester that does not call WebRequest. Provide walk-forward report for XAUUSD and real broker contract specifications.
8. Add commission-aware risk and daily net points accounting, including realized and floating P/L, fees, swap, deposits and execution slippage.
9. Add a Thai UI dashboard with risk state and toggle between Auto/Signal/Pause; default Auto OFF.
10. Demo forward-test at least 4–8 weeks before anyone enables live trading.

## Review security

- OpenAI API key **only on local bridge**. Never put secrets in code, .set, screenshot, issue, PR comment, or GitHub Actions logs.
- The bridge currently listens on loopback HTTP port 80 because MQL5 WebRequest documentation recommends HTTP/80 or HTTPS/443. If port 80 is occupied, use a local reverse proxy / alternative IPC proven in the exact terminal environment.
- Reject stale AI plans and response replays, maintain real account risk caps, and audit all opening/closing actions.
- Keep all changes in this branch and submit for owner review before merging to main.
