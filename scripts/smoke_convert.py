#!/usr/bin/env python3
"""変換パイプラインのスモークテスト（Supabase不要・APIキーのみ）。

backend/main.py の本物の関数（extract_article / translate /
tts_with_timestamps / aggregate_to_sentences）をそのまま呼び、
記事URL → 抽出 → 対訳 → TTS+タイムスタンプ → 文セグメント化 までを
ローカルファイルに書き出して目視確認するための単体疎通スクリプト。

使い方:
    cd backend
    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    # .env に OPENAI_API_KEY / ELEVENLABS_API_KEY / ELEVENLABS_VOICE_JA / _EN を設定
    python ../scripts/smoke_convert.py "https://www3.nhk.or.jp/news/..."

出力（scripts/out/ 配下）:
    source.txt / translated.txt … 抽出本文・対訳
    ja.mp3 / en.mp3              … 生成音声
    segments.json               … 文単位の対訳＋日英タイムスタンプ
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

# backend/ をインポートパスに追加して main の関数を再利用する
_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "backend"))

from main import (  # noqa: E402
    aggregate_to_sentences,
    extract_article,
    translate,
    tts_with_timestamps,
)

_OUT = Path(__file__).resolve().parent / "out"


async def run(url: str) -> None:
    _OUT.mkdir(exist_ok=True)

    print(f"[1/4] 抽出: {url}")
    title, body, src_lang = await extract_article(url)
    tgt_lang = "en" if src_lang == "ja" else "ja"
    (_OUT / "source.txt").write_text(f"# {title}\n\n{body}", encoding="utf-8")
    print(f"  title={title!r} lang={src_lang} 本文{len(body)}字")

    print(f"[2/4] 翻訳: {src_lang} -> {tgt_lang}")
    translated = await translate(body, tgt_lang)
    (_OUT / "translated.txt").write_text(translated, encoding="utf-8")
    print(f"  訳文{len(translated)}字")

    # 言語ごとに TTS → 文セグメント化
    texts = {src_lang: body, tgt_lang: translated}
    seg_by_lang: dict[str, list[dict]] = {}
    for i, (lang, text) in enumerate(texts.items(), start=3):
        print(f"[{i}/4] TTS+TS: {lang}")
        audio, chars = await tts_with_timestamps(text, lang)
        (_OUT / f"{lang}.mp3").write_bytes(audio)
        segs = aggregate_to_sentences(chars)
        seg_by_lang[lang] = segs
        print(f"  audio {len(audio)} bytes / {len(segs)} 文")

    (_OUT / "segments.json").write_text(
        json.dumps(seg_by_lang, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # 文数アライメント（言語切替の迷子防止が効く前提）の簡易チェック
    n = {k: len(v) for k, v in seg_by_lang.items()}
    print(f"\n文数: {n}")
    if len(set(n.values())) == 1:
        print("✅ 日英の文数が一致（index串刺しが成立）")
    else:
        print("⚠️ 文数が不一致 → 言語切替は相対進捗フォールバックになる")
    print(f"出力: {_OUT}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "https://www3.nhk.or.jp/news/"
    asyncio.run(run(target))
