#!/usr/bin/env bash
# fix8（增量补丁，须先有 fix6/fix7）：修 flash_sale 假报成功。
# 上游逻辑：TodayExchange 不抛异常就打印「兑换成功」并发成功推送；实测库存 0 时
# 接口同样返回 code=0、元宝不扣、券不到账（纯假报）。本补丁：开抢前记录元宝余额，
# 兑换后最多复查 3 次，实际扣款 >= 商品价才算成功（才推送）；未扣款如实记「未抢到」。
# 部署：改宿主机源码 -> docker cp 进容器 -> 重启 -> 健康检查。幂等可重复跑。
set -u
APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
SC="$APP_DIR/backend/app/core/scheduler.py"
CONT="xiaocan-assistant"
TS="$(date +%Y%m%d%H%M%S)"
say() { echo "[fix8] $*"; }
[ -f "$SC" ] || { say "ERROR: 找不到 scheduler.py，退出"; exit 1; }
cp -a "$SC" "/root/scheduler.py.bak-fix8-$TS"
export XIAOCAN_SC="$SC"
if ! python3 - <<'PYEOF_FIX8'
import os, re, sys
path = os.environ["XIAOCAN_SC"]
src = open(path, encoding="utf-8").read()
if "[fix8]" in src:
    print("[fix8] already applied, skip")
    sys.exit(0)
m = re.search(r"client\.today_exchange\(exchange_id=eid,\s*(token=[^,]+),", src)
if not m:
    print("[fix8] today_exchange call not found")
    sys.exit(1)
tok = m.group(1)
lines = src.split("\n")

idx_t = next((i for i, ln in enumerate(lines) if ln.strip() == "target_item = None"), None)
if idx_t is None:
    print("[fix8] target_item anchor not found")
    sys.exit(1)
ind16 = " " * 16
before_block = [
    ind16 + "_silk_before = None",
    ind16 + "try:",
    ind16 + "    _ui0 = await client.get_user_info(" + tok + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
    ind16 + '    _silk_before = (_ui0.get("user_info") or {}).get("silk")',
    ind16 + "except Exception:",
    ind16 + "    _silk_before = None",
]
lines[idx_t:idx_t] = before_block

src = "\n".join(lines)
lines = src.split("\n")
i_ex = next(i for i, ln in enumerate(lines) if "ex_res = await client.today_exchange" in ln)
i_try = i_ex - 1
assert lines[i_try].strip() == "try:", "line above today_exchange is not try"
i_end = next(i for i in range(i_ex, len(lines)) if "level=NotificationLevel.SUCCESS" in lines[i])
i_close = i_end + 1
assert lines[i_close].strip() == ")", "notification block tail mismatch"
i20 = " " * 20
i24 = " " * 24
i28 = " " * 28
new_block = [
    i20 + "try:",
    i24 + "ex_res = await client.today_exchange(exchange_id=eid, " + tok + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
    i24 + "# [fix8] no-error != success: only an actual silk deduction counts",
    i24 + "_verified = False",
    i24 + "_silk_after = None",
    i24 + "for _vt in range(3):",
    i28 + "await asyncio.sleep(1.0)",
    i28 + "try:",
    i28 + "    _ui2 = await client.get_user_info(" + tok + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
    i28 + '    _silk_after = (_ui2.get("user_info") or {}).get("silk")',
    i28 + "except Exception:",
    i28 + "    _silk_after = None",
    i28 + "if _silk_before is not None and _silk_after is not None and (_silk_before - _silk_after) >= max(int(esilk or 0), 1):",
    i28 + "    _verified = True",
    i28 + "    break",
    i24 + "_ts8 = datetime.now().strftime('%H:%M:%S.%f')[:-3]",
    i24 + "if _verified:",
    i28 + 'log_output += f"[{_ts8}] [自动抢元宝秒杀] 兑换成功！已斩获【{ename}】(元宝 {_silk_before} -> {_silk_after})\\n"',
    i28 + "await send_system_notification(",
    i28 + '    title="元宝秒杀抢券成功",',
    i28 + '    content=f"账号【{nickname}】成功兑换【{ename}】！",',
    i28 + "    account_key=account_key,",
    i28 + "    event=NotificationEvent.SPIKE_SUCCESS,",
    i28 + "    level=NotificationLevel.SUCCESS",
    i28 + ")",
    i24 + "else:",
    i28 + 'log_output += f"[{_ts8}] [自动抢元宝秒杀] 未抢到：接口已受理但元宝未扣款 (余额 {_silk_before} -> {_silk_after})，判定未兑换成功\\n"',
]
lines[i_try:i_close + 1] = new_block
open(path, "w", encoding="utf-8").write("\n".join(lines))
print("[fix8] success check switched to silk-deduction verification")
PYEOF_FIX8
then
  say "ERROR: 补丁写入失败，备份在 /root/scheduler.py.bak-fix8-$TS"
  exit 1
fi
python3 -m py_compile "$SC" || { say "ERROR: 语法校验失败，不动容器"; exit 1; }
grep -q "\[fix8\]" "$SC" || { say "ERROR: 未见 fix8 标记，终止"; exit 1; }
say "同步进容器并重启…"
docker cp "$SC" "$CONT:/app/backend/app/core/scheduler.py" || exit 1
docker restart "$CONT" >/dev/null
OK=0
for i in $(seq 1 24); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done
if [ "$OK" = "1" ]; then
  say "完成：兑换成功改为余额核验，未扣款不再报成功/推送"
else
  say "ERROR: 健康检查未通过，请把日志截图发给助手"
  exit 1
fi
