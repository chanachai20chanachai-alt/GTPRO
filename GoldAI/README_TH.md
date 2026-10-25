# Gold AI Auto Trader V1.1 — PROTOTYPE (ภาษาไทย)

> ⚠️ **ยังไม่ได้ Compile ด้วย MetaEditor, ยังไม่ได้ Backtest หรือทดสอบคำสั่งซื้อขายจริง**
> เริ่มต้นแบบ **Auto Trade OFF** และจะไม่เปิดไม้ถ้า API, ข่าว หรือ Risk Filter ไม่ผ่าน ห้ามใช้เงินจริงก่อนผ่านการทดสอบ Demo

โปรเจกต์ย่อยนี้แยกจาก EA เดิมของ GTPRO ไม่มีการแก้ไขหรือลบ EA เดิม

## แนวทางกลยุทธ์

- AI อ่านแท่ง **H1/M15/M5 ที่ปิดแล้ว** ทุกครั้งที่ H1 เริ่มแท่งใหม่ (ประมาณทุก 60 นาที)
- AI เสนอ 1 แผนในรอบนั้น: **Trend Pullback**, **Breakout & Retest** หรือ **NO TRADE**
- EA ยืนยันสถานะเทรนด์จาก H1 (EMA50 กับความลาดเอียง), ตรวจ setup M15 กรณี Breakout และ Trigger บน M5 ที่ปิดแล้ว
- TP หลังมีออร์เดอร์ = **110% ของระยะจากจุดเข้าอ้างอิงถึง TP ที่ AI แนะนำ**
- SL ที่ 100% = **ราคา SL ตามโครงสร้างที่ AI เสนอ** ไม่ลด SL มาใกล้ราคาแบบไม่มีเหตุผล
- เปิดครั้งละ **1 สถานะบนสัญลักษณ์**; สูงสุด **14 ไม้ต่อวัน**, ไม่รับประกันขั้นต่ำ 8 ไม้
- 1 แผนเริ่มเปิดได้ 1 ไม้; เข้าโซนเดิมได้ **อีก 2 ครั้ง** ต่อเมื่อออร์เดอร์ก่อนหน้าปิดด้วย TP โดยโบรกเกอร์จริง เกิด M5 confirmation ชุดใหม่ ราคาเคลื่อนออกจากโซนมาก่อน และพ้น Cooldown 15 นาที; ทั้งหมดต้องเกิดก่อนแผนหมดอายุ
- หลัง SL / ปิดด้วยเหตุผลอื่น **ห้ามเข้าเดิมซ้ำ** จนได้แผนใหม่
- เป้าหมายสุทธิเบื้องต้น **3,000–6,000 จุดทอง/วัน** ($1 ของราคา = 100 จุดทอง) วัดจากกำไรสุทธิจริงแปลงกลับเป็นจุดต่อ 0.10 lot โดยประมาณ (รวม Deal Commission/Fee/Swap เมื่อมีบันทึก). ไม่ใช่จำนวนที่ EA ต้องฝืนทำให้ถึง
- ปิดการเปิดเพิ่มเมื่อแตะ **6,000 จุดสุทธิ**; เป้าหมาย 3,000 จุดแสดงเป็นข้อมูลเท่านั้น

## Input เริ่มต้นสำคัญ

| ชื่อ | ค่า |
|---|---:|
| InpFixedLot | 0.10 |
| InpTPPlanPercent | 110 |
| InpSLPlanPercent | 100 |
| InpMaxTradesPerDay | 14 |
| InpMaxReentriesAfterTP | 2 |
| InpEnableAutoTrade | false (ปิดไว้ก่อน) |
| InpMinRewardRisk | 1.5 |
| InpRiskPerTradeMaxPct | 0.5% Equity |
| InpDailyLossLimitPct | 2% |
| InpMaxEquityDrawdownPct | 10% |
| InpMaxSpreadGold | $0.50 |
| InpRequireVerifiedNews | true |

**Lot คงที่ไม่เท่ากับความเสี่ยงคงที่** หาก 0.10 lot เสี่ยงเกิน 0.5% ของ Equity ตาม SL โปรแกรมจะ **ไม่เปิดออร์เดอร์** แทนการเปลี่ยนล็อตอัตโนมัติ

## ติดตั้ง AI Bridge บน Windows

1. ติดตั้ง Python 3.11+ และรัน `pip install -r GoldAI/bridge/requirements.txt`
2. สร้าง Environment Variables ฝั่ง **Windows/terminal ที่รัน Python**:
   - `OPENAI_API_KEY` = คีย์ API (ไม่ใช่บัญชี ChatGPT Plus)
   - `BRIDGE_TOKEN` = สุ่มค่ายาวอย่างน้อย 12 ตัวอักษร แล้วตั้งค่าเดียวกันใน Input ของ EA
   - `OPENAI_MODEL` = โมเดลที่รองรับ Structured Outputs ในบัญชีของคุณ (ค่าเริ่มต้นใน bridge: `gpt-5-mini`)
   - `REQUIRE_NEWS=1` (ค่าเริ่มต้น) — ต้องมีปฏิทิน MT5 ที่ตรวจสอบได้
