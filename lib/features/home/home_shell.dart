import 'package:flutter/material.dart';

import '../../models/article.dart';
import '../../services/article_repository.dart';
import '../../services/audio_player_handler.dart';
import '../../services/convert_api.dart';
import '../../services/share_receiver.dart';
import '../player/player_screen.dart';
import '../playlist/playlist_screen.dart';

/// アプリの通常ホーム。
///  - Supabase の記事一覧をリアルタイム購読して表示
///  - URLペースト/共有メニューで受け取ったURL → 記事行作成 + 変換ワーカー起動
///  - 準備完了の記事タップ → tracks/segments を取得してプレーヤーへ
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.audio,
    required this.convertApiBase,
  });

  final SyncAudioHandler audio;
  final String convertApiBase;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final ArticleRepository _repo = ArticleRepository();
  final ShareReceiver _share = ShareReceiver();
  late final ConvertApi _convert = ConvertApi(widget.convertApiBase);

  @override
  void initState() {
    super.initState();
    _share.start(_addUrl); // 共有メニューからのURLも同じ導線へ
  }

  /// URL受け取り → articles行作成 → 変換ワーカー起動。
  Future<void> _addUrl(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. 行を作成すると一覧に「待機中」が即時出現（Realtime）。
      final id = await _repo.create(url);
      // 2. 受け付けたことを即フィードバック（変換完了は待たない）。
      messenger.showSnackBar(
        const SnackBar(
          content: Text('受け付けました。一覧で変換の進捗（コンバート中…→準備完了）が表示されます'),
          duration: Duration(seconds: 4),
        ),
      );
      // 3. 変換ワーカーを起動。バックエンドは即 accepted を返すのでここはすぐ戻る。
      await _convert.start(articleId: id, sourceUrl: url);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('追加に失敗しました: $e')));
    }
  }

  /// 一覧の記事（メタのみ）→ 再生用にフル取得してプレーヤーへ遷移。
  Future<void> _open(Article article) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final full = await _repo.fetchFull(article.id);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(article: full, audio: widget.audio),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('記事の取得に失敗しました: $e')));
    }
  }

  @override
  void dispose() {
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Article>>(
      stream: _repo.watch(),
      builder: (context, snapshot) {
        return PlaylistScreen(
          articles: snapshot.data ?? const <Article>[],
          loading: snapshot.connectionState == ConnectionState.waiting,
          onAddUrl: _addUrl,
          onOpen: _open,
        );
      },
    );
  }
}
