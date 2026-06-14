# CLAUDE.md

このファイルは、本リポジトリのコードを扱う際の Claude Code（claude.ai/code）向けガイドです。

## 概要

テキスト同期型・多言語コンバートニュースリーダー **SyncNews Audio**。記事URLを入力 →
（変換ワーカーで）本文抽出 → 対向言語へ翻訳 → 日英それぞれTTS+タイムスタンプ生成 →
同期プレーヤーで「再生位置に合わせた文ハイライト」「文タップで音声シーク」を提供する。
エントリポイントは2つ: **Flutterアプリ**（`lib/main.dart`）と **変換ワーカー**（FastAPI: `backend/main.py`）。
データは **Supabase**（Postgres + Storage）に保存。

## 重要な不変条件（壊してはいけない）

リファクタ中に踏みやすい制約のクイックリファレンス。各項目は後続の該当セクションで詳述しているので、手を入れる前に必ずそちらを読むこと。

- **翻訳は「1行=1文・原文と1:1対応」を厳守** — `translate()` のsystemプロンプトがこれを強制し、ja/en の `segments.idx` を揃える前提。文を統合/分割すると言語切替時の `mapPositionForLanguageSwitch` が相対進捗フォールバックに落ち、ハイライト位置がズレる。（→ *アーキテクチャ：同期エンジンと言語切替の迷子防止*）
- **タイムスタンプは ElevenLabs 固定（OpenAI TTS不可）** — OpenAI TTS は文字/語タイムスタンプを返さない。`tts_with_timestamps()` は ElevenLabs `/with-timestamps` 前提で、`alignment` の文字TSを文境界で集約して `segments` を作る。TTSプロバイダを差し替えると同期の根拠が消える。（→ *アーキテクチャ：タイムスタンプ取得*）
- **`MainActivity` は `AudioServiceActivity` を継承** — `FlutterActivity` 継承だと音声サービスとUIが別エンジンになりバックグラウンドで再生が切れる。（→ *デプロイ* / `docs/native_setup.md`）
- **オーディオは単一の `SyncAudioHandler` を共有** — `main()` で一度だけ `initAudioService()` し、`SyncController`/`PlayerScreen` はこの単一インスタンスの `player`/`positionStream` を使う。画面ごとに `AudioPlayer` を新規生成するとバックグラウンド再生と同期が分離する。（→ *アーキテクチャ：バックグラウンド音声*）
- **Android13+ は再生前に通知許可が必須** — `POST_NOTIFICATIONS` 未許可だと `startForegroundService()` 後に `startForeground()` を5秒以内に呼べず ANR になる。`main()` の初回フレーム後に `ensureNotificationPermission()`（`lib/services/permissions.dart`、Android限定）で要求する。この呼び出しを外すと初回再生でANRが復活する。（→ *アーキテクチャ：バックグラウンド音声*）
- **`/api/convert` はエラーでも HTTP 200 + `{"ok": false, "error": ...}`** — 例外時も `articles.status=failed` に更新したうえで 200 を返す（例外を投げない）。呼び出し側はこの形を前提に分岐する。（→ *アーキテクチャ：変換パイプライン*）
- **`.env` の読み順は固定（共有→個別, `override=True`）** — `backend/main.py` 冒頭で `claude_test/.env`（親の共有）→ `backend/.env` の順に読む。順序を入れ替えると共有側の上書き挙動が逆転する。（→ *環境変数*）
- **`SUPABASE_SERVICE_ROLE_KEY` はサーバ専用** — backend のみで使用し、Flutter には絶対に出さない。アプリ側は anon key を `--dart-define` で渡す。（→ *環境変数*）
- **DBはマイグレーションツールなしの手動DDL** — `supabase/schema.sql` を手動適用。RLSはMVPで匿名読み取り、Phase2で本人限定に切替予定。
- **記述言語は日本語** — UI文字列・コメント・コミットメッセージは日本語。既存スタイルに合わせる。

## コマンド

```bash
# --- アプリ（Flutter）---
bash scripts/setup_native.sh            # 初回のみ。flutter create＋iOS/Android設定を冪等適用
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_ANON_KEY=...

# 開発検証（Supabase/backend不要、モック記事をプレーヤー直行）
flutter run --dart-define=DEV_MOCK=true

# --- 変換ワーカー（FastAPI）別ターミナル ---
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env                     # OpenAI / ElevenLabs / Supabase(service role) を設定
uvicorn main:app --reload --port 8000
curl -s localhost:8000/api/health | jq   # 各APIキーの有無を返す
```

