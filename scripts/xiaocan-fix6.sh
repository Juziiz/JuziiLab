#!/bin/bash
# xiaocan-fix6.sh — 元宝秒杀「选商品」下拉 + 日志列 ID（合并补丁）
#
# 做三件事：
#   1. endpoints.py：给 /api/tasks 加一个按账号缓存 10 分钟的商品列表助手，
#      打开「元宝秒杀抢券」任务时把原来的「秒杀商品ID」手填框换成下拉选择，
#      选项实时来自官方 ListFlashSaleExchanges 接口（名称＋元宝价＋剩余库存），
#      第一项是「自动优选」。已保存的商品若已下架，会补一条保底选项防止被清掉。
#      接口拉取失败时自动退回原手填框，不影响使用。
#   2. scheduler.py：若还没有 fix5 的日志补丁，顺带补上（任务日志逐行列出
#      在架商品 ID/名称/元宝/库存）。
#   3. scheduler.py：把商品 ID 的解析改成「提取第一个数字串」，不管下拉存的
#      是纯数字还是带符号格式都不会解析失败。
#
# 幂等：每一处都检测标记，重复运行自动跳过。失败自动回滚两个文件并重建。
#
# 用法（华为云运维终端，分两步防断线）：
#   curl -fsSL https://raw.githubusercontent.com/Juziiz/JuziiLab/main/scripts/xiaocan-fix6.sh -o /root/fix6.sh
#   nohup bash /root/fix6.sh > /root/fix6.log 2>&1 &
#   tail -n 5 /root/fix6.log   # 看结果
#
# 注意：xiaocan-update.sh 已支持升级后自动重打本补丁与 fix5。
set -u

APP_DIR=/opt/xiaocan-assistant
EP="$APP_DIR/backend/app/api/endpoints.py"
SC="$APP_DIR/backend/app/core/scheduler.py"
STAMP=$(date +%Y%m%d%H%M%S)
EP_BAK="/root/endpoints.py.bak-fix6-$STAMP"
SC_BAK="/root/scheduler.py.bak-fix6-$STAMP"

say(){ echo "[fix6] $*"; }
die(){ say "ERROR: $*"; exit 1; }

command -v docker >/dev/null 2>&1 || die "没找到 docker"
[ -f "$EP" ] || die "找不到 $EP"
[ -f "$SC" ] || die "找不到 $SC"
grep -q "async def get_tasks" "$EP" || die "endpoints.py 结构不对（找不到 get_tasks），已中止，未做任何改动"
grep -q "list_flash_sale_exchanges" "$SC" || die "scheduler.py 结构不对，已中止，未做任何改动"

cp -f "$EP" "$EP_BAK" || die "备份 endpoints.py 失败"
cp -f "$SC" "$SC_BAK" || die "备份 scheduler.py 失败"
say "已备份原文件到 $EP_BAK 与 $SC_BAK"

export XIAOCAN_EP="$EP" XIAOCAN_SC="$SC"
python3 - <<'PYEOF_FIX6'
import os, sys
ep_path = os.environ["XIAOCAN_EP"]
sc_path = os.environ["XIAOCAN_SC"]

# ---------- 1. endpoints.py ----------
src = open(ep_path, encoding="utf-8").read()
if "_fs_goods_options" in src:
    print("[fix6] endpoints 下拉补丁已存在，跳过")
else:
    anchor = 'client = XiaoCanClient()'
    if anchor not in src:
        print("[fix6] ERROR: endpoints.py 找不到 client 初始化行，已中止"); sys.exit(1)
    helper = anchor + '''

# [fix6] 元宝秒杀商品下拉数据源：按账号缓存 10 分钟，避免频繁打官方接口
_FS_GOODS_CACHE = {}

async def _fs_goods_options(account_key):
    now = time.time()
    hit = _FS_GOODS_CACHE.get(account_key)
    if hit and now - hit[0] < 600:
        return hit[1]
    options = None
    try:
        acc = db.get_account_by_key(account_key)
        if acc and acc.get("token"):
            res = await client.list_flash_sale_exchanges(
                token=acc["token"], silk_id=acc.get("silk_id"), user_id=acc.get("user_id"),
                city_code=acc.get("city_code") or 440303, is_plus=bool(acc.get("is_plus", 0)))
            _lst = res.get("list") or {}
            items = []
            for _grp in _lst.values():
                if isinstance(_grp, list):
                    items.extend(_grp)
            options = [{"label": "自动优选 - 抢第一款有库存的", "value": ""}]
            for it in items[:20]:
                options.append({
                    "label": f"{it.get('goods_name') or '未命名商品'} - {it.get('community_silk', 0)}元宝 - 剩{it.get('left', 0)}",
                    "value": str(it.get("exchange_id")),
                })
    except Exception:
        options = None
    if options:
        _FS_GOODS_CACHE[account_key] = (now, options)
    return options
'''
    src = src.replace(anchor, helper, 1)

    anchor2 = '        # 查询 APScheduler 中此任务的下一次真实触发时刻'
    if anchor2 not in src:
        print("[fix6] ERROR: endpoints.py 找不到 get_tasks 注入点，已中止"); sys.exit(1)
    inject = '''        if tid == "flash_sale":
            _fs_opts = await _fs_goods_options(account_key)
            if _fs_opts:
                _saved = str(merged_params.get("goods_ids") or "").strip()
                if _saved and _saved not in [o["value"] for o in _fs_opts]:
                    _fs_opts = _fs_opts + [{"label": f"已选商品 {_saved} - 当前不在架", "value": _saved}]
                param_defs = [{"key": "goods_ids", "label": "秒杀商品", "def": "", "type": "select", "options": _fs_opts, "hint": "选好保存后，到点只抢这款；选自动优选则抢第一款有库存的"}]

''' + anchor2
    src = src.replace(anchor2, inject, 1)
    open(ep_path, "w", encoding="utf-8").write(src)
    print("[fix6] endpoints 下拉补丁已写入")

