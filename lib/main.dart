import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/audio_player_handler.dart';
import 'services/permissions.dart';
import 'theme/app_theme.dart';
import 'features/auth/auth_gate.dart';
import 'features/home/home_shell.dart';
import 'dev/mock_entry.dart';

/// アプリ全体で共有する単一のオーディオハンドラ。
late final SyncAudioHandler audioHandler;

/// 開発検証モード（`--dart-define=DEV_MOCK=true`）。
/// Supabase / バックエンド無しでモック記事をプレーヤーに直行させる。
const bool kDevMock = bool.fromEnvironment('DEV_MOCK');

const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// 変換ワーカー（Railway）のベースURL。`--dart-define=CONVERT_API_BASE=...`
const String _convertApiBase = String.fromEnvironment('CONVERT_API_BASE');

/// Supabase が設定済みか（本番ホーム動作の前提）。
const bool _supabaseReady = _supabaseUrl != '' && _supabaseAnonKey != '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Supabase 初期化（記事メタ・同期タイムスタンプ・音声URL・認証）。
  // キー未指定（DEV_MOCK 等）では空文字で initialize すると落ちるためスキップする。
  if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  }

  // バックグラウンド音声サービス起動（ロック画面/イヤホン連携の基盤）
  audioHandler = await initAudioService();

  runApp(const ProviderScope(child: SyncNewsApp()));

  // 初回フレーム後（Activity 復帰後）に通知許可を要求する。
  // 再生でフォアグラウンドサービスを起動する前に許可を得ておくことで、
  // startForeground 未呼び出しによる ANR を防ぐ。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ensureNotificationPermission();
  });
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
      home: kDevMock
          // 開発検証: モック記事を同期プレーヤーに直行（Supabase不要）
          ? MockEntry(audio: audioHandler)
          : _supabaseReady
              // 認証ゲート: 未ログインはログイン画面、ログイン済みはホーム。
              ? AuthGate(
                  child: HomeShell(
                    audio: audioHandler,
                    convertApiBase: _convertApiBase,
                  ),
                )
              : const _SetupNeededScreen(),
    );
  }
}

/// Supabase 未設定で起動された場合の案内（本番ホームは Supabase 前提）。
class _SetupNeededScreen extends StatelessWidget {
  const _SetupNeededScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SyncNews Audio')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Supabase が未設定です。\n'
            '--dart-define=SUPABASE_URL / SUPABASE_ANON_KEY / CONVERT_API_BASE '
            'を指定して起動してください。\n'
            '（動作確認だけなら --dart-define=DEV_MOCK=true）',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
