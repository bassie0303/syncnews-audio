import 'package:flutter/material.dart';

import '../../models/article.dart';
import '../../services/audio_player_handler.dart';
import '../../services/share_receiver.dart';
import '../playlist/playlist_screen.dart';

/// アプリの通常ホーム。プレイリストを表示しつつ、ブラウザの共有メニューから
/// 渡されたURLを受け取って変換フローに流す（PRD 3-1 の方法2）。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.articles,
    required this.audio,
    required this.onAddUrl,
  });

  final List<Article> articles;
  final SyncAudioHandler audio;
  final Future<void> Function(String url) onAddUrl;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final ShareReceiver _share = ShareReceiver();

  @override
  void initState() {
    super.initState();
    // 共有シートから来たURLを受け取り → 変換開始＋フィードバック表示
    _share.start(_handleSharedUrl);
  }

  Future<void> _handleSharedUrl(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('共有を受け取りました：変換を開始します\n$url')),
    );
    await widget.onAddUrl(url);
  }

  @override
  void dispose() {
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlaylistScreen(
      articles: widget.articles,
      audio: widget.audio,
      onAddUrl: widget.onAddUrl,
    );
  }
}