# ---------- 2. scheduler.py：fix5 日志 ----------
src = open(sc_path, encoding="utf-8").read()
changed = False
if "秒杀商品 ID=" in src:
    print("[fix6] scheduler 日志补丁已存在，跳过")
else:
    lines = src.split("\n")
    idx = None
    for i, ln in enumerate(lines):
        if "元宝商城档期" in ln and "log_output" in ln:
            idx = i
            break
    if idx is None:
        print("[fix6] ERROR: scheduler.py 找不到『元宝商城档期』日志行，已中止"); sys.exit(1)
    indent = " " * 16
    insert = [
        indent + "for _fs_item in items:",
        indent + "    log_output += f\"[{time.strftime('%H:%M:%S')}] 秒杀商品 ID={_fs_item.get('exchange_id')} 名称={_fs_item.get('goods_name') or '未命名'} 元宝={_fs_item.get('community_silk', 0)} 剩余={_fs_item.get('left', 0)}\\n\"",
    ]
    lines[idx+1:idx+1] = insert
    src = "\n".join(lines)
    changed = True
    print("[fix6] scheduler 日志补丁已写入")

# ---------- 3. scheduler.py：ID 解析加固 ----------
old_parse = 'target_id = int(goods_ids.split(",")[0].strip())'
if old_parse in src:
    new_parse = 'target_id = int("".join(ch for ch in goods_ids.split(",")[0] if ch.isdigit()) or -1)'
    src = src.replace(old_parse, new_parse, 1)
    changed = True
    print("[fix6] scheduler ID 解析已加固")
else:
    print("[fix6] scheduler ID 解析已是加固版或结构不同，跳过")

# ---------- 4. scheduler.py：商品池合并 vip+svip 分组 ----------
if "_lst = fs_res.get(" in src:
    print("[fix6] scheduler 商品池已是合并版，跳过")
else:
    _lines = src.split("\n")
    for _i, _ln in enumerate(_lines):
        if '.get("vip")' in _ln and "items" in _ln:
            _ind = _ln[:len(_ln) - len(_ln.lstrip())]
            _lines[_i:_i+1] = [
                _ind + '_lst = fs_res.get("list") or {}',
                _ind + "items = []",
                _ind + "for _grp in _lst.values():",
                _ind + "    if isinstance(_grp, list):",
                _ind + "        items.extend(_grp)",
            ]
            src = "\n".join(_lines)
            changed = True
            print("[fix6] scheduler 商品池已合并 vip+svip 分组")
            break

if changed:
    open(sc_path, "w", encoding="utf-8").write(src)
PYEOF_FIX6
if [ $? -ne 0 ]; then
  cp -f "$EP_BAK" "$EP"; cp -f "$SC_BAK" "$SC"
  die "补丁写入失败，已还原两个文件，未做其他改动"
fi

grep -q "_fs_goods_options" "$EP" || { cp -f "$EP_BAK" "$EP"; cp -f "$SC_BAK" "$SC"; die "写入后校验失败，已还原"; }
python3 -m py_compile "$EP" || { cp -f "$EP_BAK" "$EP"; cp -f "$SC_BAK" "$SC"; die "endpoints.py 语法检查失败，已还原"; }
python3 -m py_compile "$SC" || { cp -f "$EP_BAK" "$EP"; cp -f "$SC_BAK" "$SC"; die "scheduler.py 语法检查失败，已还原"; }
say "补丁写入并通过语法检查，开始重建容器"

cd "$APP_DIR" || die "进不去 $APP_DIR"
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

rollback() {
  say "!! 重建/验活失败，开始回滚…"
  cp -f "$EP_BAK" "$EP"; cp -f "$SC_BAK" "$SC"
  $DC up -d --build xiaocan-assistant
  die "已回滚到补丁前版本，请把日志截图发给助手"
}

$DC up -d --build xiaocan-assistant || rollback

say "等待健康检查"
ok=0
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = "1" ] || rollback

say "完成：补丁已生效。刷新助手页面，打开『元宝秒杀抢券』任务，参数里会多出『秒杀商品』下拉，选好商品、设好时间保存即可。"
