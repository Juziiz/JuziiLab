#!/usr/bin/env bash
# fix10：给小蚕助手网页套手机适配样式。在门禁 nginx 的反代 location 里注入
# 一段仅窄屏（<=860px）生效的 CSS：弹窗近全屏、表格横滑、表单单列、输入框
# 16px 防 iOS 放大、按钮加大。不动作者代码，升级不丢；失败自动回滚。幂等。
set -u
APP_DIR="${XIAOCAN_APP_DIR:-/opt/xiaocan-assistant}"
TS="$(date +%Y%m%d%H%M%S)"
say() { echo "[fix10] $*"; }
cd "$APP_DIR" || { say "ERROR: 进不去 $APP_DIR"; exit 1; }
BK="/root/nginx-gate.bak-fix10-$TS"; mkdir -p "$BK"
for f in nginx.conf nginx-main.conf; do [ -f "$f" ] && cp -a "$f" "$BK/"; done
export XIAOCAN_APP_DIR="$APP_DIR"
if ! python3 - <<'PYEOF_FIX10'
import os, re, sys

CSS = (
"@media (max-width:860px){"
"#root>.semi-layout{height:100dvh!important}"
".semi-modal{margin:6px auto!important}"
".semi-modal-content{width:calc(100vw - 12px)!important;max-width:calc(100vw - 12px)!important;max-height:calc(100dvh - 12px)!important;display:flex!important;flex-direction:column!important}"
".semi-modal-body{overflow-y:auto!important}"
".semi-modal-header{padding:12px 16px!important}"
".semi-modal-footer{padding:10px 16px!important}"
"body .semi-table-container{overflow-x:auto!important;-webkit-overflow-scrolling:touch}"
"body .semi-table-container table{min-width:620px}"
".semi-table-row-cell{white-space:nowrap}"
".logs-table-container .semi-table-row-cell{white-space:normal!important;word-break:break-word}"
".logs-table-container .semi-table-row{height:auto!important}"
".logs-table-container .semi-table-row-cell{overflow:hidden;vertical-align:top}"
".logs-table-container .semi-table-row-cell-render-content{width:auto!important;max-width:100%!important}"
".logs-table-container .semi-table-container table{table-layout:fixed!important;width:100%!important}"
".logs-table-container col:nth-child(1){width:8%!important}"
".logs-table-container col:nth-child(2){width:24%!important}"
".logs-table-container col:nth-child(3){width:15%!important}"
".logs-table-container col:nth-child(4){width:25%!important}"
".logs-table-container col:nth-child(5){width:12%!important}"
".logs-table-container col:nth-child(6){display:none!important}"
".logs-table-container col:nth-child(7){width:16%!important}"
".logs-table-container .semi-table-thead tr>th:nth-child(6),.logs-table-container .semi-table-tbody tr>td:nth-child(6){display:none!important}"
".logs-table-container .semi-table-row-cell,.logs-table-container .semi-table-row-head{padding-left:5px!important;padding-right:5px!important;font-size:12.5px}"
".semi-row>[class*=semi-col-]{flex:0 0 100%!important;max-width:100%!important}"
"input,textarea,.semi-input,.semi-textarea{font-size:16px!important}"
".semi-select-selection{font-size:16px!important}"
".semi-button{min-height:34px}"
".semi-button-size-small{min-height:28px}"
".semi-tabs-bar{overflow-x:auto!important;-webkit-overflow-scrolling:touch}"
".semi-tabs-tab{white-space:nowrap}"
".semi-select-option-list,.semi-popover,.semi-dropdown-menu{max-width:94vw!important}"
"pre{white-space:pre-wrap!important;word-break:break-word}"
".semi-descriptions-key,.semi-descriptions-value{white-space:normal!important}"
".semi-page{flex-wrap:wrap;row-gap:6px}"
".semi-card-body{padding:12px!important}"
".semi-card-header{flex-wrap:wrap!important;row-gap:6px}"
".semi-list-item{flex-wrap:wrap;padding-top:10px;padding-bottom:10px}"
".semi-navigation-item{min-height:44px}"
".semi-layout-header{flex-wrap:wrap!important;height:auto!important;min-height:52px;padding:6px 10px!important;row-gap:6px}"
".semi-layout-header .semi-space{justify-content:flex-end;flex:1 1 auto;min-width:0}"
".semi-space{flex-wrap:wrap!important;row-gap:6px}"
"#header-location-btn span{max-width:92px!important}"
"[class*=justify-between]{flex-wrap:wrap!important}"
"[class*=text-xs]{font-size:13px!important}"
"[class*=text-[11px]]{font-size:12px!important}"
"[class*=text-[10px]]{font-size:11px!important}"
"[class*=justify-between][class*=overflow-hidden]:has(>[class*=lg:grid-cols-12]){overflow-y:auto!important;justify-content:flex-start!important}"
"[class*=lg:grid-cols-12]{overflow:visible!important;flex:none!important;height:auto!important}"
"[class*=lg:col-span-7],[class*=lg:col-span-5]{height:auto!important;overflow:visible!important}"
"[class*=lg:col-span-7] [class*=overflow-y-auto]{max-height:38dvh!important}"
"[class*=lg:col-span-5] .semi-card{flex:none!important;overflow:visible!important}"
"[class*=lg:col-span-5] .semi-card-body{overflow:visible!important;flex:none!important}"
"[class*=lg:col-span-5] .semi-card-body [class*=flex-1]{flex:none!important;height:auto!important}"
"[class*=lg:col-span-5] [class*=overflow-hidden],[class*=lg:col-span-5] [class*=overflow-y-auto]{overflow:visible!important;max-height:none!important}"
"}"
)

