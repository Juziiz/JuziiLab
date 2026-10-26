#!/bin/bash
# 小蚕小帮手 一键更新脚本 v1.0.2 热补丁专版（华为云 Flexus 那套专用）
# 本版 = xiaocan-update.sh + 两处改动，专用于从 v1.0.1 升 v1.0.2：
#   1. 换源码后、重构建前，给 backend/app/core/scheduler.py 补 Set import
#      （上游 v1.0.2 第 12 行漏 import，第 94 行却用了 Set[str]，不补则
#       模块加载即 NameError、/health 通不过、脚本会回滚；补一行即可）
#   2. 本轮不重打旧 fix5/fix6/fix9/fix11（它们针对老版 scheduler/endpoints，
#      新版已重写、锚点对不上，硬打会打坏新版；新版诚实状态补丁另行做）
# 其余流程与原脚本一致：备份、保留 data/nginx/.htpasswd/override、失败回滚。
#
# 小蚕小帮手 一键更新脚本（华为云 Flexus 那套专用）
#
# 它做什么：
#   1. 查上游 AkiSeele/xiaocan-assistant 的 main 分支最新提交，和本地比对
#   2. 已是最新版 → 直接退出，不动任何东西
#   3. 有新版 → 先把整个 /opt/xiaocan-assistant 打包备份到 /root/xiaocan-backups/
#      （只留最近 3 份），再换新源码、重构建、验活
#   4. 构建失败或验活不过 → 自动用备份回滚到旧版并重构建，不会把服务弄挂不管
#
# 保留不动的本地东西（换源码时不会被覆盖）：
#   data/                            账号、任务、数据库全在这里
#   .htpasswd / nginx.conf / nginx-main.conf / docker-compose.override.yml
#                                    8691 门禁与反代，是咱们部署时自加的，上游没有
#   /root/xiaocan-access.txt        门禁密码文件，本来就不在源码目录里
#
# 本地补丁提醒：若宿主机 backend/app/core/jwt_utils.py 里有 fix4 补丁
# （含 _join_wrapped_header_lines 字样）而上游新版没有，脚本不会拿旧文件
# 覆盖新版，只会在结束时提醒「补丁需重打」，补丁原文件在备份包里能找回。
#
# 本地补丁自动重打：若旧版 backend/app/core/scheduler.py 里有 fix5 补丁
# （含「秒杀商品 ID=」字样，作用是让元宝秒杀任务日志列出全部商品 ID），
# 换新源码并验活通过后，脚本会自动把补丁重打到新版、再构建验活一次；
# 若上游改了结构导致打不上，只提醒、不影响更新结果。仅由这两处补丁
# 造成的本地差异不算上游更新，不会误报新版。
#
# fix6 补丁（endpoints.py 含 _fs_goods_options 字样：元宝秒杀商品下拉选择，
# 附带 scheduler.py 的 ID 解析加固）同理：升级后自动重打、再构建验活；
# 打不上只提醒。由它造成的 endpoints.py 本地差异同样不算上游更新。
#
# 用法：
#   bash xiaocan-update.sh            正常更新（无新版会自己退出）
#   bash xiaocan-update.sh --check    只检查有没有新版，不动服务
# 建议配日志跑：
#   nohup bash xiaocan-update.sh > /root/xiaocan-update.log 2>&1 &
set -u
export PATH=$PATH:/usr/local/bin

MODE="update"
[ "${1:-}" = "--check" ] && MODE="check"

APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
BACKUP_DIR="${XIAOCAN_BACKUP_DIR:-/root/xiaocan-backups}"
SHA_FILE="$APP_DIR/.upstream-sha"
PATCH_REL="backend/app/core/jwt_utils.py"
PATCH_MARK="_join_wrapped_header_lines"
FIX5_REL="backend/app/core/scheduler.py"
FIX5_MARK="秒杀商品 ID="
FIX6_REL="backend/app/api/endpoints.py"
FIX6_MARK="_fs_goods_options"
REPO_ZIP="https://codeload.github.com/AkiSeele/xiaocan-assistant/zip/refs/heads/main"
REPO_API="https://api.github.com/repos/AkiSeele/xiaocan-assistant/commits/main"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { echo "[xiaocan-update] $*"; }
die() { say "ERROR: $*"; exit 1; }

