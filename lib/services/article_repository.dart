import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/article.dart';

/// Supabase 上の記事データへのアクセス。
///
/// - 一覧はリアルタイム購読（変換中→準備完了の状態遷移が自動で反映される）
/// - 再生時のみ tracks/segments まで含めて取得（一覧では重いので分離）
class ArticleRepository {
  final SupabaseClient _db = Supabase.instance.client;

  /// 記事一覧（メタのみ）を新しい順でリアルタイム購読する。
  Stream<List<Article>> watch() {
    return _db
        .from('articles')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map((rows) => rows.map(Article.fromJson).toList());
  }

  /// 記事一覧（メタのみ）を一度だけ取得する（プルリフレッシュ／復帰時の即時補完用）。
  /// Realtime ストリームが切れている間でも確実に最新を取り直せる。
  Future<List<Article>> fetchList() async {
    final rows = await _db
        .from('articles')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Article.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// 変換対象の articles 行を作成し id を返す（status は既定の pending）。
  /// title / source_lang は変換時に extract 結果で上書きされるため暫定値でよい。
  Future<String> create(String sourceUrl) async {
    final row = await _db
        .from('articles')
        .insert({'source_url': sourceUrl, 'source_lang': 'ja'})
        .select('id')
        .single();
    return row['id'] as String;
  }

  /// 再生用に tracks＋segments まで含めて1記事を取得する。
  /// segments のDB列 `idx` を `index` にエイリアスして models と整合させる。
  Future<Article> fetchFull(String id) async {
    final row = await _db
        .from('articles')
        .select(
          '*, tracks(lang, audio_url, '
          'segments(index:idx, text, start_ms, end_ms))',
        )
        .eq('id', id)
        .single();
    final article = Article.fromJson(row);
    // PostgREST のネスト結果は順序保証がないため idx 昇順に整える。
    for (final track in article.tracks.values) {
      track.segments.sort((a, b) => a.index.compareTo(b.index));
    }
    return article;
  }
}
