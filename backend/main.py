"""SyncNews Audio — 変換ワーカー (FastAPI / Railway デプロイ)

記事URL -> 本文抽出 -> 翻訳(GPT-4o) -> TTS+タイムスタンプ(ElevenLabs)
        -> Supabase Storage(音声) & Postgres(tracks/segments) へ保存。

Edge Function から移管した理由:
  Supabase Edge Functions は Deno/TS かつ実行時間制限(〜150s)があり、
  GPT-4o + 長尺TTS のジョブで詰まりやすい。本ワーカーは epiphany /
  multi_ai_prompt と同じ手札(Python + FastAPI + Railway)で実装し、
  長時間ジョブとAIエコシステムを扱いやすくする。

重要な技術判断（タイムスタンプ取得）:
  OpenAI TTS は単語/文タイムスタンプを返さない。ElevenLabs の
  `/text-to-speech/{voice_id}/with-timestamps` は文字単位TSを返すため、
  「翻訳=GPT-4o」「TTS+TS=ElevenLabs」を採用し、文字TSを文境界で集約して
  SyncSegment(start_ms,end_ms) を生成する。
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv

# --- 環境変数のロード（epiphany と同じ作法）---
# override=True：シェルに空キーが export されていても .env を優先。
# 共有(claude_test/.env)を先に、backend/.env を後に読み、具体的な方を勝たせる。
_BACKEND_DIR = Path(__file__).resolve().parent
load_dotenv(_BACKEND_DIR.parent.parent / ".env", override=True)  # claude_test/.env
load_dotenv(_BACKEND_DIR / ".env", override=True)               # backend/.env

import base64  # noqa: E402
import json  # noqa: E402

import html as _html  # noqa: E402

import httpx  # noqa: E402
from fastapi import BackgroundTasks, FastAPI, Request  # noqa: E402
from fastapi.responses import HTMLResponse  # noqa: E402
from openai import AsyncOpenAI  # noqa: E402
from pydantic import BaseModel  # noqa: E402
from supabase import Client, create_client  # noqa: E402

app = FastAPI(title="SyncNews Audio Convert Worker")

Lang = Literal["ja", "en"]

# 抽出・翻訳に使う GPT モデル。
_GPT_MODEL = "gpt-4o"
# ElevenLabs の多言語モデル（日英ともこの1モデルで可）。
_ELEVEN_MODEL = "eleven_multilingual_v2"


def _openai() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])


def _supabase() -> Client:
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],  # サーバ専用キー
    )


class ConvertRequest(BaseModel):
    article_id: str
    source_url: str


class SubmitRequest(BaseModel):
    url: str


@app.get("/api/health")
def health() -> dict:
    """Railway ヘルスチェック。必要キーの有無＋UTF-8モードを返す。"""
    import sys

    return {
        "ok": True,
        "openai": bool(os.environ.get("OPENAI_API_KEY")),
        "elevenlabs": bool(os.environ.get("ELEVENLABS_API_KEY")),
        "supabase": bool(os.environ.get("SUPABASE_URL")),
        # C ロケールでの日本語 ascii encode 失敗を防ぐ UTF-8 モードが効いているか
        "utf8_mode": sys.flags.utf8_mode,
        "preferred_encoding": __import__("locale").getpreferredencoding(False),
    }


@app.post("/api/convert")
async def convert(req: ConvertRequest, background_tasks: BackgroundTasks) -> dict:
    """変換を「受け付け」、実処理はバックグラウンドで行う（即時応答）。

    同期で全変換（数分）を待つとアプリのフィードバックが遅れ、プロキシの
    長時間リクエストtimeoutにも当たる。ここでは即 accepted を返し、進捗は
    articles.status（pending→processing→ready/failed）で表現する。
    """
    background_tasks.add_task(_run_pipeline, req.article_id, req.source_url)
    return {"ok": True, "accepted": True}


async def _eleven_subscription() -> dict:
    """ElevenLabs の利用状況（使用済み/上限文字数）を取得して残量を計算する。"""
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(
            "https://api.elevenlabs.io/v1/user/subscription",
            headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"]},
        )
        resp.raise_for_status()
    data = resp.json()
    used = int(data.get("character_count", 0))
    limit = int(data.get("character_limit", 0))
    return {"used": used, "limit": limit, "remaining": max(0, limit - used)}


@app.get("/api/quota")
async def quota() -> dict:
    """ElevenLabs の残クレジット（文字数）。登録前の残量表示に使う。"""
    try:
        return {"ok": True, **await _eleven_subscription()}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}


def _tts_char_count(text: str, lang: Lang) -> int:
    """その言語で ElevenLabs に実際に送る文字数（ja はカナ読み）。"""
    return len(_to_reading_ja(text) if lang == "ja" else text)


@app.post("/api/submit")
def submit(req: SubmitRequest, background_tasks: BackgroundTasks) -> dict:
    """URL だけで「記事行の作成＋変換開始」を1発で行う（PC導線用）。

    アプリは anon キーで articles に insert してから /api/convert を叩くが、
    ブラウザのブックマークレット/拡張からは Supabase クライアントを持たない。
    そこで backend(service_role) が行作成まで肩代わりし、URL のみで登録できる。
    """
    url = (req.url or "").strip()
    if not url.startswith(("http://", "https://")):
        return {"ok": False, "error": "URLが不正です"}
    sb = _supabase()
    # source_lang は仮で ja。抽出時に実言語へ更新される（アプリと同じ作法）。
    row = (
        sb.table("articles")
        .insert({"source_url": url, "source_lang": "ja"})
        .execute()
        .data[0]
    )
    background_tasks.add_task(_run_pipeline, row["id"], url)
    return {"ok": True, "accepted": True, "article_id": row["id"]}


@app.get("/submit", response_class=HTMLResponse)
def submit_page(url: str = "") -> str:
    """ブックマークレットが開くポップアップ。同一オリジンで /api/submit を叩く。

    クロスオリジン preflight(CORS) を避けるため、登録ページを backend 自身が配信し、
    そこから同一オリジンの fetch で POST する。結果を日本語で表示する。
    """
    safe_url = _html.escape(url, quote=True)
    return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SyncNews Audio に登録</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: -apple-system, "Hiragino Kaku Gothic ProN", sans-serif;
         margin: 0; padding: 28px; background: #f7f7fb; color: #1f2430; }}
  .brand {{ font-weight: 700; color: #4F46E5; font-size: 14px; letter-spacing: .04em; }}
  h1 {{ font-size: 20px; margin: 12px 0 8px; }}
  .url {{ font-size: 12px; color: #6b7280; word-break: break-all;
         background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 8px 10px; }}
  .status {{ margin-top: 18px; font-size: 16px; min-height: 24px; }}
  .ok {{ color: #16a34a; font-weight: 600; }}
  .err {{ color: #dc2626; font-weight: 600; }}
  .hint {{ margin-top: 16px; font-size: 12px; color: #6b7280; }}
  button {{ margin-top: 18px; background: #4F46E5; color: #fff; border: 0;
           border-radius: 8px; padding: 10px 16px; font-size: 14px; cursor: pointer; }}
</style></head>
<body>
  <div class="brand">SyncNews Audio</div>
  <h1>記事を登録</h1>
  <div class="url" id="url">{safe_url}</div>
  <div class="status" id="status">登録中…</div>
  <div class="hint">変換にはしばらくかかります。アプリの一覧で進捗（コンバート中…→準備完了）が表示されます。</div>
  <button onclick="window.close()">閉じる</button>
<script>
  const url = {json.dumps(url)};
  const $ = (id) => document.getElementById(id);
  (async () => {{
    if (!url) {{ $('status').className='status err'; $('status').textContent='URLが取得できませんでした'; return; }}
    try {{
      const res = await fetch('/api/submit', {{
        method: 'POST',
        headers: {{ 'Content-Type': 'application/json' }},
        body: JSON.stringify({{ url }}),
      }});
      const data = await res.json();
      if (data.ok) {{
        $('status').className = 'status ok';
        $('status').textContent = '✅ 登録しました！変換を開始しました。';
      }} else {{
        $('status').className = 'status err';
        $('status').textContent = '登録に失敗: ' + (data.error || '不明なエラー');
      }}
    }} catch (e) {{
      $('status').className = 'status err';
      $('status').textContent = '通信に失敗しました: ' + e;
    }}
  }})();
</script>
</body></html>"""