3. รัน `python GoldAI/bridge/server.py` ให้ Bridge ฟังเฉพาะ `127.0.0.1`
4. ใน MT5: Tools > Options > Expert Advisors > Allow WebRequest for listed URL แล้วเพิ่ม `http://127.0.0.1`
5. เปิด MetaEditor และคัดลอก `GoldAI/MT5/GoldAI_AutoTrader.mq5` ไป `MQL5/Experts/GoldAI_AutoTrader.mq5`
6. Compile ใน MetaEditor และตรวจแท็บ Errors ให้ **0 errors**; หากมี warning ให้ตรวจและแก้
7. ติดตั้งลงกราฟ XAUUSD.v **บัญชี Demo** แล้วกำหนด `InpBridgeToken` ให้ตรงกับ Python; เริ่มที่ `InpEnableAutoTrade=false`
8. ตรวจ Journal ว่าดึงข่าว ปฏิทิน, API, แผน JSON และช่วงราคาถูกต้องตามเวลา / Server TZ แล้วทดสอบการเปิดด้วยล็อต Demo ก่อนเปลี่ยน `InpEnableAutoTrade=true`

### เมื่อ API ขัดข้องหรือข้อมูลไม่พอ

EA ไม่เปิดไม้ใหม่ และจะไม่ใช้แผนหมดอายุซ้ำ. ถ้า Calendar ใช้ไม่ได้ จะขึ้น NO_TRADE โดยตั้งใจ (fail closed). ไม่ควรปิด News Filter เพื่อข้ามปัญหาในบัญชีจริง.

### ข้อจำกัดที่ยังต้องพัฒนา / ตรวจสอบ

- **Compile MT5 จริง** บน Windows + ปรับรายละเอียด broker-specific fill policy, stop level, margin
- **Replay / Backtest**: WebRequest ไม่ทำงานใน MT5 Strategy Tester; ต้องสร้าง fixture/replay mode ที่ใช้ JSON/CSV แผนจากอดีตแบบไม่ look-ahead หรือ mock bridge ใน test harness แยก
- Dashboard เวอร์ชันนี้ใช้ข้อความ `Comment()` เป็นหลัก ยังไม่มีแผง GUI ภาษาไทยพร้อมปุ่มควบคุม
- ยังไม่ส่งรายการข่าว/หัวข้อข่าวให้ AI; ปฏิทิน MT5 ที่ใช้ตอนนี้เป็น **ตัวกรองไม่เปิดก่อน/หลังข่าว USD high-impact ±30 นาที** เท่านั้น
- อัตราส่วน RR หลังหักต้นทุนเป็น **การประมาณ**; ค่า Commission จริงของโบรกเกอร์และ Slippage ควรใช้ค่าจากประวัติและจำลอง Worst-case เพิ่มเติม
- `ThaiMidnightServer()` ใช้ offset server/UTC ณ เวลาปัจจุบัน; ต้องทดสอบกรณีเปลี่ยน DST และกรณี deposit/withdrawal สำหรับคำนวณ daily risk
- บันทึก GlobalVariables ระดับ Account/Magic; ถ้าติด EA หลายกราฟ XAUUSD สัญลักษณ์อื่น/หลายเทอร์มินัล ต้องเพิ่ม distributed-lock เพื่อไม่เปิดซ้ำ
- การปิด Risk Lock ต้องทำโดยผู้ใช้และบันทึก Audit Log
- ควรเพิ่ม Symbol Volume Min/Max/Step validation และ spread/slippage shock test
- ต้องเพิ่ม unit/integration tests, trade-reason reconstruction หลังรีสตาร์ตและตรวจทุก Edge Case ก่อนใช้จริง

## แหล่งอ้างอิงทางเทคนิค

- OpenAI Structured Outputs: https://developers.openai.com/api/docs/guides/structured-outputs
- MQL5 WebRequest: https://www.mql5.com/en/docs/network/webrequest
- MQL5 Economic Calendar: https://www.mql5.com/en/docs/calendar
- MQL5 OrderCalcProfit: https://www.mql5.com/en/docs/trading/ordercalcprofit

## ข้อควรระวัง

AI ไม่รับประกันความถูกต้องของการวิเคราะห์ และเป้าหมาย 8–14 ไม้/วัน กับ 3,000–6,000 จุดสุทธิ/วัน เป็น **เป้าหมายการออกแบบและตัวชี้วัดการทดสอบ** ไม่ใช่ผลกำไรคาดการณ์ที่พิสูจน์แล้ว. หากไม่พบ setup หรือข้อมูลขัดแย้ง ต้องแสดง NO TRADE และไม่เปิดไม้.

### สำหรับ Codex: งานลำดับถัดไป

1. Compile และแก้ MQL5 บน Windows/MetaEditor ให้ได้ 0 errors
2. สร้าง Trade/Bridge replay fixture แบบมี timestamp และ walk-forward
3. เพิ่มสัญญาณที่ตรวจสอบ setup M15 และการออกจากโซนจริงก่อน re-entry
4. สร้าง UI Dashboard ภาษาไทย + Logs
5. Backtest รายเดือนและ Demo forward test 4–8 สัปดาห์ แสดง net points, trades/day, DD และ win/loss distribution ก่อนเงินจริง

### WebRequest Port บน MT5

MQL5 WebRequest ระบุว่า HTTP ใช้พอร์ต 80 และ HTTPS ใช้พอร์ต 443 ตาม protocol. รุ่นนี้จึงเลือก Python Bridge ที่ **127.0.0.1:80** และ URL `http://127.0.0.1`. หากพอร์ต 80 ของ Windows ถูกใช้อยู่ ให้ใช้ reverse proxy ในเครื่องหรือปรับ architecture ก่อนใช้งาน ไม่ควรแก้ WebRequest ให้ใช้พอร์ตอื่นโดยไม่ทดสอบการเชื่อมต่อจริง.