[ -d "$APP_DIR" ] || die "找不到 $APP_DIR，这台机器上没部署过小蚕助手？"
[ -f "$APP_DIR/Dockerfile" ] || die "$APP_DIR 里没有 Dockerfile，源码目录不对，已中止"

# ---------- 1. 查上游最新提交 ----------
REMOTE_SHA=""
if command -v curl >/dev/null 2>&1; then
  REMOTE_SHA="$(curl -fsSL "$REPO_API" 2>/dev/null | grep -m1 '"sha"' | sed 's/.*"sha": *"\([0-9a-f]*\)".*/\1/' || true)"
fi
LOCAL_SHA=""
[ -f "$SHA_FILE" ] && LOCAL_SHA="$(awk 'NR==1{print $1}' "$SHA_FILE")"
if [ -n "$REMOTE_SHA" ]; then
  say "上游最新提交: $REMOTE_SHA"
else
  say "WARN: GitHub API 没查到最新提交（网络问题？），改用文件逐个比对判断"
fi
say "本地记录提交: ${LOCAL_SHA:-（无记录，首次运行将以文件比对为准）}"

# ---------- 2. 下载新版源码到临时目录 ----------
WORK="$(mktemp -d /tmp/xiaocan-update.XXXXXX)" || die "建临时目录失败"
trap 'rm -rf "$WORK"' EXIT
say "下载上游最新源码…"
curl -fsSL -o "$WORK/xiaocan.zip" "$REPO_ZIP" || die "源码下载失败，线上服务未动"
mkdir -p "$WORK/src"
if command -v unzip >/dev/null 2>&1; then
  unzip -o -q "$WORK/xiaocan.zip" -d "$WORK/src" || die "解压失败，线上服务未动"
else
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$WORK/xiaocan.zip" "$WORK/src" || die "解压失败，线上服务未动"
fi
NEW_SRC="$WORK/src/xiaocan-assistant-main"
[ -f "$NEW_SRC/Dockerfile" ] && [ -f "$NEW_SRC/docker-compose.yml" ] || die "下载的源码不完整（缺 Dockerfile / docker-compose.yml），已中止，线上服务未动"

# 与部署时保持一致：应用端口只绑本机，外面走 8691 门禁
sed -i 's/"8690:8690"/"127.0.0.1:8690:8690"/' "$NEW_SRC/docker-compose.yml"

# ---------- 3. 比对：有没有新版 ----------
PATCH_LOCAL=0
grep -q "$PATCH_MARK" "$APP_DIR/$PATCH_REL" 2>/dev/null && PATCH_LOCAL=1
PATCH_UPSTREAM=0
grep -q "$PATCH_MARK" "$NEW_SRC/$PATCH_REL" 2>/dev/null && PATCH_UPSTREAM=1
FIX5_LOCAL=0
grep -q "$FIX5_MARK" "$APP_DIR/$FIX5_REL" 2>/dev/null && FIX5_LOCAL=1
FIX5_UPSTREAM=0
grep -q "$FIX5_MARK" "$NEW_SRC/$FIX5_REL" 2>/dev/null && FIX5_UPSTREAM=1
FIX6_LOCAL=0
grep -q "$FIX6_MARK" "$APP_DIR/$FIX6_REL" 2>/dev/null && FIX6_LOCAL=1
FIX6_UPSTREAM=0
grep -q "$FIX6_MARK" "$NEW_SRC/$FIX6_REL" 2>/dev/null && FIX6_UPSTREAM=1

DIFF_OUT="$WORK/diff.txt"
diff -rq \
  -x 'data' -x '.htpasswd' -x 'nginx.conf' -x 'nginx-main.conf' \
  -x 'docker-compose.override.yml' -x '.upstream-sha' \
  -x '__pycache__' -x 'node_modules' -x '.DS_Store' \
  "$NEW_SRC" "$APP_DIR" > "$DIFF_OUT" 2>/dev/null || true
