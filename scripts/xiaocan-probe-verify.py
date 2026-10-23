import sys, asyncio, json
sys.path.insert(0, "/app/backend")
from app.models import database as db
from app.protocol.client import XiaoCanClient, XiaoCanRPCError

TARGET_ID = 202

def find_target(res):
    lst = res.get("list") or {}
    for gname, g in lst.items():
        if isinstance(g, list):
            for it in g:
                if it.get("exchange_id") == TARGET_ID:
                    return gname, it
    return None, None

async def main():
    accs = [a for a in db.get_all_accounts() if a.get("token")]
    acc = next((a for a in accs if str(a.get("silk_id")) == "527711911"), accs[0] if accs else None)
    if not acc:
        print("no account")
        return
    print("account:", acc.get("nickname") or acc.get("key"), "silk_id:", acc.get("silk_id"))
    kw = dict(token=acc["token"], silk_id=acc.get("silk_id"), user_id=acc.get("user_id"),
              city_code=acc.get("city_code") or 440303)
    client = XiaoCanClient()

    info1 = await client.get_user_info(**kw)
    ui1 = info1.get("info") or info1
    print("silk BEFORE:", ui1.get("silk"), "| info keys:", list(ui1.keys())[:15])

    fs1 = await client.list_flash_sale_exchanges(is_plus=bool(acc.get("is_plus", 0)), **kw)
    g, it = find_target(fs1)
    print(f"target {TARGET_ID} BEFORE: group={g} left={it.get('left') if it else None} name={it.get('goods_name') if it else None}")

    try:
        res = await client.today_exchange(exchange_id=TARGET_ID, **kw)
        print("exchange response goods:", json.dumps(res.get("goods"), ensure_ascii=False)[:600])
    except XiaoCanRPCError as e:
        print(f"exchange RPCError: code={e.code} msg={e.msg}")

    info2 = await client.get_user_info(**kw)
    ui2 = info2.get("info") or info2
    print("silk AFTER:", ui2.get("silk"))

    fs2 = await client.list_flash_sale_exchanges(is_plus=bool(acc.get("is_plus", 0)), **kw)
    g2, it2 = find_target(fs2)
    print(f"target {TARGET_ID} AFTER: left={it2.get('left') if it2 else None}")
    await client.close()

asyncio.run(main())
