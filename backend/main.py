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

from fastapi import FastAPI  # noqa: E402
from pydantic import BaseModel  # noqa: E402
from supabase import Client, create_client  # noqa: E402

app = FastAPI(title="SyncNews Audio Convert Worker")

Lang = Literal["ja", "en"]


def _supabase() -> Client:
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],  # サーバ専用キー
    )


class ConvertRequest(BaseModel):
    article_id: str
    source_url: str


@app.get("/api/health")
def health() -> dict:
    """Railway ヘルスチェック。必要キーの有無も返す。"""
    return {
        "ok": True,
        "openai": bool(os.environ.get("OPENAI_API_KEY")),
        "elevenlabs": bool(os.environ.get("ELEVENLABS_API_KEY")),
        "supabase": bool(os.environ.get("SUPABASE_URL")),
    }


@app.post("/api/convert")
async def convert(req: ConvertRequest) -> dict:
    """記事を変換して日英の tracks/segments を生成する。"""
    sb = _supabase()
    sb.table("articles").update({"status": "processing"}).eq("id", req.article_id).execute()

    try:
        # 1. 本文抽出（言語判定込み）
        title, body, lang = await extract_article(req.source_url)
        sb.table("articles").update(
            {"title": title, "source_lang": lang}
        ).eq("id", req.article_id).execute()

        # 2. 対向言語へ翻訳
        target: Lang = "en" if lang == "ja" else "ja"
        translated = await translate(body, target)

        # 3. 各言語で TTS+TS -> 文集約 -> Storage/DB 保存
        for l, text in ((lang, body), (target, translated)):
            audio_bytes, char_ts = await tts_with_timestamps(text, l)
            segments = aggregate_to_sentences(char_ts)

            audio_path = f"{req.article_id}/{l}.mp3"
            sb.storage.from_("audio").upload(
                audio_path, audio_bytes, {"content-type": "audio/mpeg", "upsert": "true"}
            )
            public_url = sb.storage.from_("audio").get_public_url(audio_path)

            track = (
                sb.table("tracks")
                .upsert({"article_id": req.article_id, "lang": l, "audio_url": public_url})
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

        sb.table("articles").update({"status": "ready"}).eq("id", req.article_id).execute()
        return {"ok": True}
    except Exception as e:  # noqa: BLE001
        sb.table("articles").update({"status": "failed"}).eq("id", req.article_id).execute()
        return {"ok": False, "error": str(e)}


# --- パイプライン各段（実装ポイント。MVPで埋める）---


async def extract_article(url: str) -> tuple[str, str, Lang]:
    """本文・タイトル・言語をGPT-4oでJSON抽出するのが手堅い。"""
    raise NotImplementedError("TODO: GPT-4o で本文抽出・言語判定")


async def translate(text: str, target: Lang) -> str:
    """GPT-4o。フロントの言語切替(index一致)が効くよう「1行=1文」で訳す。"""
    raise NotImplementedError("TODO: GPT-4o 翻訳（1行1文を厳守）")


async def tts_with_timestamps(
    text: str, lang: Lang
) -> tuple[bytes, list[dict]]:
    """ElevenLabs /with-timestamps を呼ぶ。voice は lang で出し分け。
    返り値: (音声bytes, [{'char','start_ms','end_ms'}, ...])"""
    raise NotImplementedError("TODO: ElevenLabs with-timestamps")


_SENT_END = re.compile(r"[。．.!?！？\n]")


def aggregate_to_sentences(chars: list[dict]) -> list[dict]:
    """文字タイムスタンプを文(。/./!/?)単位の SyncSegment へ集約。"""
    out: list[dict] = []
    buf = ""
    start = chars[0]["start_ms"] if chars else 0
    for c in chars:
        buf += c["char"]
        if _SENT_END.search(c["char"]):
            out.append({"text": buf.strip(), "start_ms": start, "end_ms": c["end_ms"]})
            buf, start = "", c["end_ms"]
    if buf.strip():
        out.append({"text": buf.strip(), "start_ms": start, "end_ms": chars[-1]["end_ms"]})
    return out
