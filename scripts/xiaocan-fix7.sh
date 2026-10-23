#!/usr/bin/env bash
# fix7（增量补丁，须先有 fix6）：元宝秒杀接口实际返回 vip + svip 两个分组，
# 上游代码与 fix6 下拉都只读 vip 组，导致 svip 商品选不到、按 ID 也匹配不上
# （如 202 = svip 大牌券）。本补丁把两个分组一起并入：
#   1) scheduler.py：抢券时的商品池改为合并 list 下全部分组（定向 ID 可命中 svip；
#      自动优选顺序不变，仍先 vip 后 svip）
#   2) endpoints.py：fix6 下拉数据源同样合并全部分组，上限 15 -> 20
# 部署方式：改宿主机源码 -> docker cp 进容器 -> 重启 -> 健康检查（不整场重建，
# 避开国内机 apt 拉 deb.debian.org 卡死的问题）。宿主机源码同步已打补丁，
# 后续重建/升级不丢（update.sh 亦已同步此逻辑）。
# 幂等：两处都打过会直接跳过补丁步骤，仅重新同步进容器。
set -u
APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
EP="$APP_DIR/backend/app/api/endpoints.py"
SC="$APP_DIR/backend/app/core/scheduler.py"
CONT="xiaocan-assistant"
TS="$(date +%Y%m%d%H%M%S)"
say() { echo "[fix7] $*"; }

[ -f "$EP" ] && [ -f "$SC" ] || { say "ERROR: 找不到源码文件（$APP_DIR），退出"; exit 1; }
grep -q "_fs_goods_options" "$EP" || { say "ERROR: 未检测到 fix6，请先装 fix6"; exit 1; }

cp -a "$EP" "/root/endpoints.py.bak-fix7-$TS"
cp -a "$SC" "/root/scheduler.py.bak-fix7-$TS"

export XIAOCAN_EP="$EP" XIAOCAN_SC="$SC"
if ! python3 - <<'PYEOF_FIX7'
import os, sys
ep = os.environ["XIAOCAN_EP"]; sc = os.environ["XIAOCAN_SC"]

# ---- endpoints: 下拉合并全部分组 ----
src = open(ep, encoding="utf-8").read()
old = 'items = (res.get("list") or {}).get("vip") or []'
if old in src:
    ind = " " * 12
    new = ('_lst = res.get("list") or {}\n'
           + ind + 'items = []\n'
           + ind + 'for _grp in _lst.values():\n'
           + ind + '    if isinstance(_grp, list):\n'
           + ind + '        items.extend(_grp)')
    src = src.replace(old, new, 1)
    if 'items[:15]' in src:
        src = src.replace('items[:15]', 'items[:20]', 1)
    open(ep, "w", encoding="utf-8").write(src)
    print("[fix7] endpoints 下拉已合并全部分组")
else:
    print("[fix7] endpoints 已是合并版，跳过")

# ---- scheduler: 商品池合并全部分组 ----
src = open(sc, encoding="utf-8").read()
if 'for _grp in _lst.values():' not in src:
    lines = src.split("\n")
    done = False
    for i, ln in enumerate(lines):
        if '.get("vip")' in ln and 'items' in ln:
            ind = ln[:len(ln) - len(ln.lstrip())]
            lines[i:i+1] = [
                ind + '_lst = fs_res.get("list") or {}',
                ind + 'items = []',
                ind + 'for _grp in _lst.values():',
                ind + '    if isinstance(_grp, list):',
                ind + '        items.extend(_grp)',
            ]
            done = True
            break
    if not done:
        sys.exit(1)
    open(sc, "w", encoding="utf-8").write("\n".join(lines))
    print("[fix7] scheduler 商品池已合并全部分组")
else:
    print("[fix7] scheduler 已是合并版，跳过")
PYEOF_FIX7
then
  say "ERROR: 补丁写入失败，已保留备份在 /root/*.bak-fix7-$TS"
  exit 1
fi

python3 -m py_compile "$EP" "$SC" || { say "ERROR: 语法校验失败，不动容器"; exit 1; }
grep -q 'for _grp in _lst.values():' "$SC" || { say "ERROR: scheduler 未见合并标记，终止"; exit 1; }

say "同步进容器并重启…"
docker cp "$EP" "$CONT:/app/backend/app/api/endpoints.py" || exit 1
docker cp "$SC" "$CONT:/app/backend/app/core/scheduler.py" || exit 1
docker restart "$CONT" >/dev/null

OK=0
for i in $(seq 1 24); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done
if [ "$OK" = "1" ]; then
  say "完成：vip + svip 分组已合并，下拉与抢券逻辑都生效"
else
  say "ERROR: 健康检查未通过，请把这段日志截图发给助手"
  exit 1
fi
