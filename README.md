# SyncNews Audio

テキスト同期型・多言語コンバートニュースリーダー（Flutter / Supabase）。
歩行中は「音声」、電車内では「テキスト」へシームレスに切り替えながら、
興味のあるWebニュースで語学学習（リスニング/リーディング）を行うためのアプリ。

---

## 1. 技術スタック選定（と理由）

| レイヤー | 採用 | 理由 |
|---|---|---|
| フロント | **Flutter** | iOS/Android両対応 + バックグラウンド音声プラグイン (`audio_service`/`just_audio`) の成熟度が高い |
| 再生エンジン | **just_audio** | `positionStream`(ms精度)・速度変更・seek。ハイライト同期の心臓部 |
| OSメディア連携 | **audio_service** | ロック画面/コントロールセンター/**イヤホン物理ボタン**をコールバックへ集約 |
| 状態管理 | **Riverpod** | 画面横断のオーディオ状態・記事ストリームを宣言的に |
| BaaS | **Supabase** | Postgres(ミリ秒タイムスタンプをSQLで素直に持てる) + Storage(音声) + Auth(Phase2) |
| 変換ワーカー | **FastAPI（Railway デプロイ）** | 抽出→翻訳→TTSは数十秒の長尺ジョブ。Edge Functions(Deno/TS・〜150s制限)を避け、epiphany/multi_ai_promptと同じ Python+FastAPI+Railway に統一 |
| 本文抽出/翻訳 | **OpenAI GPT-4o** | 本文整形・言語判定・1文1行の対訳生成 |
| TTS+タイムスタンプ | **ElevenLabs (with-timestamps)** | ⚠️ OpenAI TTSは語/文タイムスタンプを返さない。文字単位TSが取れるElevenLabsを採用 |
| ソース管理 | **GitHub** (`bassie0303/syncnews-audio`) | 既存全PJ(`github.com/bassie0303/*`)と統一 |
| デプロイ | アプリ→**TestFlight/Play Console**、変換ワーカー→**Railway** | Flutterアプリ本体はRailwayに載らない（ストア配信）。RailwayはFastAPIワーカーのみ |

> **重要な技術判断**: PRDは「OpenAI TTS または ElevenLabs」だが、
> **テキスト同期の精度を出すにはタイムスタンプが必須**。OpenAI TTS単体ではTSが取れず、
> Whisperでの forced-alignment が別途必要になる。MVPは ElevenLabs の
> `text-to-speech/{voice}/with-timestamps` で文字TSを取得し、文境界で集約する設計にした。

---

## 2. プロジェクト構成

```
011_multilang_news/
├─ lib/
│  ├─ main.dart                       # 起動・Supabase/AudioService初期化
│  ├─ theme/app_theme.dart            # ライト/ダーク ThemeData（後述）
│  ├─ models/
│  │  ├─ article.dart                 # 記事＋言語別トラック
│  │  └─ sync_segment.dart            # ★同期の最小単位(text+start_ms+end_ms)
│  ├─ services/
│  │  └─ audio_player_handler.dart    # ★バックグラウンド音声/ロック画面/イヤホン
│  └─ features/
│     ├─ playlist/playlist_screen.dart   # ストック一覧・URL追加 (PRD 3-2)
│     └─ player/
│        ├─ sync_controller.dart      # ★ms→ハイライトindex/タップ→seek/言語切替の迷子防止
│        └─ player_screen.dart        # 同期プレーヤーUI (PRD 3-3/3-4)
├─ assets/icon/app_icon.svg           # アプリアイコン（既存自作アプリの系譜を継承）
├─ web/favicon.svg                    # ファビコン（同系譜）
├─ supabase/
│  └─ schema.sql                      # articles / tracks / segments（DBはSupabase継続）
├─ backend/                           # ★変換ワーカー（FastAPI / Railway）
│  ├─ main.py                         # 抽出→翻訳→TTS→Storage/DB保存 + /api/health
│  ├─ requirements.txt
│  ├─ railway.toml                    # nixpacks + uvicorn 起動（epiphanyと同作法）
│  └─ .env.example
├─ docs/
│  └─ native_setup.md                 # ★iOS/Android バックグラウンド音声の設定手順
└─ pubspec.yaml
```

★ = Phase1 MVP のコアロジック。

---

## 3. コア設計のポイント

### A. バックグラウンド音声 / イヤホン / ロック画面（技術課題①）
`lib/services/audio_player_handler.dart`。
`audio_service` が OS のメディアセッションを保持するため、ロック画面・コントロール
センター・**イヤホン物理ボタン/AVRCP/OS標準メディアコマンド**はすべて
`play()`/`pause()`/`rewind()`/`fastForward()` コールバックへ自動的に流れ込む
（個別実装不要）。30秒戻し/15秒送りは `MediaControl` と `AudioServiceConfig` の
インターバル両方に反映している。

### B. テキスト⇄音声 リアルタイム同期（技術課題②）
`lib/features/player/sync_controller.dart`。
- **音声→テキスト**: `positionStream`(ms) を購読し、現在文の `index` を算出
  → `ValueNotifier<int>` を UI が listen してハイライト＆自動スクロール。
  毎フレーム全件探索を避け、「現在/隣を先に確認 → 外れたら二分探索」で滑らかさを担保。
- **テキスト→音声**: 文タップで `seekToSegment()` → `player.seek(start)`。
- **言語切替の迷子防止**: 旧トラックの現在地を、文数一致なら同index、
  不一致なら相対進捗(0〜1)で新トラックへマップして着地。

### C. ネイティブ設定（必須）
**iOS** `ios/Runner/Info.plist`:
```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```
**Android** `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<!-- application 内 -->
<service android:name="com.ryanheise.audioservice.AudioService"
  android:foregroundServiceType="mediaPlayback" android:exported="true">
  <intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
</service>
<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
  <intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
</receiver>
```
`MainActivity` は `AudioServiceActivity` を継承させる。

> 📄 iOS/Android の完全な手順・動作確認チェックリストは
> [`docs/native_setup.md`](docs/native_setup.md) を参照。
> イヤホンのダブル/トリプルタップは `skipToNext`/`skipToPrevious` 経由で
> 15秒送り/30秒戻しに割り当て済み。

---

## 4. テーマ / ブランド（デザインポリシー継承）

> ⚠️ 今回チャットにデザイン見本画像の添付はありませんでした。代わりに**既存自作アプリ
> 6本の favicon を解析**し、共通のデザインDNAを抽出して継承しています。
> 別の見本がある場合は共有いただければアイコンを差し替えます。

**抽出した共通DNA**（003 multi_ai / 001 povo / 006 food_share / 009 epiphany / 004 memoir / 010 comutehelper）:
- 512×512・角丸 `rx=115` の**単色背景タイル**
- **白の線画グリフ**（`fill=none stroke=#fff` / `linecap=round` / stroke 24〜36）
- アクセントに**白の塗り円ドット**、アプリごとに1ブランドカラー

**SyncNews Audio の採用**:
- ブランドカラー: **ディープ・インディゴ `#4F46E5`**（既存6色と未重複。学習×音声に合う知的色）
- グリフ: **ヘッドホン**（聴く）＋中央**波形3本**（テキスト同期）＋**2ドット**（JA/EN多言語）
- 同期ハイライト: **アンバー `#FFB020`**（再生中の文。本文中で最も目を引く差し色）

ThemeData は `lib/theme/app_theme.dart` にライト/ダーク両対応で定義
（`ColorScheme.fromSeed(#4F46E5)` ベース + Noto Sans JP）。

### アイコン生成手順
`assets/icon/app_icon.svg` を 1024px PNG に書き出し `assets/icon/app_icon.png` として配置 →
`flutter pub run flutter_launcher_icons`（pubspec に設定済み）で iOS/Android/Web の
`AppIcon` / `favicon.ico` を一括生成。

---

## 5. セットアップ

```bash
# --- アプリ (Flutter) ---
flutter create . --org com.syncnews        # 既存lib/を残してネイティブ足場を生成
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_ANON_KEY=...

# --- 変換ワーカー (FastAPI) 別ターミナル ---
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # OpenAI / ElevenLabs / Supabase(service role) を設定
uvicorn main:app --reload --port 8000
curl -s localhost:8000/api/health | jq   # キー有無の確認

# Supabase: schema.sql を適用、audio バケットを作成
# Railway: backend/ を nixpacks でデプロイ（railway.toml 同梱）
```

## 6. Phase1 残タスク
- [ ] `backend/main.py` の GPT-4o / ElevenLabs 実装（現在スタブ）
- [ ] Supabase realtime で記事ストリーム購読（`PlaylistScreen`へ接続）
- [ ] `receive_sharing_intent` でブラウザ共有メニュー受け取り配線
- [ ] 自動スクロールを `scrollable_positioned_list` に置換（長文最適化）
