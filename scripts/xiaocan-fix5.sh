#!/bin/bash
# xiaocan-fix5.sh — 让小蚕助手「元宝秒杀抢券」任务在日志里列出全部在架商品 ID
#
# 背景：元宝秒杀的「自定义商品ID」填的是商城商品的 exchange_id，但小蚕 App
# 页面上不显示这个编号，只有接口返回里有。原版任务日志只报在架商品数量，
# 不报每个商品的 ID，用户想抢固定一款时无从下手。
# 本补丁：在 flash_sale 任务拉到商品列表后，把每款商品的
# ID / 名称 / 消耗元宝 / 剩余库存逐行打进任务日志。改动仅限日志输出，
# 不改变抢券逻辑。重复运行自动跳过（幂等）。
#
# 用法（华为云运维终端，一行粘贴）：
#   curl -fsSL https://raw.githubusercontent.com/Juziiz/JuziiLab/main/scripts/xiaocan-fix5.sh | bash
#
# 注意：xiaocan-update.sh 已支持升级后自动重打本补丁（检测到旧版有
# 补丁才会打）；手动换源码则需重跑本脚本。
set -u

APP_DIR=/opt/xiaocan-assistant
TARGET="$APP_DIR/backend/app/core/scheduler.py"
STAMP=$(date +%Y%m%d%H%M%S)
BACKUP="/root/scheduler.py.bak-fix5-$STAMP"

say(){ echo "[fix5] $*"; }
die(){ say "ERROR: $*"; exit 1; }

command -v docker >/dev/null 2>&1 || die "没找到 docker"
[ -f "$TARGET" ] || die "找不到 $TARGET"
grep -q "list_flash_sale_exchanges" "$TARGET" || die "目标文件结构不对（找不到 list_flash_sale_exchanges），已中止，未做任何改动"

cp -f "$TARGET" "$BACKUP" || die "备份失败"
say "已备份原文件到 $BACKUP"

export XIAOCAN_FIX5_TARGET="$TARGET"
python3 - <<'PYEOF_FIX5'
import os, sys
path = os.environ["XIAOCAN_FIX5_TARGET"]
src = open(path, encoding="utf-8").read()
if "秒杀商品 ID=" in src:
    print("[fix5] 检测到补丁已存在，跳过写入")
    sys.exit(0)
lines = src.split("\n")
idx = None
for i, ln in enumerate(lines):
    if "元宝商城档期" in ln and "log_output" in ln:
        idx = i
        break
if idx is None:
    print("[fix5] ERROR: 找不到『元宝商城档期』日志行，已中止")
    sys.exit(1)
indent = " " * 16
insert = [
    indent + "for _fs_item in items:",
    indent + "    log_output += f\"[{time.strftime('%H:%M:%S')}] 秒杀商品 ID={_fs_item.get('exchange_id')} 名称={_fs_item.get('goods_name') or '未命名'} 元宝={_fs_item.get('community_silk', 0)} 剩余={_fs_item.get('left', 0)}\\n\"",
]
lines[idx+1:idx+1] = insert
open(path, "w", encoding="utf-8").write("\n".join(lines))
print("[fix5] 已写入商品 ID 列表日志")
PYEOF_FIX5
[ $? -eq 0 ] || { cp -f "$BACKUP" "$TARGET"; die "补丁写入失败，已还原，未做其他改动"; }

grep -q "秒杀商品 ID=" "$TARGET" || { cp -f "$BACKUP" "$TARGET"; die "写入后校验失败，已还原"; }
python3 -m py_compile "$TARGET" || { cp -f "$BACKUP" "$TARGET"; die "语法检查失败，已还原"; }
say "补丁写入并通过语法检查，开始重建容器"

cd "$APP_DIR" || die "进不去 $APP_DIR"
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
if ! $DC up -d --build xiaocan-assistant; then
  say "重建失败，正在回滚"
  cp -f "$BACKUP" "$TARGET"
  $DC up -d --build xiaocan-assistant
  die "已回滚到补丁前版本，请把以上输出截图发给助手"
fi

say "等待健康检查"
ok=0
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  say "健康检查未通过，正在回滚"
  cp -f "$BACKUP" "$TARGET"
  $DC up -d --build xiaocan-assistant
  die "已回滚到补丁前版本，请把以上输出截图发给助手"
fi

say "完成：补丁已生效。现在去助手页面给『元宝秒杀抢券』点一次『立即执行』，打开任务日志就能看到每款商品的 ID、名称、元宝价和剩余库存；把你要抢那款的 ID 填到该任务的『参数 → 秒杀商品ID』里即可。"
