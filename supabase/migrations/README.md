# Supabase マイグレーション（手動適用）

第三者著作物を公開API経路から隔離する二スキーマ構成。**SQLの実行は手動**（Supabase SQL Editor）。

## 適用順
1. `0001_schemas.sql` — スキーマ作成・権限（syncnews / syncnews_vault）
2. `0002_syncnews_articles.sql` — 公開メタテーブル（RLS・Realtime）
3. `0003_vault_content.sql` — 金庫テーブル（タイトル・本文・英訳）

## ダッシュボードで必要な手動設定（SQLでは完結しない）

### 1. Exposed schemas（最重要・公開ゲート）
Settings → API → **Exposed schemas** に **`syncnews` だけ追加**する。
**`syncnews_vault` は絶対に追加しない**。これが第三者著作物を公開APIから出さない最後の砦。
（既存の `public` は、下の「旧構成のクローズ」が済むまでは残る点に注意）

### 2. Storage バケットを「非公開」に
- `audio` バケットを **Private** にする（公開URL不可）。
- 再生時はサーバ（Railway バックエンド / service_role）が **短期署名URL（6時間）** を発行して渡す。
- パス規約: `audio/{article_id}/{lang}.mp3`

### 3. Auth（メールアカウント）
Authentication → Providers で **Email** を有効化。RLS の `auth.uid()` に紐づくため、
記事の所有者付与（`articles.user_id`）に認証ユーザーが必要。

## 旧構成（public スキーマ）のクローズ ✅ 実施済み（2026-06 / 露出のみ閉鎖・データは残置）
- [x] 旧データ（タイトル・本文・音声）を新スキーマ＋非公開バケットへ移設（`migrate_public_to_new.py`）
- [x] 旧 public の anon ポリシー撤去（直結PGで `drop policy`。anon/authenticated とも読めない＝既定deny）
- [x] `audio` バケットの公開→非公開化（旧公開URLは HTTP 400 で遮断確認）
- [x] アプリ/バックエンドの読み書きを新スキーマ（gate）へ切替
- 残置（バックアップ）: `public.articles/tracks/segments` テーブルと旧 `audio` バケットのファイルは
  当面残す（公開はされない）。完全に不要になったら drop / 削除してよい。
- 残作業（任意）: 旧 anon エンドポイント（`/api/convert`・anon `/api/submit`・`/submit`・`/bookmarklet`）は
  public へ書くだけで新アプリは読まないため実質無効。ブックマークレットを認証対応にするか撤去する。

## アプリ/バックエンドの実装方針（合意済み・別タスク）
- **supabase-js / supabase_flutter は通常操作で schema=syncnews を使う**（`.schema('syncnews')`）。
- **vault に触る処理はサーバ側に限定**。具体的には Railway バックエンドに
  再生用ゲート `GET /api/playback/{id}` を追加し、本人認証＋所有チェックのうえで
  「本文セグメント（日英）＋日英音声の署名URL（6時間）」を返す。
- 一覧/状態/Realtime は `syncnews.articles` を直読み（メタのみ＝安全）。タイトルはゲート経由で取得。

### ⚠️ 重要: vault は PostgREST(REST) から到達不能（検証済み）
Exposed schemas に入れていないため、**service_role キーを使っても `supabase-py`/`supabase-js` の
REST 経由では vault に読み書きできない**（`PGRST106: Invalid schema: syncnews_vault` で拒否される。
これがゲートの実体）。したがって:
- **vault への読み書きは「直接 Postgres 接続」**（接続文字列で psycopg/asyncpg、または Edge Function の
  直接DB接続）で行う。`sb.schema('syncnews_vault')...` は使えない。
- 公開メタ（`syncnews.articles`）は従来どおり REST/`.schema('syncnews')` でよい。
- 接続文字列は Supabase ダッシュボード → Database → Connection string（**サーバ専用・.env**）。