テストスイート・リンター・フォーマッターは未設定。アプリの検証は実機で `docs/native_setup.md`
の動作確認チェックリストに沿って行い、変換ワーカーは `/api/health` と実URLでの `/api/convert`
疎通で確認する。

## デプロイ

- **アプリ本体**: Railwayには載らない。**TestFlight（iOS）/ Play Console（Android）** で配信。
  バックグラウンド音声には iOS/Android のネイティブ設定が必須（`docs/native_setup.md`）。
- **変換ワーカー（`backend/`）**: **Railway**（`railway.toml` 同梱、`builder=nixpacks`）。
  起動は `uvicorn main:app --host 0.0.0.0 --port ${PORT}`、ヘルスチェックは `/api/health`。
- **DB / Storage / Auth**: **Supabase**（マネージド）。`schema.sql` を適用し、`audio` バケットを作成。

## 環境変数

| 変数 | 用途 |
| --- | --- |
| `SUPABASE_URL` | アプリ・backend 双方。Supabase プロジェクトURL |
| `SUPABASE_ANON_KEY` | アプリのみ。`--dart-define` で渡すクライアント用キー |
| `SUPABASE_SERVICE_ROLE_KEY` | **backend専用**。Storage/DB書き込み。クライアントに出さない |
| `OPENAI_API_KEY` | backend。GPT-4o 本文抽出・翻訳 |
| `ELEVENLABS_API_KEY` | backend。TTS + 文字タイムスタンプ |
| `ELEVENLABS_VOICE_JA` | backend。日本語TTSのvoice ID |
| `ELEVENLABS_VOICE_EN` | backend。英語TTSのvoice ID |

backend は `claude_test/.env`（共有）→ `backend/.env`（個別）の順で読み込み、いずれも `override=True`。

## プロジェクト構成

| パス | 役割 |
| --- | --- |
| `lib/main.dart` | 起動。Supabase初期化 + `initAudioService()` で単一ハンドラ生成 |
| `lib/theme/app_theme.dart` | ライト/ダーク ThemeData（ブランド `#4F46E5`）+ `AppColors`（ハイライト アンバー） |
| `lib/models/sync_segment.dart` | `SyncSegment`（text/start/end）と `LocalizedTrack`（言語別の音声URL+segments） |
| `lib/models/article.dart` | `Article`（ja/en の `tracks` を保持）。`track(lang)` で取得 |
| `lib/services/audio_player_handler.dart` | ★`SyncAudioHandler`。バックグラウンド音声/ロック画面/イヤホン |
| `lib/services/share_receiver.dart` | ブラウザ共有メニューからのURL受信（`receive_sharing_intent`、web無効） |
| `lib/services/permissions.dart` | Android13+ の通知許可要求（FGS/ANR対策） |
| `lib/features/player/sync_controller.dart` | ★同期エンジン。position→index 算出、言語切替の位置マップ |
| `lib/features/player/player_screen.dart` | 同期プレーヤーUI（ハイライト/タップseek/言語独立トグル） |
| `lib/features/home/home_shell.dart` | 通常ホーム。共有URL受信→`onAddUrl`＋スナックバー。`PlaylistScreen` を内包 |
| `lib/features/playlist/playlist_screen.dart` | ストック一覧・URL追加（PRD 3-2） |
| `lib/dev/mock_entry.dart` | 開発検証用。`--dart-define=DEV_MOCK=true` でモック記事を `PlayerScreen` 直行 |
| `scripts/setup_native.sh` | `flutter create`＋iOS/Android のバックグラウンド音声・共有intent設定を冪等適用 |
| `ios/ShareExtension/` | iOS Share Extension 雛形（Xcodeで手動ターゲット追加が必要） |
| `backend/main.py` | ★変換ワーカー（FastAPI）。抽出→翻訳→TTS→保存 + `/api/health` |
| `backend/railway.toml` | Railwayデプロイ設定（nixpacks + uvicorn） |
| `supabase/schema.sql` | `articles` / `tracks` / `segments`（手動適用） |
| `docs/native_setup.md` | iOS/Android バックグラウンド音声の設定手順・動作確認チェックリスト |
| `assets/icon/app_icon.svg`, `web/favicon.svg` | アイコン/ファビコン（下記「既知のクセ」参照） |

