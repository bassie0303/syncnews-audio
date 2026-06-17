import 'sync_segment.dart';

enum ConvertStatus { pending, processing, ready, failed }

/// コンバート済み記事。日本語入力でも英語入力でも、
/// 最終的に ja / en 両トラックを保持する（PRD 3-1 の生成資産の組み合わせ）。
class Article {
  final String id;
  final String sourceUrl;
  final String title;
  final String sourceLang; // 入力された元言語 'ja' | 'en'
  final ConvertStatus status;
  final DateTime createdAt;

  /// 記事の公開日時（抽出できなければ null）。ローカルタイムに変換済み。
  final DateTime? publishedAt;

  /// 失敗理由（status==failed のとき。クレジット不足/変換エラー等）。
  final String? error;

  /// 言語コード -> トラック。MVP では {'ja': ..., 'en': ...}
  final Map<String, LocalizedTrack> tracks;

  const Article({
    required this.id,
    required this.sourceUrl,
    required this.title,
    required this.sourceLang,
    required this.status,
    required this.createdAt,
    required this.tracks,
    this.publishedAt,
    this.error,
  });

  LocalizedTrack? track(String lang) => tracks[lang];

  /// 一覧/詳細表示用の公開日時ラベル（例: 2026/06/15 10:30）。無ければ null。
  String? get publishedLabel {
    final d = publishedAt;
    if (d == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  factory Article.fromJson(Map<String, dynamic> json) => Article(
        id: json['id'] as String,
        sourceUrl: json['source_url'] as String,
        title: json['title'] as String,
        sourceLang: json['source_lang'] as String,
        status: ConvertStatus.values.byName(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        publishedAt: json['published_at'] == null
            ? null
            : DateTime.parse(json['published_at'] as String).toLocal(),
        error: json['error'] as String?,
        tracks: {
          for (final t in (json['tracks'] as List? ?? []))
            (t['lang'] as String):
                LocalizedTrack.fromJson(t as Map<String, dynamic>)
        },
      );
}
