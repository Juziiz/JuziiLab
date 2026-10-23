import sys, asyncio, json
sys.path.insert(0, "/app/backend")
from app.models import database as db
from app.protocol.client import XiaoCanClient

def show(tag, obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                show(tag, v, prefix + k + ".")
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                print(f"{tag} {prefix}{k} = {v}")

async def main():
    print("PROBE-SILK")
    accs = db.get_all_accounts()
    for a in accs:
        print("DB row:", a.get("nickname"), "| db.silk =", a.get("silk"), "| keys with numbers:")
        show("  db", {k: v for k, v in a.items() if k not in ("token", "app_token", "mini_token", "headers", "cookie")})
    acc = next((a for a in accs if str(a.get("silk_id")) == "527711911"), None)
    if not acc:
        print("main account not found")
        return
    client = XiaoCanClient()
    res = await client.get_user_info(token=acc["token"], silk_id=acc.get("silk_id"),
                                     user_id=acc.get("user_id"), city_code=acc.get("city_code") or 440303)
    ui = res.get("user_info") or {}
    print("LIVE user_info numeric fields:")
    show("  ui", ui)
    await client.close()

asyncio.run(main())