@app.get("/bookmarklet", response_class=HTMLResponse)
def bookmarklet_page(request: Request) -> str:
    """ブックマークレット導入ページ。リンクをブックマークバーにドラッグするだけ。

    自分のオリジン(base_url)から /submit を開くブックマークレットを動的生成するので、
    デプロイ先ドメインが変わっても貼り直し不要。
    """
    base = str(request.base_url).rstrip("/")
    # Railway はプロキシ裏で TLS 終端するため base_url が http:// で返る。
    # localhost 以外は https に正規化（https の記事ページから余計なリダイレクトを避ける）。
    if base.startswith("http://") and "localhost" not in base and "127.0.0.1" not in base:
        base = "https://" + base[len("http://") :]
    # javascript: スキームのワンライナー。現在ページURLを付けて /submit を小窓で開く。
    code = (
        "javascript:(function(){window.open('"
        + base
        + "/submit?url='+encodeURIComponent(location.href),"
        "'syncnews','width=440,height=340');})();"
    )
    safe_code = _html.escape(code, quote=True)
    return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SyncNews Audio ブックマークレット</title>
<style>
  body {{ font-family: -apple-system, "Hiragino Kaku Gothic ProN", sans-serif;
         max-width: 640px; margin: 0 auto; padding: 32px 20px; color: #1f2430; line-height: 1.7; }}
  .brand {{ font-weight: 700; color: #4F46E5; letter-spacing: .04em; }}
  h1 {{ font-size: 22px; }}
  .bm {{ display: inline-block; background: #4F46E5; color: #fff !important;
        text-decoration: none; border-radius: 10px; padding: 12px 20px;
        font-size: 16px; font-weight: 600; margin: 12px 0; }}
  ol {{ padding-left: 1.2em; }}
  code {{ background: #f3f4f6; padding: 2px 6px; border-radius: 4px; }}
</style></head>
<body>
  <div class="brand">SyncNews Audio</div>
  <h1>ブックマークレットで記事を登録</h1>
  <p>下のボタンを<strong>ブックマークバーにドラッグ＆ドロップ</strong>してください。
     以降、読みたいニュース記事のページでこのブックマークを押すだけで登録できます。</p>
  <p><a class="bm" href="{safe_code}">📰 SyncNewsに登録</a></p>
  <h2>使い方</h2>
  <ol>
    <li>ブラウザのブックマークバーを表示（Chrome/Edge: <code>Ctrl/⌘+Shift+B</code>）</li>
    <li>上のボタンをバーへドラッグして追加</li>
    <li>登録したいニュース記事を開いた状態でブックマークをクリック</li>
    <li>小窓に「✅ 登録しました」と出れば完了。アプリの一覧に変換中として現れます</li>
  </ol>
</body></html>"""


@app.delete("/api/articles/{article_id}")
def delete_article(article_id: str) -> dict:
    """記事を削除する（履歴削除／進行中ならコンバートのキャンセルを兼ねる）。

    Storage の音声を削除し、articles 行を削除（cascade で tracks/segments も消える）。
    進行中の変換は、パイプラインのチェックポイントが行の消失を検知して中断する。
    """
    sb = _supabase()
    try:
        items = sb.storage.from_("audio").list(article_id)
        paths = [f"{article_id}/{it['name']}" for it in items]
        if paths:
            sb.storage.from_("audio").remove(paths)
    except Exception:  # noqa: BLE001
        import traceback

        print(traceback.format_exc(), flush=True)  # 音声削除失敗は致命的でない
    sb.table("articles").delete().eq("id", article_id).execute()
    return {"ok": True}


def _article_exists(sb: Client, article_id: str) -> bool:
    return bool(sb.table("articles").select("id").eq("id", article_id).execute().data)


async def _run_pipeline(article_id: str, source_url: str) -> None:
    """記事を変換して日英の tracks/segments を生成する（バックグラウンド実行）。"""
    sb = _supabase()
    sb.table("articles").update({"status": "processing"}).eq("id", article_id).execute()

    try:
        # 1. 本文抽出（言語判定・公開日時込み）
        title, body, lang, published_at = await extract_article(source_url)
        if not _article_exists(sb, article_id):  # キャンセル(削除)済み
            return
        meta: dict = {"title": title, "source_lang": lang}
        if published_at:  # 取れたときだけ更新（取れなければ null のまま）
            meta["published_at"] = published_at
        sb.table("articles").update(meta).eq("id", article_id).execute()

        # 2. 対向言語へ翻訳
        target: Lang = "en" if lang == "ja" else "ja"
        translated = await translate(body, target)

        # 3. 各言語で 合成+TS -> 文集約 -> Storage/DB 保存
        #    ja は漢字の誤読を避けるためカナ読みで合成（表示は原文の漢字）。
        #    重いTTSの前にキャンセル（削除）を確認して無駄な課金を避ける。
        if not _article_exists(sb, article_id):
            return

        # クレジットガード: 重いTTSの前に「必要文字数」と「残量」を比較する。
        # 足りなければ TTS を一切実行せず failed にして理由を残し、課金を防ぐ。
        # 残量取得に失敗したらガードせず従来通り続行（外部API障害で止めない）。
        needed = _tts_char_count(body, lang) + _tts_char_count(translated, target)
        try:
            remaining = (await _eleven_subscription())["remaining"]
        except Exception:  # noqa: BLE001
            remaining = None
        if remaining is not None and needed > remaining:
            msg = f"ElevenLabsクレジット不足（必要 {needed:,} 字 / 残 {remaining:,} 字）"
            sb.table("articles").update(
                {"status": "failed", "error": msg}
            ).eq("id", article_id).execute()
            return

        for l, text in ((lang, body), (target, translated)):
            audio_bytes, segments = await synthesize_segments(text, l)

            audio_path = f"{article_id}/{l}.mp3"
            sb.storage.from_("audio").upload(
                audio_path, audio_bytes, {"content-type": "audio/mpeg", "upsert": "true"}
            )
            public_url = sb.storage.from_("audio").get_public_url(audio_path)

            track = (
                sb.table("tracks")
                .upsert({"article_id": article_id, "lang": l, "audio_url": public_url})
                .execute()
                .data[0]
            )
            sb.table("segments").insert(
                [
                    {
                        "track_id": track["id"],
                        "idx": i,
                        "text": s["text"],
                        "start_ms": s["start_ms"],
                        "end_ms": s["end_ms"],
                    }
                    for i, s in enumerate(segments)
                ]
            ).execute()

        sb.table("articles").update({"status": "ready"}).eq("id", article_id).execute()
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(traceback.format_exc(), flush=True)  # Railway ログに完全なトレースを残す
        sb.table("articles").update(
            {"status": "failed", "error": f"変換エラー: {exc}"[:300]}
        ).eq("id", article_id).execute()


# --- パイプライン各段（実装ポイント。MVPで埋める）---


_TAG_RE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.DOTALL | re.IGNORECASE)
_HTML_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"[ \t]*\n[ \t\n]*")


def _html_to_text(html: str) -> str:
    """GPT に渡す前の軽量クリーニング。script/style とタグを除去し空白を畳む。"""
    html = _TAG_RE.sub(" ", html)
    text = _HTML_RE.sub(" ", html)
    text = re.sub(r"[ \t]{2,}", " ", text)
    text = _WS_RE.sub("\n", text)
    # GPT のトークン上限・コスト対策に過大な入力は頭側を採用（記事本文は前方に集中）。
    return text.strip()[:24000]


import datetime as _dt  # noqa: E402

# 公開日時の抽出。構造化データ(JSON-LD/meta/<time>)から拾う方が GPT 推測より確実。
# _html_to_text はタグを落とすので、この抽出は生HTMLに対して行う。
_JSONLD_PUB = re.compile(r'"datePublished"\s*:\s*"([^"]+)"', re.IGNORECASE)
_META_TAG = re.compile(r"<meta\b[^>]*>", re.IGNORECASE)
_META_ATTR = re.compile(
    r"""([\w:.-]+)\s*=\s*"([^"]*)"|([\w:.-]+)\s*=\s*'([^']*)'"""
)
_TIME_TAG = re.compile(
    r"""<time\b[^>]*\bdatetime\s*=\s*["']([^"']+)["']""", re.IGNORECASE
)
# meta の property/name/itemprop がこれらなら公開日時とみなす（小文字比較）。
_PUB_KEYS = {
    "article:published_time",
    "og:published_time",
    "datepublished",
    "pubdate",
    "publishdate",
    "publish-date",
    "date",
    "dc.date.issued",
    "dc.date",
    "sailthru.date",
}


def _parse_dt(s: str) -> _dt.datetime | None:
    """様々な日時表記を datetime へ。失敗したら None。"""
    s = (s or "").strip()
    if not s:
        return None
    try:
        return _dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        pass
    for fmt in (
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y-%m-%d",
        "%Y/%m/%d",
    ):
        try:
            return _dt.datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def _extract_published(html: str) -> str | None:
    """生HTMLから記事の公開日時を ISO 文字列で抽出（取れなければ None）。"""
    # 1. JSON-LD の datePublished（ニュース記事で最も信頼できる）
    m = _JSONLD_PUB.search(html)
    if m and (dt := _parse_dt(m.group(1))):
        return dt.isoformat()
    # 2. <meta> の各種公開日時キー（属性順に依存しないよう属性を辞書化）
    for tag in _META_TAG.findall(html):
        attrs: dict[str, str] = {}
        for a in _META_ATTR.finditer(tag):
            key = (a.group(1) or a.group(3) or "").lower()
            val = a.group(2) if a.group(2) is not None else a.group(4)
            attrs[key] = val or ""
        label = attrs.get("property") or attrs.get("name") or attrs.get("itemprop")
        if label and label.lower() in _PUB_KEYS and (dt := _parse_dt(attrs.get("content", ""))):
            return dt.isoformat()
    # 3. <time datetime="...">
    m = _TIME_TAG.search(html)
    if m and (dt := _parse_dt(m.group(1))):
        return dt.isoformat()
    return None


async def extract_article(url: str) -> tuple[str, str, Lang, str | None]:
    """記事URLを取得し、GPT-4o でタイトル・本文・言語をJSON抽出する。

    併せて生HTMLから公開日時(published_at)を構造化データから拾う（取れなければ None）。
    """
    async with httpx.AsyncClient(
        follow_redirects=True,
        timeout=30,
        headers={"User-Agent": "Mozilla/5.0 (compatible; SyncNewsBot/0.1)"},
    ) as client:
        resp = await client.get(url)
        resp.raise_for_status()
    published = _extract_published(resp.text)
    cleaned = _html_to_text(resp.text)

    client = _openai()
    completion = await client.chat.completions.create(
        model=_GPT_MODEL,
        temperature=0,
        response_format={"type": "json_object"},
        messages=[
            {
                "role": "system",
                "content": (
                    "あなたはWebニュースの本文抽出器です。与えられたページテキストから、"
                    "ナビ・広告・関連記事・コメントを除いた『記事本文』だけを抽出します。"
                    'JSONで {"title": str, "body": str, "lang": "ja"|"en"} を返してください。'
                    "body は段落を改行で区切り、原文の言語のまま。lang は本文の主言語。"
                ),
            },
            {"role": "user", "content": cleaned},
        ],
    )
    data = json.loads(completion.choices[0].message.content or "{}")
    lang: Lang = "en" if data.get("lang") == "en" else "ja"
    return data.get("title", "").strip(), data.get("body", "").strip(), lang, published


async def translate(text: str, target: Lang) -> str:
    """GPT-4o で対向言語へ翻訳。

    フロントの言語切替(index一致)を効かせるため『1行=1文』を厳守させ、
    原文と訳文の文数・順序を一致させる。
    """
    target_name = "英語" if target == "en" else "日本語"
    client = _openai()
    completion = await client.chat.completions.create(
        model=_GPT_MODEL,
        temperature=0.2,
        messages=[
            {
                "role": "system",
                "content": (
                    f"あなたはプロの翻訳者です。入力を自然な{target_name}に翻訳します。"
                    "重要な制約: 出力は『1行に1文』。入力を文単位に分け、"
                    "原文の文数・順序と1対1で対応させること（文を統合/分割しない）。"
                    "余計な見出し・注釈・番号は付けない。"
                ),
            },
            {"role": "user", "content": text},
        ],
    )
    return (completion.choices[0].message.content or "").strip()


async def tts_with_timestamps(text: str, lang: Lang) -> tuple[bytes, list[dict]]:
    """ElevenLabs /with-timestamps を呼び、音声と文字単位タイムスタンプを得る。

    返り値: (mp3 bytes, [{'char', 'start_ms', 'end_ms'}, ...])
    """
    voice = os.environ[
        "ELEVENLABS_VOICE_EN" if lang == "en" else "ELEVENLABS_VOICE_JA"
    ]
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice}/with-timestamps"
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(
            url,
            headers={
                "xi-api-key": os.environ["ELEVENLABS_API_KEY"],
                "Content-Type": "application/json",
            },
            json={
                "text": text,
                "model_id": _ELEVEN_MODEL,
                "output_format": "mp3_44100_128",
            },
        )
        resp.raise_for_status()
    payload = resp.json()

    audio = base64.b64decode(payload["audio_base64"])
    align = payload["alignment"]
    chars = [
        {
            "char": ch,
            "start_ms": round(s * 1000),
            "end_ms": round(e * 1000),
        }
        for ch, s, e in zip(
            align["characters"],
            align["character_start_times_seconds"],
            align["character_end_times_seconds"],
        )
    ]
    return audio, chars


_SENT_END = "。．.!?！？\n"
# 区切り記号・空白を除いて実体（文字）が残るか＝中身のある文かの判定用
_CONTENT = re.compile(r"[^\s。．.!?！？、,…「」『』（）()]")


def _is_break(s: str, i: int) -> bool:
    """s[i] が文末区切りか。数字に挟まれた "." / "．"（小数点）は文末とみなさない。"""
    ch = s[i]
    if ch not in _SENT_END:
        return False
    if ch in ".．" and 0 < i < len(s) - 1 and s[i - 1].isdigit() and s[i + 1].isdigit():
        return False  # 0.1 のような小数点
    return True


def aggregate_to_sentences(chars: list[dict]) -> list[dict]:
    """文字タイムスタンプを文(。/./!/?)単位の SyncSegment へ集約。

    ・「。\\n」のような区切りの連続で生じる空セグメントは捨てる（文数の水増し防止）。
    ・"0.1" のような小数点は文末扱いしない。
    """
    s = "".join(c["char"] for c in chars)
    out: list[dict] = []
    start_idx = 0
    start_ms = chars[0]["start_ms"] if chars else 0
    for i, c in enumerate(chars):
        if _is_break(s, i):
            text = s[start_idx : i + 1].strip()
            if _CONTENT.search(text):
                out.append({"text": text, "start_ms": start_ms, "end_ms": c["end_ms"]})
            start_idx, start_ms = i + 1, c["end_ms"]
    tail = s[start_idx:].strip()
    if chars and _CONTENT.search(tail):
        out.append({"text": tail, "start_ms": start_ms, "end_ms": chars[-1]["end_ms"]})
    return out


def _split_sentences(text: str) -> list[str]:
    """テキストを文単位の文字列に分割（aggregate_to_sentences と同じ境界規則）。
    日本語の「表示用（漢字）」文と、合成カナのタイミング文を1:1で対応付けるため。"""
    out: list[str] = []
    start = 0
    for i in range(len(text)):
        if _is_break(text, i):
            t = text[start : i + 1].strip()
            if _CONTENT.search(t):
                out.append(t)
            start = i + 1
    t = text[start:].strip()
    if _CONTENT.search(t):
        out.append(t)
    return out


# 漢字（CJK統合漢字＋々〆ヶ）を含むか
_HAS_KANJI = re.compile(r"[一-鿿々〆ヶ]")
_ja_tokenizer = None  # 初回利用時に遅延生成（辞書ロードが重いため）


def _kata_to_hira(s: str) -> str:
    """カタカナをひらがなへ変換（長音符ー・中点・数字・英字等はそのまま）。

    sudachi の reading_form はカタカナで返るが、合成テキストに長いカタカナ列が
    並ぶとニューラルTTSが『外来語/強調』的な区切れた韻律になり、語の途中や
    長音符でつっかえる。読みをひらがなにすると自然なかな文に近づき韻律が安定する
    （音は同じ。本来のカタカナ語＝サーバー等は別トークンで原文のまま残る）。
    """
    out: list[str] = []
    for ch in s:
        o = ord(ch)
        out.append(chr(o - 0x60) if 0x30A1 <= o <= 0x30F6 else ch)
    return "".join(out)


def _to_reading_ja(text: str) -> str:
    """漢字の誤読を避けるため、形態素解析で読み（かな）へ変換する。

    ・漢字を含む語のみ読みに置換し、記号・数字・カナ・英字は原文のまま残す
      （括弧が「キゴウ」と読まれる、数字が桁読みされる等を防ぐ）。
    ・読みはひらがなにする（カタカナ過多による不自然な区切れを防ぐ）。
    ・表示は元の漢字のまま。合成音声だけこの読みを使う。
    """
    global _ja_tokenizer
    if _ja_tokenizer is None:
        from sudachipy import dictionary, tokenizer

        _ja_tokenizer = (
            dictionary.Dictionary().create(),
            tokenizer.Tokenizer.SplitMode.C,
        )
    tok, mode = _ja_tokenizer
    parts: list[str] = []
    for m in tok.tokenize(text, mode):
        surface = m.surface()
        reading = m.reading_form()
        if _HAS_KANJI.search(surface) and reading:
            parts.append(_kata_to_hira(reading))
        else:
            parts.append(surface)
    return "".join(parts)


async def synthesize_segments(display_text: str, lang: Lang) -> tuple[bytes, list[dict]]:
    """表示テキストから、音声＋文単位セグメント（表示用テキスト＋タイムスタンプ）を生成。

    ja は漢字の誤読を避けるため合成にはカナ読みを使い、segments の text には
    元の漢字の文を入れる（タイミングはカナ合成から、文単位で1:1対応付け）。
    en はそのまま。
    """
    speech_text = _to_reading_ja(display_text) if lang == "ja" else display_text
    audio, char_ts = await tts_with_timestamps(speech_text, lang)
    timing = aggregate_to_sentences(char_ts)

    if lang != "ja":
        return audio, timing

    display_sents = _split_sentences(display_text)
    n = min(len(timing), len(display_sents))
    segments = [
        {
            "text": display_sents[i],
            "start_ms": timing[i]["start_ms"],
            "end_ms": timing[i]["end_ms"],
        }
        for i in range(n)
    ]
    return audio, segments
