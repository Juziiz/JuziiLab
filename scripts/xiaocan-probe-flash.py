import sys, asyncio
sys.path.insert(0, "/app/backend")
from app.models import database as db
from app.protocol.client import XiaoCanClient

async def main():
    accs = [a for a in db.get_all_accounts() if a.get("token")]
    print("accounts with token:", len(accs))
    client = XiaoCanClient()
    for acc in accs:
        name = acc.get("nickname") or acc.get("key")
        try:
            res = await client.list_flash_sale_exchanges(
                token=acc["token"], silk_id=acc.get("silk_id"), user_id=acc.get("user_id"),
                city_code=acc.get("city_code") or 440303, is_plus=bool(acc.get("is_plus", 0)))
        except Exception as e:
            print(f"[{name}] RPC failed: {e}")
            continue
        lst = res.get("list") or {}
        print(f"[{name}] is_plus={acc.get('is_plus')} top keys: {list(res.keys())}")
        print(f"[{name}] list keys: {list(lst.keys())}")
        for k, v in lst.items():
            if isinstance(v, list):
                print(f"  group [{k}]: {len(v)} items")
                for it in v[:20]:
                    print(f"    id={it.get('exchange_id')} name={it.get('goods_name')} silk={it.get('community_silk')} left={it.get('left')}")
            else:
                print(f"  group [{k}]: {type(v).__name__} = {str(v)[:120]}")
        print(f"  rounds: {res.get('rounds')}")
    await client.close()

asyncio.run(main())
