#!/usr/bin/env bash
# fix9：修正 fix8 的核验字段。元宝余额不在 get_user_info 的 silk（那是蚕丝，
# 大号 silk=2400 而元宝=70618），而在 UserTaskV2 的 data.yb_point。
# 本补丁：已打 fix8 的文件就地改读 yb_point；没打过的直接装正确版。
# 部署：改宿主机源码 -> docker cp 进容器 -> 重启 -> 健康检查。幂等可重复跑。
set -u
APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
SC="$APP_DIR/backend/app/core/scheduler.py"
CONT="xiaocan-assistant"
TS="$(date +%Y%m%d%H%M%S)"
say() { echo "[fix9] $*"; }
[ -f "$SC" ] || { say "ERROR: 找不到 scheduler.py，退出"; exit 1; }
cp -a "$SC" "/root/scheduler.py.bak-fix9-$TS"
export XIAOCAN_SC="$SC"
if ! python3 - <<'PYEOF_FIX9'
import os, re, sys
path = os.environ["XIAOCAN_SC"]
src = open(path, encoding="utf-8").read()

if "[fix9]" in src:
    print("[fix9] already applied, skip")
    sys.exit(0)

if "[fix8]" in src:
    # transform fix8's wrong-field reads to UserTaskV2 yb_point
    out = []
    n = 0
    for ln in src.split("\n"):
        if "_ui0 = await client.get_user_info(" in ln or "_ui2 = await client.get_user_info(" in ln:
            ln = ln.replace("client.get_user_info(", "client.get_user_task_v2(")
            n += 1
        if '(_ui0.get("user_info") or {}).get("silk")' in ln:
            ln = ln.replace('(_ui0.get("user_info") or {}).get("silk")', '(_ui0.get("data") or {}).get("yb_point")')
            n += 1
        if '(_ui2.get("user_info") or {}).get("silk")' in ln:
            ln = ln.replace('(_ui2.get("user_info") or {}).get("silk")', '(_ui2.get("data") or {}).get("yb_point")')
            n += 1
        if "# [fix8]" in ln:
            ln = ln.replace("# [fix8]", "# [fix9]")
            n += 1
        out.append(ln)
    if n < 5:
        print(f"[fix9] transform incomplete: only {n} spots changed")
        sys.exit(1)
    open(path, "w", encoding="utf-8").write("\n".join(out))
    print(f"[fix9] fix8 field corrected at {n} spots (yb_point via UserTaskV2)")
    sys.exit(0)

# fresh: generate the whole verification block with the correct field
m = re.search(r"client\.today_exchange\(exchange_id=eid,\s*(token=[^,]+),", src)
if not m:
    print("[fix9] today_exchange call not found")
    sys.exit(1)
tok = m.group(1)
lines = src.split("\n")
idx_t = next((i for i, ln in enumerate(lines) if ln.strip() == "target_item = None"), None)
if idx_t is None:
    print("[fix9] target_item anchor not found")
    sys.exit(1)
ind16 = " " * 16
before_block = [
    ind16 + "_silk_before = None",
    ind16 + "try:",
    ind16 + "    _ui0 = await client.get_user_task_v2(" + tok + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
    ind16 + '    _silk_before = (_ui0.get("data") or {}).get("yb_point")',
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
    i24 + "# [fix9] no-error != success: only an actual yb_point deduction counts",
    i24 + "_verified = False",
    i24 + "_silk_after = None",
    i24 + "for _vt in range(3):",
    i28 + "await asyncio.sleep(1.0)",
    i28 + "try:",
    i28 + "    _ui2 = await client.get_user_task_v2(" + tok + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
    i28 + '    _silk_after = (_ui2.get("data") or {}).get("yb_point")',
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
print("[fix9] verification block installed (yb_point via UserTaskV2)")
PYEOF_FIX9
then
  say "ERROR: 补丁写入失败，备份在 /root/scheduler.py.bak-fix9-$TS"
  exit 1
fi
python3 -m py_compile "$SC" || { say "ERROR: 语法校验失败，不动容器"; exit 1; }
grep -q "\[fix9\]" "$SC" || { say "ERROR: 未见 fix9 标记，终止"; exit 1; }
say "同步进容器并重启…"
docker cp "$SC" "$CONT:/app/backend/app/core/scheduler.py" || exit 1
docker restart "$CONT" >/dev/null
OK=0
for i in $(seq 1 24); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done
if [ "$OK" = "1" ]; then
  say "完成：成功判定已改用元宝 yb_point 扣款核验"
else
  say "ERROR: 健康检查未通过，请把日志截图发给助手"
  exit 1
fi
