import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/article.dart';
import '../../services/audio_player_handler.dart';
import '../../services/convert_api.dart';
import '../../services/share_receiver.dart';
import '../player/player_screen.dart';
import '../playlist/playlist_screen.dart';

/// 認証済みユーザーのホーム。二スキーマ構成では、第三者著作物（本文/タイトル/音声）は
/// 公開APIに出さず、すべて本人認証付きの**ゲート経由**（ConvertApi）で扱う:
///  - 一覧:   GET /api/articles
///  - 登録:   POST /api/articles
///  - 削除:   DELETE /api/articles/{id}
///  - 再生:   GET /api/playback/{id} で本文＋署名URLを取得してプレーヤーへ
/// 変換中の記事があるあいだだけ数秒ごとに再取得して status を反映する。
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
  final ShareReceiver _share = ShareReceiver();
  late final ConvertApi _convert = ConvertApi(widget.convertApiBase);

  List<Article> _articles = const [];
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _share.start(_addUrl); // 共有メニューからのURLも同じ導線へ
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  bool get _anyPending => _articles.any((a) =>
      a.status == ConvertStatus.pending ||
      a.status == ConvertStatus.processing);

  /// 一覧を取り直す（初回／復帰／プルリフレッシュ／登録・削除後／ポーリング）。
  Future<void> _refresh() async {
    try {
      final list = await _convert.fetchArticles();
      if (!mounted) return;
      setState(() {
        _articles = list;
        _loading = false;
      });
      _syncPolling();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 変換中の記事があるあいだだけ数秒間隔で再取得する（status の自動反映）。
  void _syncPolling() {
    if (_anyPending && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    } else if (!_anyPending && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  /// URL受け取り → 認証付きで登録（バックエンドが所有者付きで作成＋変換開始）。
  Future<void> _addUrl(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _convert.createArticle(url);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('受け付けました。一覧で変換の進捗（コンバート中…→準備完了）が表示されます'),
          duration: Duration(seconds: 4),
        ),
      );
      await _refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('追加に失敗しました: $e')));
    }
  }

  /// 記事の削除（進行中ならコンバートのキャンセルを兼ねる）。本人のみ。
  Future<void> _delete(Article article) async {
    final messenger = ScaffoldMessenger.of(context);
    final canceling = article.status == ConvertStatus.pending ||
        article.status == ConvertStatus.processing;
    try {
      await _convert.deleteArticle(article.id);
      messenger.showSnackBar(
        SnackBar(content: Text(canceling ? 'コンバートをキャンセルしました' : '削除しました')),
      );
      await _refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作に失敗しました: $e')));
    }
  }

  /// 準備完了の記事 → 再生用フル取得（本文＋署名URL）してプレーヤーへ。
  Future<void> _open(Article article) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final full = await _convert.fetchPlayback(article);
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

  Future<void> _logout() async {
    await Supabase.instance.client.auth.signOut();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlaylistScreen(
      articles: _articles,
      loading: _loading,
      onAddUrl: _addUrl,
      onOpen: _open,
      onDelete: _delete,
      onRefresh: _refresh,
      onLogout: _logout,
      fetchRemaining: _convert.remainingCredits,
    );
  }
}
