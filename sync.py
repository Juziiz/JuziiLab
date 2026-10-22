#!/usr/bin/env python3
"""JuziiLab 每日同步: 从 kelvinlab.wuyra.com 拉最新清单与文件,
全部外链改写为本仓库 (Juziiz/JuziiLab) 的 raw 链接后落盘。
由 .github/workflows/sync.yml 调用; 无变化时工作区无 diff, 不产生提交。
安全策略: 任一一级文件 (插件/模块) 下载失败 -> 整轮放弃 (exit 1, 不提交);
依赖文件下载失败时, 若本地已有旧版则保留旧版, 从未有过的则跳过并记录。
"""
import json, os, re, sys, shutil, subprocess
from urllib.parse import urlparse, unquote
import urllib.request, urllib.error

ORIGIN = 'https://kelvinlab.wuyra.com'
RAW = 'https://raw.githubusercontent.com/Juziiz/JuziiLab/main'
REPO_PAGE = 'https://github.com/Juziiz/JuziiLab'
ROOT = os.path.dirname(os.path.abspath(__file__))
HEADERS = {
    'Referer': ORIGIN + '/',
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/json,*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'sec-ch-ua': '"Chromium";v="126", "Google Chrome";v="126", "Not-A.Brand";v="24"',
    'sec-ch-ua-platform': '"macOS"',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'same-origin',
}

def fetch(url, timeout=40):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def main():
    raw_list = fetch(ORIGIN + '/list.json')
    catalog = json.loads(raw_list.decode('utf-8'))

    # ---------- 一级文件 (只收 lpx 区: 插件+模块; 规则按主人要求不收) ----------
    jobs = {}  # url -> rel path
    def extract(field):
        if not field:
            return None
        m = re.search(r'https://kelvinlab\.wuyra\.com/[^\s"\'&]+', field)
        return m.group(0) if m else None
    for it in catalog.get('lpx', []):
        for field, kind in (('loonUrl', 'loon'), ('surgeUrl', 'surge')):
            u = extract(it.get(field, ''))
            if u:
                jobs[u] = f"{kind}/{u.split('/')[-1]}"

    staging = os.path.join(ROOT, '.sync_staging')
    if os.path.exists(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)

    def fetch_or_keep(u, rel):
        """返回 (bytes|None, status): ok / kept-old / dead / abort
        404: 原站已删 — 有旧版留旧版, 没旧版记为 dead 跳过
        其他错误: 有旧版留旧版, 没旧版整轮放弃 (无法区分临时故障与真问题)"""
        try:
            data = fetch(u)
            if not data:
                raise ValueError('empty')
            return data, 'ok'
        except urllib.error.HTTPError as e:
            old = os.path.join(ROOT, rel)
            if os.path.exists(old):
                return open(old, 'rb').read(), 'kept-old'
            if e.code == 404:
                return None, 'dead'
            return None, 'abort'
        except Exception:
            old = os.path.join(ROOT, rel)
            if os.path.exists(old):
                return open(old, 'rb').read(), 'kept-old'
            return None, 'abort'

    level1 = {}  # rel -> bytes
    for u, rel in sorted(jobs.items()):
        data, st = fetch_or_keep(u, rel)
        if st == 'abort':
            print(f'ABORT: level-1 unreachable {u}')
            return 1
        if st == 'dead':
            print('  dead at origin (skipped):', u)
            continue
        if st == 'kept-old':
            print('  kept old copy:', rel)
        level1[rel] = data
    print(f'level-1 files: {len(level1)}')

    # ---------- 二级依赖 ----------
    pat = [
        re.compile(r'script-path\s*=\s*(https?://[^\s,"]+)'),
        re.compile(r'(?:RULE-SET|rule-set|ruleset)\s*,\s*(https?://[^\s,]+)'),
        re.compile(r'#!icon\s*=\s*(https?://\S+)'),
        re.compile(r'jq-path\s*=\s*"?(https?://[^"\s,]+)'),
        re.compile(r'jq_file\("(https?://[^"]+)"\)'),
    ]
    dep_urls = set()
    for rel, data in level1.items():
        txt = data.decode('utf-8', errors='replace')
        for p in pat:
            dep_urls |= set(p.findall(txt))
        for line in txt.splitlines():
            ls = line.strip()
            if ls.startswith('http') and 'pattern' not in ls and '=http' not in ls:
                m = re.match(r'(https?://\S+?)\s*(?:,|$)', ls)
                if m:
                    dep_urls.add(m.group(1))
    dep_urls = {u.rstrip(')').strip() for u in dep_urls}
    dep_urls = {u for u in dep_urls if '{{{' not in u and u not in jobs}

    url2repo = {u: f'{RAW}/{rel}' for u, rel in jobs.items()}
    deps_ok, deps_kept, deps_missing = {}, [], []
    for u in sorted(dep_urls):
        p = urlparse(u)
        rel = f"deps/{p.netloc}{unquote(p.path)}"
        data, st = fetch_or_keep(u, rel)
        if st in ('ok', 'kept-old'):
            deps_ok[rel] = data
            url2repo[u] = f'{RAW}/{rel}'
            if st == 'kept-old':
                deps_kept.append(rel)
        else:
            # 依赖拿不到且从未镜像过: 跳过并记录 (引用保留原外链兜底, 不阻断整轮)
            deps_missing.append(u)
    print(f'deps ok: {len(deps_ok)} (kept-old: {len(deps_kept)}, still-missing: {len(deps_missing)})')
    for u in deps_missing:
        print('  missing dep:', u)

    pairs = sorted(url2repo.items(), key=lambda kv: -len(kv[0]))

    def rewrite(data):
        try:
            txt = data.decode('utf-8')
        except UnicodeDecodeError:
            return data
        for old, new in pairs:
            if old in txt:
                txt = txt.replace(old, new)
        txt = txt.replace('#!homepage=https://kelvinlab.wuyra.com', f'#!homepage={REPO_PAGE}')
        return txt.encode('utf-8')

    # ---------- 落盘: 重建 loon/ surge/ deps/ ----------
    for d in ('loon', 'surge', 'deps'):
        full = os.path.join(ROOT, d)
        if os.path.exists(full):
            shutil.rmtree(full)
    def put(rel, data):
        dest = os.path.join(staging, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, 'wb').write(data)
    for rel, data in level1.items():
        put(rel, rewrite(data))
    for rel, data in deps_ok.items():
        put(rel, data)
    for d in ('loon', 'surge', 'deps'):
        src = os.path.join(staging, d)
        if os.path.exists(src):
            shutil.move(src, os.path.join(ROOT, d))
    shutil.rmtree(staging, ignore_errors=True)

    # ---------- 转换目录 ----------
    cat = json.loads(raw_list.decode('utf-8'))
    cat.pop('rule', None)
    for it in cat.get('lpx', []):
        for f in ('loonUrl', 'surgeUrl'):
            v = it.get(f, '') or ''
            for old, new in pairs:
                if old in v:
                    v = v.replace(old, new)
            it[f] = v
        if it.get('icon') in url2repo:
            it['icon'] = url2repo[it['icon']]
    with open(os.path.join(ROOT, 'kelvinlab-list.json'), 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, ensure_ascii=False, indent=1)
    print('sync done')
    return 0

if __name__ == '__main__':
    sys.exit(main())