# 只有本地补丁（fix4 的 jwt_utils.py / fix5 的 scheduler.py）造成的差异，不算上游更新
if [ "$PATCH_LOCAL" = "1" ] && [ "$PATCH_UPSTREAM" = "0" ]; then
  grep -v "jwt_utils\.py" "$DIFF_OUT" > "$WORK/diff2.txt" || true
  mv "$WORK/diff2.txt" "$DIFF_OUT"
fi
if [ "$FIX5_LOCAL" = "1" ] && [ "$FIX5_UPSTREAM" = "0" ]; then
  grep -v "scheduler\.py" "$DIFF_OUT" > "$WORK/diff2.txt" || true
  mv "$WORK/diff2.txt" "$DIFF_OUT"
fi
if [ "$FIX6_LOCAL" = "1" ] && [ "$FIX6_UPSTREAM" = "0" ]; then
  grep -v "endpoints\.py" "$DIFF_OUT" > "$WORK/diff2.txt" || true
  mv "$WORK/diff2.txt" "$DIFF_OUT"
fi

if [ -n "$REMOTE_SHA" ] && [ -n "$LOCAL_SHA" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
  say "已是最新版（提交一致），无需更新"
  exit 0
fi
if [ ! -s "$DIFF_OUT" ]; then
  say "已是最新版（文件比对无差异），无需更新"
  # 补写基线，方便下次直接按提交号判断
  if [ -n "$REMOTE_SHA" ]; then
    echo "$REMOTE_SHA $STAMP" > "$SHA_FILE" 2>/dev/null || true
  fi
  exit 0
fi

say "检测到新版，变更文件如下："
sed 's/^/    /' "$DIFF_OUT" | head -n 30

if [ "$MODE" = "check" ]; then
  say "（--check 模式）只检查不更新，服务未动"
  exit 0
fi

# v1.0.2 专版：旧补丁不重打（见头注第 2 条）
FIX5_LOCAL=0
FIX6_LOCAL=0

# ---------- 4. 找 compose 命令 ----------
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  die "找不到 docker compose，无法重构建，已中止（源码未换）"
fi
command -v docker >/dev/null 2>&1 || die "找不到 docker，已中止"

# ---------- 5. 全量备份 ----------
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/xiaocan-backup-$STAMP.tar.gz"
say "备份当前版本到 $BACKUP_FILE …"
tar -czf "$BACKUP_FILE" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" \
  || die "备份失败，已中止（源码未换）"
# 只留最近 3 份备份
ls -1t "$BACKUP_DIR"/xiaocan-backup-*.tar.gz 2>/dev/null | tail -n +4 | while read -r old; do
  rm -f "$old"; say "清理旧备份: $old"
done

rollback() {
  say "!! 更新失败，开始回滚到备份版本…"
  rm -rf "$APP_DIR"
  tar -xzf "$BACKUP_FILE" -C "$(dirname "$APP_DIR")" || { say "!! 回滚解包也失败，备份在 $BACKUP_FILE，请找助手处理"; exit 1; }
  cd "$APP_DIR" || exit 1
  $COMPOSE up -d --build || { say "!! 回滚重构建失败，请找助手处理（备份在 $BACKUP_FILE）"; exit 1; }
  say "已回滚到更新前的版本。备份保留在 $BACKUP_FILE"
  exit 1
}

# ---------- 6. 换源码（保留本地文件） ----------
PRESERVE="$WORK/preserve"
mkdir -p "$PRESERVE"
for f in .htpasswd nginx.conf nginx-main.conf docker-compose.override.yml; do
  [ -f "$APP_DIR/$f" ] && cp -f "$APP_DIR/$f" "$PRESERVE/$f"
done
PATCH_BACKUP=""
if [ "$PATCH_LOCAL" = "1" ]; then
  cp -f "$APP_DIR/$PATCH_REL" "$PRESERVE/jwt_utils.fix4.py"
  PATCH_BACKUP="$PRESERVE/jwt_utils.fix4.py"
fi

say "替换源码…"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude 'data' --exclude '.htpasswd' --exclude 'nginx.conf' \
    --exclude 'nginx-main.conf' --exclude 'docker-compose.override.yml' \
    --exclude '.upstream-sha' \
    "$NEW_SRC/" "$APP_DIR/" || die "源码同步失败，已中止（数据未动，可重跑本脚本）"
else
  cp -rf "$NEW_SRC"/. "$APP_DIR"/ || die "源码复制失败，已中止（数据未动，可重跑本脚本）"
  say "WARN: 本机没有 rsync，上游已删除的文件不会自动清理（一般不影响使用）"
fi
cd "$APP_DIR" || die "进不去 $APP_DIR"

# 保留文件兜底：万一被误删就从暂存恢复
for f in .htpasswd nginx.conf nginx-main.conf docker-compose.override.yml; do
  if [ ! -f "$APP_DIR/$f" ] && [ -f "$PRESERVE/$f" ]; then
    cp -f "$PRESERVE/$f" "$APP_DIR/$f"; say "已恢复本地文件: $f"
  fi
done
if [ ! -d "$APP_DIR/data" ]; then
  say "WARN: data 目录不见了，从备份恢复…"
  tar -xzf "$BACKUP_FILE" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")/data" || die "data 恢复失败！备份在 $BACKUP_FILE，请立刻找助手处理"
fi

# 门禁/反代文件若全缺（异常情况），按部署时的版本重新生成
if [ ! -f "$APP_DIR/docker-compose.override.yml" ]; then
  say "WARN: override 不存在，按部署版重新生成门禁配置…"
  ACCESS_FILE=/root/xiaocan-access.txt
  [ -f "$ACCESS_FILE" ] || die "override 与 $ACCESS_FILE 都不存在，无法重建门禁，请找助手处理（已回滚前请先备份）"
  PASS="$(grep '^pass:' "$ACCESS_FILE" | awk '{print $2}')"
  HASH="$(openssl passwd -apr1 "$PASS")"
  echo "ju:$HASH" > "$APP_DIR/.htpasswd"
  cat > "$APP_DIR/nginx.conf" <<'NGINX'
server {
    listen 80;
    auth_basic "xiaocan";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://xiaocan-assistant:8690;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
NGINX
  cat > "$APP_DIR/nginx-main.conf" <<'MAIN'
user nginx;
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr notice;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    sendfile on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
MAIN
  cat > "$APP_DIR/docker-compose.override.yml" <<'OVERRIDE'
services:
  web:
    image: nginx:alpine
    container_name: xiaocan-web
    restart: unless-stopped
    security_opt:
      - seccomp=unconfined
    ports:
      - "8691:80"
    volumes:
      - ./nginx-main.conf:/etc/nginx/nginx.conf:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./.htpasswd:/etc/nginx/.htpasswd:ro
    tmpfs:
      - /tmp
      - /run
    depends_on:
      - xiaocan-assistant
OVERRIDE
fi

# ---------- 6.5 v1.0.2 热补丁：scheduler.py 补 Set import ----------
FIX102_REL="backend/app/core/scheduler.py"
if grep -q "from typing import Dict, Any, Optional, Tuple" "$APP_DIR/$FIX102_REL" && ! grep -q "from typing import.*Set" "$APP_DIR/$FIX102_REL"; then
  say "打 v1.0.2 热补丁：给 scheduler.py 补 Set import…"
  sed -i 's/from typing import Dict, Any, Optional, Tuple/from typing import Dict, Any, Optional, Tuple, Set/' "$APP_DIR/$FIX102_REL" || die "热补丁写入失败，已中止（数据未动，可重跑）"
fi
grep -q "from typing import.*Set" "$APP_DIR/$FIX102_REL" || die "热补丁未生效：scheduler.py 里仍无 Set import，已中止"
python3 -m py_compile "$APP_DIR/$FIX102_REL" || die "热补丁后 scheduler.py 编译失败，已中止"
say "v1.0.2 热补丁已生效：scheduler.py 已含 Set import"

# ---------- 7. 重构建 + 验活 ----------
say "重构建并启动（约 3-10 分钟）…"
$COMPOSE up -d --build || rollback

say "等待健康检查…"
OK=0
for i in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1 || docker exec xiaocan-assistant python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8690/health')" >/dev/null 2>&1; then
    OK=1; break
  fi
  sleep 5
done
$COMPOSE ps || true
if [ "$OK" != "1" ]; then
  say "新版健康检查未通过，最近日志："
  $COMPOSE logs --tail=40 xiaocan-assistant || true
  rollback
fi
CODE1="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8691/ 2>/dev/null || true)"
[ -n "$CODE1" ] || CODE1=000
say "门禁验证: 未登录访问 8691 返回 $CODE1（预期 401）"

# ---------- 7.5 自动重打 fix5 补丁（元宝秒杀日志列商品 ID） ----------
if [ "$FIX5_LOCAL" = "1" ] && [ "$FIX5_UPSTREAM" = "0" ]; then
  say "检测到旧版有 fix5 补丁，正在给新版自动重打…"
  export XIAOCAN_FIX5_TARGET="$APP_DIR/$FIX5_REL"
  if python3 - <<'PYEOF_FIX5'
import os, sys
path = os.environ["XIAOCAN_FIX5_TARGET"]
src = open(path, encoding="utf-8").read()
if "秒杀商品 ID=" in src:
    sys.exit(0)
lines = src.split("\n")
idx = None
for i, ln in enumerate(lines):
    if "元宝商城档期" in ln and "log_output" in ln:
        idx = i
        break
if idx is None:
    sys.exit(1)
indent = " " * 16
insert = [
    indent + "for _fs_item in items:",
    indent + "    log_output += f\"[{time.strftime('%H:%M:%S')}] 秒杀商品 ID={_fs_item.get('exchange_id')} 名称={_fs_item.get('goods_name') or '未命名'} 元宝={_fs_item.get('community_silk', 0)} 剩余={_fs_item.get('left', 0)}\\n\"",
]
lines[idx+1:idx+1] = insert
src2 = "\n".join(lines)
_old_parse = 'target_id = int(goods_ids.split(",")[0].strip())'
if _old_parse in src2:
    src2 = src2.replace(_old_parse, 'target_id = int("".join(ch for ch in goods_ids.split(",")[0] if ch.isdigit()) or -1)', 1)
if "_lst = fs_res.get(" not in src2:
    _lines2 = src2.split("\n")
    for _i2, _ln2 in enumerate(_lines2):
        if '.get("vip")' in _ln2 and "items" in _ln2:
            _ind2 = _ln2[:len(_ln2) - len(_ln2.lstrip())]
            _lines2[_i2:_i2+1] = [
                _ind2 + '_lst = fs_res.get("list") or {}',
                _ind2 + "items = []",
                _ind2 + "for _grp in _lst.values():",
                _ind2 + "    if isinstance(_grp, list):",
                _ind2 + "        items.extend(_grp)",
            ]
            src2 = "\n".join(_lines2)
            break

# ---------- 5. scheduler.py：fix9 兑换成功改为元宝(yb_point)扣款核验 ----------
import re as _re8
if "[fix9]" in src2:
    print("[update] scheduler fix9 核验已在，跳过")
else:
    _m8 = _re8.search(r"client\.today_exchange\(exchange_id=eid,\s*(token=[^,]+),", src2)
    if not _m8:
        print("[update] WARN: 未找到 today_exchange，fix9 跳过")
    else:
        _tok8 = _m8.group(1)
        _lines8 = src2.split("\n")
        _idx_t8 = next((i for i, ln in enumerate(_lines8) if ln.strip() == "target_item = None"), None)
        _i_ex8 = next(i for i, ln in enumerate(_lines8) if "ex_res = await client.today_exchange" in ln)
        _i_try8 = _i_ex8 - 1
        _i_end8 = next(i for i in range(_i_ex8, len(_lines8)) if "level=NotificationLevel.SUCCESS" in _lines8[i])
        _i_close8 = _i_end8 + 1
        if _idx_t8 is None or _lines8[_i_try8].strip() != "try:" or _lines8[_i_close8].strip() != ")":
            print("[update] WARN: fix9 锚点不符，跳过")
        else:
            _ind16 = " " * 16
            _before8 = [
                _ind16 + "_silk_before = None",
                _ind16 + "try:",
                _ind16 + "    _ui0 = await client.get_user_task_v2(" + _tok8 + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
                _ind16 + '    _silk_before = (_ui0.get("data") or {}).get("yb_point")',
                _ind16 + "except Exception:",
                _ind16 + "    _silk_before = None",
            ]
            _lines8[_idx_t8:_idx_t8] = _before8
            _shift8 = len(_before8)
            _i_try8 += _shift8; _i_close8 += _shift8; _i_ex8 += _shift8
            _i20 = " " * 20; _i24 = " " * 24; _i28 = " " * 28
            _new8 = [
                _i20 + "try:",
                _i24 + "ex_res = await client.today_exchange(exchange_id=eid, " + _tok8 + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
                _i24 + "# [fix9] no-error != success: only an actual silk deduction counts",
                _i24 + "_verified = False",
                _i24 + "_silk_after = None",
                _i24 + "for _vt in range(3):",
                _i28 + "await asyncio.sleep(1.0)",
                _i28 + "try:",
                _i28 + "    _ui2 = await client.get_user_task_v2(" + _tok8 + ", silk_id=silk_id, user_id=user_id, city_code=city_code)",
                _i28 + '    _silk_after = (_ui2.get("data") or {}).get("yb_point")',
                _i28 + "except Exception:",
                _i28 + "    _silk_after = None",
                _i28 + "if _silk_before is not None and _silk_after is not None and (_silk_before - _silk_after) >= max(int(esilk or 0), 1):",
                _i28 + "    _verified = True",
                _i28 + "    break",
                _i24 + "_ts8 = datetime.now().strftime('%H:%M:%S.%f')[:-3]",
                _i24 + "if _verified:",
                _i28 + 'log_output += f"[{_ts8}] [自动抢元宝秒杀] 兑换成功！已斩获【{ename}】(元宝 {_silk_before} -> {_silk_after})\\n"',
                _i28 + "await send_system_notification(",
                _i28 + '    title="元宝秒杀抢券成功",',
                _i28 + '    content=f"账号【{nickname}】成功兑换【{ename}】！",',
                _i28 + "    account_key=account_key,",
                _i28 + "    event=NotificationEvent.SPIKE_SUCCESS,",
                _i28 + "    level=NotificationLevel.SUCCESS",
                _i28 + ")",
                _i24 + "else:",
                _i28 + 'log_output += f"[{_ts8}] [自动抢元宝秒杀] 未抢到：接口已受理但元宝未扣款 (余额 {_silk_before} -> {_silk_after})，判定未兑换成功\\n"',
            ]
            _lines8[_i_try8:_i_close8 + 1] = _new8
            src2 = "\n".join(_lines8)
            pass
            print("[update] scheduler fix9 余额核验已写入")

open(path, "w", encoding="utf-8").write(src2)
PYEOF_FIX5
  then
  XIAOCAN_SC="$APP_DIR/$FIX5_REL" python3 - <<'PYEOF_FIX11' || say "WARN: fix11 状态补丁未打上，已跳过（不影响更新），请找助手手动处理"
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
    if grep -q "$FIX5_MARK" "$APP_DIR/$FIX5_REL" && python3 -m py_compile "$APP_DIR/$FIX5_REL"; then
      say "fix5 补丁已重打，重新构建生效…"
      $COMPOSE up -d --build || rollback
      OK2=0
      for i in $(seq 1 40); do
        if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1 || docker exec xiaocan-assistant python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8690/health')" >/dev/null 2>&1; then
          OK2=1; break
        fi
        sleep 5
      done
      [ "$OK2" = "1" ] || { say "重打 fix5 后健康检查未通过"; rollback; }
      say "fix5 补丁重打完成并通过健康检查"
    else
      say "WARN: fix5 补丁写入校验失败，已跳过（不影响新版使用），请找助手手动处理"
    fi
  else
    say "WARN: fix5 补丁未能自动重打（上游结构可能变了），已跳过（不影响新版使用），请找助手手动处理"
  fi
fi

# ---------- 7.6 自动重打 fix6 补丁（元宝秒杀商品下拉选择） ----------
if [ "$FIX6_LOCAL" = "1" ] && [ "$FIX6_UPSTREAM" = "0" ]; then
  say "检测到旧版有 fix6 补丁，正在给新版自动重打…"
  export XIAOCAN_FIX6_TARGET="$APP_DIR/$FIX6_REL"
  if python3 - <<'PYEOF_FIX6'
import os, sys
path = os.environ["XIAOCAN_FIX6_TARGET"]
src = open(path, encoding="utf-8").read()
if "_fs_goods_options" in src:
    sys.exit(0)
anchor = 'client = XiaoCanClient()'
if anchor not in src:
    sys.exit(1)
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
    sys.exit(1)
inject = '''        if tid == "flash_sale":
            _fs_opts = await _fs_goods_options(account_key)
            if _fs_opts:
                _saved = str(merged_params.get("goods_ids") or "").strip()
                if _saved and _saved not in [o["value"] for o in _fs_opts]:
                    _fs_opts = _fs_opts + [{"label": f"已选商品 {_saved} - 当前不在架", "value": _saved}]
                param_defs = [{"key": "goods_ids", "label": "秒杀商品", "def": "", "type": "select", "options": _fs_opts, "hint": "选好保存后，到点只抢这款；选自动优选则抢第一款有库存的"}]

''' + anchor2
src = src.replace(anchor2, inject, 1)
open(path, "w", encoding="utf-8").write(src)
PYEOF_FIX6
  then
    if grep -q "$FIX6_MARK" "$APP_DIR/$FIX6_REL" && python3 -m py_compile "$APP_DIR/$FIX6_REL"; then
      say "fix6 补丁已重打，重新构建生效…"
      $COMPOSE up -d --build || rollback
      OK3=0
      for i in $(seq 1 40); do
        if curl -fsS http://127.0.0.1:8690/health >/dev/null 2>&1 || docker exec xiaocan-assistant python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8690/health')" >/dev/null 2>&1; then
          OK3=1; break
        fi
        sleep 5
      done
      [ "$OK3" = "1" ] || { say "重打 fix6 后健康检查未通过"; rollback; }
      say "fix6 补丁重打完成并通过健康检查"
    else
      say "WARN: fix6 补丁写入校验失败，已跳过（不影响新版使用），请找助手手动处理"
    fi
  else
    say "WARN: fix6 补丁未能自动重打（上游结构可能变了），已跳过（不影响新版使用），请找助手手动处理"
  fi
fi

# ---------- 8. 收尾 ----------
if [ -n "$REMOTE_SHA" ]; then
  echo "$REMOTE_SHA $STAMP" > "$SHA_FILE"
fi
say "更新完成: ${LOCAL_SHA:-（无记录）} -> ${REMOTE_SHA:-（见上方变更清单）}"
say "更新前备份: $BACKUP_FILE（确认新版用着没问题后可删；脚本只自动保留最近 3 份）"
if [ "$PATCH_LOCAL" = "1" ] && [ "$PATCH_UPSTREAM" = "0" ]; then
  say "注意: 本地 fix4 解析器补丁已被新版源码覆盖，需要重打 fix4 才能恢复「折行粘贴也能导入」；补丁原文件在备份包里"
fi
say "DONE"
