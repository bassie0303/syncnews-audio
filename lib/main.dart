import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/audio_player_handler.dart';
import 'theme/app_theme.dart';
import 'features/playlist/playlist_screen.dart';
import 'models/article.dart';

/// アプリ全体で共有する単一のオーディオハンドラ。
late final SyncAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Supabase 初期化（記事メタ・同期タイムスタンプ・音声URL・認証）
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );

  // バックグラウンド音声サービス起動（ロック画面/イヤホン連携の基盤）
  audioHandler = await initAudioService();

  runApp(const ProviderScope(child: SyncNewsApp()));
}

class SyncNewsApp extends StatelessWidget {
  const SyncNewsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncNews Audio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system, // ライト/ダーク自動追従
      home: PlaylistScreen(
        articles: const <Article>[], // TODO: Supabase からストリーム購読
        audio: audioHandler,
        onAddUrl: (url) async {
          // TODO: Railway の変換ワーカー `POST {CONVERT_API}/api/convert`
          //       (body: {article_id, source_url}) を呼び出してコンバート開始。
          //       article 行は事前に status=pending で Supabase に作成しておく。
        },
      ),
    );
  }
}
