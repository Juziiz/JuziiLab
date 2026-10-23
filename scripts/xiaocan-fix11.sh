#!/usr/bin/env bash
# fix11：状态诚实化。元宝秒杀未抢到（fix9 已核验未扣款）时把本次运行状态记为
# error，日志列表/首页动态不再显示「成功」；大牌券 3 次尝试全失败同理记 error，
# 并补一行「本场未抢到」。部署：改宿主机源码 -> docker cp -> 重启 -> 验活。幂等。
set -u
APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
SC="$APP_DIR/backend/app/core/scheduler.py"
CONT="xiaocan-assistant"
TS="$(date +%Y%m%d%H%M%S)"
say() { echo "[fix11] $*"; }
[ -f "$SC" ] || { say "ERROR: 找不到 scheduler.py，退出"; exit 1; }
cp -a "$SC" "/root/scheduler.py.bak-fix11-$TS"
export XIAOCAN_SC="$SC"
if ! python3 - <<'PYEOF_FIX11'
import os, sys
path = os.environ["XIAOCAN_SC"]
src = open(path, encoding="utf-8").read()
if "[fix11]" in src:
    print("[fix11] already applied, skip")
    sys.exit(0)
lines = src.split("\n")
out = []
changed = 0
for ln in lines:
    out.append(ln)
    # 1) flash_sale: 未抢到 -> status = "error"
    if "判定未兑换成功" in ln and "log_output" in ln:
        ind = ln[:len(ln) - len(ln.lstrip())]
        out.append(ind + "status = \"error\"  # [fix11] 未抢到不算成功")
        changed += 1
    # 2) brand_flash: 初始化抢到标记（只认整点直射那处循环，上方有专属注释）
    if ln.strip() == "for try_idx in range(1, 4):" and "_bf_grabbed" not in src:
        prev = "\n".join(lines[max(0, len(out) - 4):len(out)])
        owner = next((x for x in reversed(out) if "elif task_id ==" in x), "")
        if "Zero-latency Burst" in prev and "brand_flash" in owner:
            ind = ln[:len(ln) - len(ln.lstrip())]
            out[-1] = ind + "_bf_grabbed = False  # [fix11]\n" + ln
            changed += 1
    # 3) brand_flash: 真正受理成功时打标记
    if "抢券成功！已成功领取" in ln and "log_output" in ln:
        ind = ln[:len(ln) - len(ln.lstrip())]
        out.append(ind + "_bf_grabbed = True")
        changed += 1
    # 4) brand_flash: 循环结束仍未抢到 -> status = "error"
    if ln.startswith("        elif task_id == \"yb_task\":"):
        ind16 = " " * 16
        out[-1] = (
            ind16 + "if can_burst and not _bf_grabbed:\n"
            + ind16 + "    status = \"error\"\n"
            + ind16 + "    log_output += f\"[{time_service.format_now()}] [抢每日大牌券] 本场未抢到: 多次尝试均未成功\\n\"\n"
            + ln
        )
        changed += 1
if changed < 4:
    print(f"[fix11] anchors incomplete: only {changed}/4 spots patched")
    sys.exit(1)
open(path, "w", encoding="utf-8").write("\n".join(out))
print(f"[fix11] status honesty patched at {changed} spots")
PYEOF_FIX11
then
  say "ERROR: 补丁写入失败，备份在 /root/scheduler.py.bak-fix11-$TS"
  exit 1
fi
python3 -m py_compile "$SC" || { say "ERROR: 语法校验失败，不动容器"; exit 1; }
grep -q "\[fix11\]" "$SC" || { say "ERROR: 未见 fix11 标记，终止"; exit 1; }
say "同步进容器并重启…"
docker cp "$SC" "$CONT:/app/backend/app/core/scheduler.py" || exit 1
docker restart "$CONT" >/dev/null
OK=0
for i in $(seq 1 24); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done
if [ "$OK" = "1" ]; then
  say "完成：未抢到的运行不再显示成功（状态记为失败）"
else
  say "ERROR: 健康检查未通过，请把日志截图发给助手"
  exit 1
fi
