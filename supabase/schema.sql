-- SyncNews Audio: スキーマ定義
-- 記事メタ + 言語別トラック + ミリ秒タイムスタンプ付きセグメント。

create type convert_status as enum ('pending', 'processing', 'ready', 'failed');

-- 記事（コンバートの単位）
create table articles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id), -- Phase2 認証用（MVPはnull可）
  source_url  text not null,
  title       text not null default '(無題)',
  source_lang text not null check (source_lang in ('ja','en')),
  status      convert_status not null default 'pending',
  created_at  timestamptz not null default now()
);

-- 言語別トラック（1記事に ja / en の2行）
create table tracks (
  id         uuid primary key default gen_random_uuid(),
  article_id uuid not null references articles(id) on delete cascade,
  lang       text not null check (lang in ('ja','en')),
  -- Supabase Storage の音声ファイル公開URL
  audio_url  text,
  unique (article_id, lang)
);

-- 同期セグメント（文 or 単語単位。ハイライト同期の中核）
create table segments (
  id        bigint generated always as identity primary key,
  track_id  uuid not null references tracks(id) on delete cascade,
  idx       int  not null,          -- トラック内の連番
  text      text not null,
  start_ms  int  not null,          -- トラック先頭からの開始(ms)
  end_ms    int  not null,          -- 終了(ms)
  unique (track_id, idx)
);
create index on segments (track_id, start_ms);

-- RLS（Phase2で本人のみ参照可に。MVPは匿名読み取り許可）
alter table articles enable row level security;
alter table tracks   enable row level security;
alter table segments enable row level security;

-- MVP ポリシー: 匿名(anon)での閲覧と記事追加を許可する。
-- ・articles: アプリが anon キーで一覧購読(select)＋URL登録(insert)
-- ・tracks/segments: 再生時に anon が select（書き込みは backend の service_role が担う）
-- Phase2 でユーザー認証を入れる際に user_id ベースの制限へ差し替える。
create policy "anon select articles" on articles for select to anon using (true);
create policy "anon insert articles" on articles for insert to anon with check (true);
create policy "anon select tracks"   on tracks   for select to anon using (true);
create policy "anon select segments" on segments for select to anon using (true);

-- リアルタイム購読（一覧の status 変化を自動反映）のため publication に追加。
alter publication supabase_realtime add table articles;
