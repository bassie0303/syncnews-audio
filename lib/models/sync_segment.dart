/// 音声とテキストを結びつける最小単位（文 or 単語）。
///
/// バックエンドの TTS パイプラインが返す「タイムスタンプ付きセグメント」を表す。
/// start/end はトラック先頭からの経過時間。これが
/// 「音声→テキストのハイライト」「テキスト→音声のシーク」両方向の同期の基盤になる。
class SyncSegment {
  final int index;
  final String text;
  final Duration start;
  final Duration end;

  const SyncSegment({
    required this.index,
    required this.text,
    required this.start,
    required this.end,
  });

  bool contains(Duration position) => position >= start && position < end;

  factory SyncSegment.fromJson(Map<String, dynamic> json) => SyncSegment(
        index: json['index'] as int,
        text: json['text'] as String,
        // バックエンドはミリ秒(int)で格納する
        start: Duration(milliseconds: json['start_ms'] as int),
        end: Duration(milliseconds: json['end_ms'] as int),
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'text': text,
        'start_ms': start.inMilliseconds,
        'end_ms': end.inMilliseconds,
      };
}

/// 1言語分のレンダリング素材（テキスト全文 + 音声URL + 同期セグメント）。
class LocalizedTrack {
  final String lang; // 'ja' | 'en'
  final String audioUrl;
  final List<SyncSegment> segments;

  const LocalizedTrack({
    required this.lang,
    required this.audioUrl,
    required this.segments,
  });

  factory LocalizedTrack.fromJson(Map<String, dynamic> json) => LocalizedTrack(
        lang: json['lang'] as String,
        audioUrl: json['audio_url'] as String,
        segments: (json['segments'] as List)
            .map((e) => SyncSegment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
