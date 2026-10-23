import sys, asyncio, json
sys.path.insert(0, "/app/backend")
from app.models import database as db
from app.protocol.client import XiaoCanClient, XiaoCanRPCError

async def main():
    accs = [a for a in db.get_all_accounts() if a.get("token")]
    if not accs:
        print("no account with token")
        return
    acc = accs[0]
    print("account:", acc.get("nickname") or acc.get("key"))
    client = XiaoCanClient()
    try:
        res = await client.today_exchange(
            exchange_id=202,
            token=acc["token"], silk_id=acc.get("silk_id"), user_id=acc.get("user_id"),
            city_code=acc.get("city_code") or 440303)
        print("NO ERROR RAISED. full response:")
        print(json.dumps(res, ensure_ascii=False, indent=1)[:3000])
    except XiaoCanRPCError as e:
        print(f"RPCError raised: code={e.code} msg={e.msg}")
        print("raw:", json.dumps(e.raw, ensure_ascii=False)[:2000] if e.raw else None)
    await client.close()

asyncio.run(main())