DIRECTIVES = (
    "\n        # [fix10] mobile css injection v4 (narrow screens only)\n"
    "        proxy_set_header Accept-Encoding \"\";\n"
    "        sub_filter_once on;\n"
    "        sub_filter '</head>' '<style id=\"xc-mobile\">" + CSS + "</style></head>';\n"
    "    "
)

def find_location_blocks(text):
    blocks = []
    i = 0
    while True:
        j = text.find("location", i)
        if j < 0:
            break
        k = text.find("{", j)
        if k < 0:
            break
        depth = 0
        m = k
        while m < len(text):
            ch = text[m]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            m += 1
        if m >= len(text):
            break
        blocks.append((j, k, m))
        i = m + 1
    return blocks

app_dir = os.environ.get("XIAOCAN_APP_DIR", "/opt/xiaocan-assistant")
done = False
for name in ("nginx.conf", "nginx-main.conf"):
    p = os.path.join(app_dir, name)
    if not os.path.exists(p):
        continue
    text = open(p, encoding="utf-8").read()
    if "injection v4" in text:
        print("[fix10] already v4 in " + name + ", skip")
        done = True
        break
    if "xc-mobile" in text:
        new = re.sub(r'(<style id="xc-mobile">).*?(</style>)',
                     lambda mo: mo.group(1) + CSS + mo.group(2), text, count=1, flags=re.S)
        new = re.sub(r"mobile css injection( v\d+)? \(narrow screens only\)",
                     "mobile css injection v4 (narrow screens only)", new)
        if new != text and "injection v4" in new:
            open(p, "w", encoding="utf-8").write(new)
            print("[fix10] upgraded mobile CSS to v4 in " + name)
            done = True
            break
        print("[fix10] ERROR: old version found but upgrade failed in " + name)
        sys.exit(1)
    for (j, k, m) in find_location_blocks(text):
        block = text[k:m]
        if "proxy_pass" in block and "8690" in block:
            text = text[:m] + DIRECTIVES + text[m:]
            open(p, "w", encoding="utf-8").write(text)
            print("[fix10] injected mobile CSS v4 into " + name)
            done = True
            break
    if done:
        break
if not done:
    print("[fix10] ERROR: no location block proxying to 8690 found in gate configs")
    sys.exit(1)
PYEOF_FIX10
then
  say "ERROR: 未能定位反代 location，已放弃（配置未改动）"
  exit 1
fi
CONT="$(docker ps --format "{{.Names}}|{{.Image}}" | awk -F"|" "\$2 ~ /nginx/ {print \$1; exit}")"
[ -z "$CONT" ] && CONT="$(docker ps --format "{{.Names}}" | grep -i nginx | head -1)"
if [ -z "$CONT" ]; then
  say "ERROR: 找不到 nginx 容器，配置已写入但未生效，请截图发助手"
  exit 1
fi
say "nginx 容器：$CONT，校验配置…"
if ! docker exec "$CONT" nginx -t 2>&1; then
  say "ERROR: nginx 配置校验失败，正在回滚"
  for f in nginx.conf nginx-main.conf; do [ -f "$BK/$f" ] && cp -a "$BK/$f" "$APP_DIR/$f"; done
  docker exec "$CONT" nginx -s reload >/dev/null 2>&1
  say "已回滚到原配置，页面未受影响"
  exit 1
fi
docker exec "$CONT" nginx -s reload
sleep 1
VERIFY="skipped"
if [ -f /root/xiaocan-access.txt ]; then
  PW="$(grep -Eo "ju[: ]+[^[:space:]]+" /root/xiaocan-access.txt | head -1 | sed "s/^ju[: ]*//")"
  [ -z "$PW" ] && PW="$(head -1 /root/xiaocan-access.txt | tr -d " \r\n")"
  if [ -n "$PW" ]; then
    if curl -fsS -u "ju:$PW" http://127.0.0.1:8691/ 2>/dev/null | grep -q "xc-mobile"; then VERIFY="ok"; else VERIFY="auth-or-page-failed"; fi
  fi
fi
if [ "$VERIFY" = "ok" ]; then
  say "完成：手机适配样式已注入并验证生效（窄屏打开自动生效，电脑端不变）"
else
  say "完成：配置已生效（自动验证跳过：$VERIFY），请用手机打开页面确认效果"
fi