## アーキテクチャ

### 変換パイプライン（`backend/main.py`）
`POST /api/convert {article_id, source_url}` で `articles.status` を
`processing` → 各段実行 → `ready` と遷移させる。流れ:
`extract_article`（httpxで取得 → `_html_to_text` で軽量クリーン → GPT-4o で
`{title, body, lang}` をJSON抽出）→ `translate`（GPT-4oで対向言語へ1:1翻訳）→
言語ごとに `tts_with_timestamps`（ElevenLabs）→ `aggregate_to_sentences` で
文単位segmentへ集約 → Storage(`audio/{article_id}/{lang}.mp3`) と `tracks`/`segments` に保存。
**例外は投げず**、`status=failed` に更新して HTTP 200 + `{"ok": false, "error": ...}` を返す。

### 同期エンジンと言語切替の迷子防止（`sync_controller.dart`）
- **音声→テキスト**: `positionStream`(ms) を購読し、現在index有効→隣→二分探索の順で
  現在文を確定（毎フレーム全件線形探索を避けるのが滑らかさの肝）。`ValueNotifier<int>` を
  UIが listen してハイライト + 自動スクロール。
- **テキスト→音声**: 文タップで `seekToSegment()` → `audio.seek(segment.start)`。
- **言語切替**: `mapPositionForLanguageSwitch()` が、ja/en の文数一致時は同 `idx` の先頭へ、
  不一致時は相対進捗(0〜1)で着地。文数一致を保つため翻訳の1:1制約が前提（不変条件参照）。

### バックグラウンド音声（`audio_player_handler.dart`）
`SyncAudioHandler extends BaseAudioHandler with SeekHandler`。just_audio の状態を
`playbackState` に橋渡しし、ロック画面/コントロールセンター/イヤホンの操作が
`play`/`pause`/`rewind`(30秒)/`fastForward`(15秒) に流入する。イヤホンのダブル/トリプルタップ
（`skipToNext`/`skipToPrevious`）は **15秒送り/30秒戻し** に割り当て。OS連携は
ネイティブ設定（`docs/native_setup.md`）が前提。Android13+ では再生前に通知許可が必要
（不変条件参照）。

### 共有メニュー受け取り（PRD 3-1 方法2）
`ShareReceiver`（`share_receiver.dart`）が `receive_sharing_intent` で
コールド/ホット双方の共有URLを受信し、`HomeShell` が `onAddUrl` へ渡す。
Android は `MainActivity` の `ACTION_SEND text/*` intent-filter（`setup_native.sh` で適用）、
iOS は Share Extension（`ios/ShareExtension/` 雛形＋Xcode手動）。web は `kIsWeb` で無効。

### タイムスタンプ取得（なぜ ElevenLabs か）
PRDは「OpenAI TTS または ElevenLabs」だが、テキスト同期にはタイムスタンプが必須で、
OpenAI TTS単体では取れない（Whisperでの forced-alignment が別途必要）。よって
`/text-to-speech/{voice}/with-timestamps`（`eleven_multilingual_v2`）で文字TSを取得し、
`character_start/end_times_seconds` をms化して文境界で集約する設計に固定している。

## 既知のクセ / コードに見えるが違うもの

- **アイコンは推測ベースのプレースホルダ** — `assets/icon/app_icon.svg` と `web/favicon.svg` は
  既存自作アプリのデザイン系譜から推定したもの。**本番アイコンが正**であり、差し替え前提。
- **`ios/`・`android/` は `flutter create` 生成済み** — `setup_native.sh` でバックグラウンド音声・
  共有intent設定を適用済み。ただし **iOS Share Extension は未完**（`ios/ShareExtension/` は雛形のみ、
  Xcodeでのターゲット追加＋App Group が必要）。
- **検証状況** — Web（同期プレーヤーUI）と Android エミュ（ビルド・共有受け取り・バックグラウンド音声・
  通知）は確認済み。**iOS実機と、変換ワーカーの実APIキー疎通は未検証**。ElevenLabsレスポンスの
  `alignment` キー名は初回疎通時に要確認。
- **独立したネストgitリポジトリ** — 親 `claude_test`（`article-summarizer.git`）とは別に、本ディレクトリ
  直下に独自の `.git` を持ち `github.com/bassie0303/011_syncnews-audio` を origin とする。
