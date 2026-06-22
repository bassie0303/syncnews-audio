# SyncNews Audio ブラウザ拡張（認証対応 v2）

開いているニュース記事を、ツールバーのアイコンから**自分のアカウントに登録**（変換開始）する Chrome/Edge 拡張機能です。

`backend` の `/bookmarklet`（ブックマークレット）の拡張版。ログイン式で、**有料会員ページ**にも対応します。

## 仕組み

1. アイコンをクリックするとポップアップが開く。
2. **初回のみ**、メール＋パスワードでログイン（Supabase Auth）。セッションは `chrome.storage.local` に保存され、以降は自動。
3. **「この記事を登録」** を押すと、現在タブの **URL とページHTML** を `POST /api/articles`（**JWT認証付き**）へ送信。
   - 本人の記事として新構成（公開メタ `syncnews` ＋ 本文は金庫 `syncnews_vault` ＋ 音声は非公開バケット）に登録される。
   - **ページHTMLも送る**ので、あなたが閲覧権を持つ**有料会員記事**の本文も処理できる（サーバはHTMLがあれば再取得しない）。
   - 結果はポップアップに表示。アプリの一覧に「コンバート中…→準備完了」として現れる。

旧版（v1）の「anonで `/api/submit` に投げる」方式は廃止。第三者著作物が公開API経路に出ない設計に合わせています。

## ファイル
- `manifest.json` … MV3。`activeTab`/`scripting`/`storage` 権限、host は Railway と Supabase のみ。
- `popup.html` / `popup.js` … ログイン＋登録UI、Auth（GoTrue REST）、HTML取得・送信。
- `config.js` … `API_BASE` / `SUPABASE_URL` / `SUPABASE_ANON_KEY`（**anonは公開キーなので同梱可**）。

## インストール（未署名・ローカル読み込み）

Chrome / Edge:

1. `chrome://extensions`（Edge は `edge://extensions`）を開く
2. 右上の **「デベロッパー モード」** をオン
3. **「パッケージ化されていない拡張機能を読み込む」** → この `extension/` フォルダを選択
4. ツールバーにアイコンが出る（見えなければパズルピース→ピン留め）

以降、登録したいニュース記事のページで **アイコンをクリック → （初回はログイン）→「この記事を登録」**。

## 注意

- デプロイ先URL／プロジェクトを変えたら `config.js` と `manifest.json` の `host_permissions` を更新。
- `config.js` の `SUPABASE_ANON_KEY` は公開前提のクライアントキー。**service_role 等の秘密鍵は絶対に置かない**。
- 本文がHTMLに含まれない記事（例: 日経の紙面ビューア `/paper/article/`）は対象外。
- Chrome Web Store への公開は未対応（ローカル読み込みのみ）。
