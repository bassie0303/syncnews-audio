-- 失敗理由カラムを追加（クレジットガード: 一覧の失敗カードに理由を表示）。
-- 本番 Supabase の SQL Editor で一度だけ実行する。冪等（既にあれば何もしない）。
-- backend のクレジットガード/エラー記録より前に必ず適用すること
-- （未適用のままだと error 更新が失敗し、処理が processing のまま止まりうる）。
alter table articles add column if not exists error text;
