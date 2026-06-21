import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/article.dart';
import '../models/sync_segment.dart';

/// Railway 上の変換ワーカー（FastAPI）への呼び出し。
///
/// 二スキーマ構成では、第三者著作物（本文・タイトル・音声）は公開APIに出さず、
/// すべて**本人認証付きのゲート経由**で取得する:
///   - 一覧:     GET  /api/articles            （メタ＋タイトル）
///   - 再生:     GET  /api/playback/{id}        （本文＋音声6h署名URL）
///   - 登録:     POST /api/articles {url}
///   - 削除:     DELETE /api/articles/{id}
/// 認証は Supabase セッションの access token（Bearer）。
class ConvertApi {
  ConvertApi(this.baseUrl);

  /// 例: https://syncnews-convert-production.up.railway.app
  final String baseUrl;

  Map<String, String> _headers({bool json = false}) {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// 本人の記事一覧（メタ＋タイトル）。本文/音声は含まない（再生時に別途取得）。
  Future<List<Article>> fetchArticles() async {
    if (baseUrl.isEmpty) throw StateError('CONVERT_API_BASE が未設定です');
    final res =
        await http.get(Uri.parse('$baseUrl/api/articles'), headers: _headers());
    if (res.statusCode != 200) {
      throw Exception('一覧の取得に失敗: ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (body['articles'] as List)
        .cast<Map<String, dynamic>>()
        .map(_metaArticle)
        .toList();
  }

  Article _metaArticle(Map<String, dynamic> j) => Article(
        id: j['id'] as String,
        sourceUrl: (j['source_url'] as String?) ?? '',
        title: (j['title'] as String?) ?? '(無題)',
        sourceLang: (j['source_lang'] as String?) ?? 'ja',
        status: ConvertStatus.values.byName(j['status'] as String),
        createdAt: DateTime.parse(j['created_at'] as String),
        publishedAt: j['published_at'] == null
            ? null
            : DateTime.parse(j['published_at'] as String).toLocal(),
        error: j['error'] as String?,
        tracks: const {},
      );

  /// 記事を新規登録（認証必須）。バックエンドが所有者付きで作成し変換を開始する。
  Future<void> createArticle(String url) async {
    if (baseUrl.isEmpty) throw StateError('CONVERT_API_BASE が未設定です');
    final res = await http.post(
      Uri.parse('$baseUrl/api/articles'),
      headers: _headers(json: true),
      body: jsonEncode({'url': url}),
    );
    if (res.statusCode != 200) {
      throw Exception('登録に失敗: ${res.statusCode} ${utf8.decode(res.bodyBytes)}');
    }
  }

  /// 再生用にフル取得（本文セグメント日英＋音声の6時間署名URL）。本人のみ。
  Future<Article> fetchPlayback(Article meta) async {
    if (baseUrl.isEmpty) throw StateError('CONVERT_API_BASE が未設定です');
    final res = await http.get(
      Uri.parse('$baseUrl/api/playback/${meta.id}'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('再生データの取得に失敗: ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final segs = (body['segments'] as Map<String, dynamic>?) ?? const {};
    final audio = (body['audio'] as Map<String, dynamic>?) ?? const {};
    final tracks = <String, LocalizedTrack>{};
    for (final lang in const ['ja', 'en']) {
      final list = (segs[lang] as List? ?? const []).cast<Map<String, dynamic>>();
      tracks[lang] = LocalizedTrack(
        lang: lang,
        audioUrl: (audio[lang] as String?) ?? '',
        segments: [
          for (var i = 0; i < list.length; i++)
            SyncSegment(
              index: (list[i]['idx'] as int?) ?? i,
              text: list[i]['text'] as String,
              start: Duration(milliseconds: list[i]['start_ms'] as int),
              end: Duration(milliseconds: list[i]['end_ms'] as int),
            ),
        ],
      );
    }
    return Article(
      id: meta.id,
      sourceUrl: meta.sourceUrl,
      title: (body['title'] as String?) ?? meta.title,
      sourceLang: meta.sourceLang,
      status: meta.status,
      createdAt: meta.createdAt,
      publishedAt: meta.publishedAt,
      error: meta.error,
      tracks: tracks,
    );
  }

  /// 記事を削除（履歴削除／進行中ならキャンセル）。本人のみ（認証ヘッダで判定）。
  Future<void> deleteArticle(String articleId) async {
    if (baseUrl.isEmpty) throw StateError('CONVERT_API_BASE が未設定です');
    final res = await http.delete(
      Uri.parse('$baseUrl/api/articles/$articleId'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('削除に失敗: ${res.statusCode} ${utf8.decode(res.bodyBytes)}');
    }
  }

  /// ElevenLabs の残クレジット（文字数）。登録前の残量表示用（認証不要）。
  Future<int?> remainingCredits() async {
    if (baseUrl.isEmpty) return null;
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/quota'));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['ok'] != true) return null;
      return (json['remaining'] as num).toInt();
    } catch (_) {
      return null;
    }
  }
}
