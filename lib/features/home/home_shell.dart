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

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final ArticleRepository _repo = ArticleRepository();
  final ShareReceiver _share = ShareReceiver();
  late final ConvertApi _convert = ConvertApi(widget.convertApiBase);

  // Realtime 購読ストリーム。バックグラウンド復帰時に作り直して再購読する。
  late Stream<List<Article>> _stream = _repo.watch();
  // 直前に表示できた一覧。復帰中の再購読で一瞬「空」が流れても直前を出し続ける
  // ことで「一覧が空になる」不具合を防ぐ。
  List<Article> _last = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _share.start(_addUrl); // 共有メニューからのURLも同じ導線へ
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 復帰時: Realtime が切れている可能性があるので購読を作り直し、
      // さらに一度だけ取得して即座に最新で埋める（空表示の回避）。
      setState(() => _stream = _repo.watch());
      _refresh();
    }
  }

  /// 一覧を一度だけ取り直して直前データを更新（プルリフレッシュ／復帰時）。
  Future<void> _refresh() async {
    try {
      final list = await _repo.fetchList();
      if (mounted) setState(() => _last = list);
    } catch (_) {
      // 取得失敗時は直前データを維持（無理に空にしない）。
    }
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

  /// 記事の削除（進行中ならコンバートのキャンセルを兼ねる）。
  /// 実体削除は backend(service_role) 経由。一覧からは Realtime で除去される。
  Future<void> _delete(Article article) async {
    final messenger = ScaffoldMessenger.of(context);
    final canceling = article.status == ConvertStatus.pending ||
        article.status == ConvertStatus.processing;
    try {
      await _convert.deleteArticle(article.id);
      messenger.showSnackBar(
        SnackBar(content: Text(canceling ? 'コンバートをキャンセルしました' : '削除しました')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
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
    WidgetsBinding.instance.removeObserver(this);
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Article>>(
      stream: _stream,
      builder: (context, snapshot) {
        // Realtime からデータが来たら直前データを更新。
        if (snapshot.hasData) _last = snapshot.data!;
        // 表示は「最新があればそれ／無ければ直前データ」。再購読中の空表示を避ける。
        final articles = snapshot.data ?? _last;
        // ローディングは「まだ一度も表示データが無い」ときだけ。
        final loading =
            snapshot.connectionState == ConnectionState.waiting && _last.isEmpty;
        return PlaylistScreen(
          articles: articles,
          loading: loading,
          onAddUrl: _addUrl,
          onOpen: _open,
          onDelete: _delete,
          onRefresh: _refresh,
          fetchRemaining: _convert.remainingCredits,
        );
      },
    );
  }
}
