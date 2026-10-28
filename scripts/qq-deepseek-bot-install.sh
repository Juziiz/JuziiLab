#!/bin/bash
set -e
cd /opt/qq-deepseek-bot 2>/dev/null || mkdir -p /opt/qq-deepseek-bot && cd /opt/qq-deepseek-bot
mkdir -p bot napcat/config napcat/data napcat/qq
cat > docker-compose.yml << 'COMPOSE'
services:
  napcat:
    image: mlikiowa/napcat-docker:latest
    container_name: napcat
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "3000:3000"
      - "3001:3001"
      - "6099:6099"
    volumes:
      - ./napcat/config:/app/napcat/config
      - ./napcat/data:/app/napcat/data
      - ./napcat/qq:/app/.config/QQ
    restart: unless-stopped
  bot:
    build: ./bot
    container_name: qq-deepseek-bot
    depends_on:
      - napcat
    env_file: .env
    environment:
      - NAPCAT_WS=ws://napcat:3001
    restart: unless-stopped
COMPOSE
cat > bot/Dockerfile << 'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
COPY bot.py .
CMD ["python", "bot.py"]
DOCKER
cat > bot/requirements.txt << 'REQ'
websockets
REQ
cat > bot/bot.py << 'PYEOF'
#!/usr/bin/env python3
"""QQ DeepSeek private-chat bot.

Listens to NapCat OneBot WebSocket, replies only to one whitelisted
private-chat user, and calls DeepSeek chat completions with history.
Env: NAPCAT_WS, DEEPSEEK_API_KEY, DEEPSEEK_MODEL, ALLOWED_USER_ID.
No key is ever printed or logged.
"""
import asyncio
import json
import os
import sys
import urllib.request

import websockets

NAPCAT_WS = os.environ.get("NAPCAT_WS", "ws://napcat:3001")
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
DEEPSEEK_MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")
ALLOWED_USER_ID = os.environ.get("ALLOWED_USER_ID", "")
NAPCAT_TOKEN = os.environ.get("NAPCAT_TOKEN", "")
HISTORY_LIMIT = 20


def deepseek_reply(history):
    payload = json.dumps({
        "model": DEEPSEEK_MODEL,
        "messages": history,
    }).encode()
    request = urllib.request.Request(
        "https://api.deepseek.com/v1/chat/completions",
        data=payload, method="POST",
    )
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + DEEPSEEK_API_KEY)
    with urllib.request.urlopen(request, timeout=120) as response:
        result = json.loads(response.read().decode())
    return result["choices"][0]["message"]["content"]


async def main():
    if not DEEPSEEK_API_KEY or not ALLOWED_USER_ID:
        print("missing DEEPSEEK_API_KEY or ALLOWED_USER_ID", file=sys.stderr)
        return 2
    history = []
    ws_url = NAPCAT_WS
    headers = {}
    if NAPCAT_TOKEN:
        if "?" in ws_url:
            ws_url += "&access_token=" + NAPCAT_TOKEN
        else:
            ws_url += "?access_token=" + NAPCAT_TOKEN
        headers["Authorization"] = "Bearer " + NAPCAT_TOKEN
    async with websockets.connect(ws_url, max_size=10 * 1024 * 1024, additional_headers=headers) as ws:
        print("connected to NapCat", flush=True)
        async for raw in ws:
            try:
                event = json.loads(raw)
            except Exception:
                continue
            if event.get("post_type") != "message":
                continue
            if event.get("message_type") != "private":
                continue
            sender = event.get("sender", {})
            user_id = str(sender.get("user_id", ""))
            if user_id != ALLOWED_USER_ID:
                continue
            text = event.get("raw_message", "").strip()
            if not text:
                continue
            if text == "/reset":
                history = []
                reply = "已清空上下文，重新开始聊吧。"
            else:
                history.append({"role": "user", "content": text})
                history = history[-HISTORY_LIMIT:]
                try:
                    reply = deepseek_reply(history)
                except Exception as exc:
                    print("deepseek error:", exc, flush=True)
                    reply = "DeepSeek 那边出错了，稍后再试一次。"
                    history.pop()
                    continue
                history.append({"role": "assistant", "content": reply})
                history = history[-HISTORY_LIMIT:]
            await ws.send(json.dumps({
                "action": "send_private_msg",
                "params": {"user_id": int(ALLOWED_USER_ID), "message": reply},
            }))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

PYEOF
if [ -f .env ] && ! grep -q NAPCAT_TOKEN .env; then
  read -p "NapCat WebSocket Token（服务器上输入）: " NAPCAT_TOKEN
  printf "NAPCAT_TOKEN=%s\n" "$NAPCAT_TOKEN" >> .env
  chmod 600 .env
fi
if [ ! -f .env ]; then
  read -p "跟机器人私聊的那个QQ号（只回这个号，其他号不回）: " ALLOWED_USER_ID
  read -s -p "DeepSeek API Key（服务器上输入，不会回显，也不要发给任何人）: " DEEPSEEK_API_KEY
  echo
  printf "ALLOWED_USER_ID=%s\nDEEPSEEK_API_KEY=%s\nDEEPSEEK_MODEL=deepseek-chat\n" "$ALLOWED_USER_ID" "$DEEPSEEK_API_KEY" > .env
  chmod 600 .env
fi
docker compose up -d --build
docker compose ps
IP=$(hostname -I | awk '{print $1}')
echo "NapCat WebUI: http://$IP:6099"
echo "先在华为云安全组临时放行 6099，打开上面地址扫码登录机器人QQ，登录成功后关掉 6099，只留 22 和业务端口。"
echo "然后用允许的那个QQ私聊机器人QQ，发一句话试试，/reset 可清空上下文。"
