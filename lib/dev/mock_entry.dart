import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/article.dart';
import '../services/audio_player_handler.dart';
import '../features/player/player_screen.dart';

/// 開発検証用エントリ。Supabase / バックエンド無しで、モック記事を
/// `PlayerScreen` に直接流し込み、同期プレーヤー・バックグラウンド音声・
/// イヤホン操作を実機で確認するためのもの。
///
/// 起動: `flutter run --dart-define=DEV_MOCK=true`
///
/// ※ 音声はサンプルmp3のプレースホルダで、タイムスタンプと内容は一致しない。
///   UI挙動・背景再生・ロック画面/イヤホン操作の確認用。
class MockEntry extends StatelessWidget {
  const MockEntry({super.key, required this.audio});

  final SyncAudioHandler audio;

  Future<Article> _load() async {
    final raw = await rootBundle.loadString('assets/mock/sample_article.json');
    return Article.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Article>(
      future: _load(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            body: Center(child: Text('モック読込失敗: ${snap.error}')),
          );
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return PlayerScreen(article: snap.data!, audio: audio);
      },
    );
  }
}
