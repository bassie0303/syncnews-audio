"""旧 public スキーマの記事を新構成へ移設する一回限りのスクリプト（追加のみ・public無変更）。

- public.articles/tracks/segments → syncnews.articles + syncnews_vault(title/segments)
- 公開バケット audio/{id}/{lang}.mp3 → 非公開バケット audio-private へコピー
- 所有者は指定メールのアカウント（auth.users）。
- 冪等: syncnews.articles に既に存在する id はスキップ。

使い方: python migrate_public_to_new.py <owner_email>
"""
import asyncio
import datetime as dt
import re
import sys

import httpx

import main

OWNER_EMAIL = sys.argv[1] if len(sys.argv) > 1 else "bassie0303@gmail.com"


def _parse(ts):
    """ISO文字列→datetime。Python3.9のfromisoformatは小数秒が3/6桁以外だと
    失敗するため、小数秒を6桁に正規化してから解釈する。"""
    if not ts:
        return None
    s = str(ts).replace("Z", "+00:00")
    m = re.search(r"\.(\d+)", s)
    if m:
        frac = (m.group(1) + "000000")[:6]
        s = s[: m.start()] + "." + frac + s[m.end():]
    try:
        return dt.datetime.fromisoformat(s)
    except ValueError:
        return None


async def main_async():
    sb = main._supabase()

    # 所有者 user_id
    users = sb.auth.admin.list_users()
    owner = next((u for u in users if (u.email or "").lower() == OWNER_EMAIL.lower()), None)
    if not owner:
        print(f"❌ アカウント {OWNER_EMAIL} が見つかりません")
        return
    owner_id = owner.id
    print(f"所有者: {OWNER_EMAIL} ({owner_id[:8]}…)")

    # 既に新スキーマにある id（スキップ用）
    conn = await main._pg()
    try:
        existing = {r["id"] for r in await conn.fetch("select id::text from syncnews.articles")}
    finally:
        await conn.close()

    # 旧public（本文・トラック・セグメントを一括取得）
    rows = (
        sb.table("articles")
        .select("*, tracks(lang, audio_url, segments(idx, text, start_ms, end_ms))")
        .order("created_at")
        .execute()
        .data
    )
    print(f"旧public記事: {len(rows)}件")

    migrated = skipped = 0
    for a in rows:
        aid = a["id"]
        if aid in existing:
            print(f"  - skip（移設済）: {a['title'][:30]}")
            skipped += 1
            continue

        # 1) 音声を非公開バケットへコピー（公開URL経由でDL→非公開へupload）
        for tr in a.get("tracks", []):
            lang = tr["lang"]
            path = f"{aid}/{lang}.mp3"
            try:
                pub = sb.storage.from_("audio").get_public_url(path)
                r = httpx.get(pub, timeout=60)
                if r.status_code == 200 and r.content:
                    sb.storage.from_("audio-private").upload(
                        path, r.content, {"content-type": "audio/mpeg", "upsert": "true"}
                    )
                else:
                    print(f"    ⚠ 音声DL失敗 {path}: HTTP {r.status_code}")
            except Exception as e:  # noqa: BLE001
                print(f"    ⚠ 音声コピー失敗 {path}: {str(e)[:80]}")

        # 2) DB（syncnews + vault）へ直結書き込み
        conn = await main._pg()
        try:
            async with conn.transaction():
                await conn.execute(
                    """
                    insert into syncnews.articles
                      (id, user_id, source_url, source_lang, status, published_at, error, created_at)
                    values ($1,$2,$3,$4,$5,$6,$7,$8)
                    on conflict (id) do nothing
                    """,
                    aid, owner_id, a["source_url"], a["source_lang"], a["status"],
                    _parse(a.get("published_at")), a.get("error"), _parse(a.get("created_at")),
                )
                await conn.execute(
                    """
                    insert into syncnews_vault.article_titles (article_id, title)
                    values ($1,$2) on conflict (article_id) do update set title=excluded.title
                    """,
                    aid, a.get("title") or "(無題)",
                )
                for tr in a.get("tracks", []):
                    lang = tr["lang"]
                    segs = sorted(tr.get("segments", []), key=lambda s: s["idx"])
                    await conn.execute(
                        "delete from syncnews_vault.segments where article_id=$1 and lang=$2",
                        aid, lang,
                    )
                    await conn.executemany(
                        """
                        insert into syncnews_vault.segments
                          (article_id, lang, idx, text, start_ms, end_ms)
                        values ($1,$2,$3,$4,$5,$6)
                        """,
                        [(aid, lang, s["idx"], s["text"], s["start_ms"], s["end_ms"]) for s in segs],
                    )
        finally:
            await conn.close()
        print(f"  ✅ 移設: {a['title'][:30]}")
        migrated += 1

    print(f"\n完了: 移設 {migrated} 件 / スキップ {skipped} 件")


if __name__ == "__main__":
    asyncio.run(main_async())
