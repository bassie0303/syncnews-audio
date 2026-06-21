import 'package:flutter/material.dart';
import '../../models/article.dart';

/// プレイリスト / ストック画面（PRD 3-2）。
/// コンバート済み記事の一覧。URLペースト or 共有メニュー経由で追加する。
class PlaylistScreen extends StatelessWidget {
  final List<Article> articles;
  final bool loading;
  final Future<void> Function(String url) onAddUrl;
  final Future<void> Function(Article article) onOpen;
  final Future<void> Function(Article article) onDelete;

  /// ElevenLabs の残クレジット（文字数）取得。null なら表示しない。
  final Future<int?> Function()? fetchRemaining;

  /// プルリフレッシュで一覧を取り直す。null ならリフレッシュ無効。
  final Future<void> Function()? onRefresh;

  /// ログアウト。null なら表示しない。
  final Future<void> Function()? onLogout;

  const PlaylistScreen({
    super.key,
    required this.articles,
    required this.onAddUrl,
    required this.onOpen,
    required this.onDelete,
    this.fetchRemaining,
    this.onRefresh,
    this.onLogout,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncNews Audio'),
        actions: [
          if (onLogout != null)
            IconButton(
              tooltip: 'ログアウト',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('ログアウトしますか？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('キャンセル')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('ログアウト')),
                    ],
                  ),
                );
                if (ok == true) await onLogout!();
              },
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_link),
        label: const Text('記事URLを追加'),
        onPressed: () => _showAddDialog(context),
      ),
      body: loading && articles.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              // onRefresh が無ければ何もしない Future を返す（プル無効相当）。
              onRefresh: onRefresh ?? () async {},
              child: articles.isEmpty
                  // 空でもプルできるよう、必ずスクロール可能にする。
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 160),
                        Center(child: Text('記事URLを追加してコンバートを始めましょう')),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      // 下に余白を確保し、最後の記事の再生/⋮ボタンが
                      // 追加FAB(右下)に隠れて押しにくくなるのを防ぐ。
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      itemCount: articles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) => _ArticleCard(
                        article: articles[i],
                        onOpen: onOpen,
                        onDelete: onDelete,
                      ),
                    ),
            ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('記事URLを貼り付け'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fetchRemaining != null) _RemainingCredits(fetch: fetchRemaining!),
            TextField(
              controller: controller,
              decoration: const InputDecoration(hintText: 'https://...'),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('コンバート')),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) await onAddUrl(url);
  }
}

class _ArticleCard extends StatelessWidget {
  final Article article;
  final Future<void> Function(Article article) onOpen;
  final Future<void> Function(Article article) onDelete;
  const _ArticleCard({
    required this.article,
    required this.onOpen,
    required this.onDelete,
  });

  bool get _inProgress =>
      article.status == ConvertStatus.pending ||
      article.status == ConvertStatus.processing;

  Future<void> _confirmDelete(BuildContext context) async {
    // 進行中＝キャンセル（確認なしで即実行）、それ以外＝削除（確認あり）
    if (_inProgress) {
      await onDelete(article);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除しますか？'),
        content: Text(article.title, maxLines: 3),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除')),
        ],
      ),
    );
    if (ok == true) await onDelete(article);
  }

  @override
  Widget build(BuildContext context) {
    final ready = article.status == ConvertStatus.ready;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        title: Text(article.title,
            maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusChip(status: article.status),
                  if (article.publishedLabel != null) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.schedule,
                              size: 13, color: Colors.grey.shade500),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              article.publishedLabel!,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              // 失敗時は理由（クレジット不足/変換エラー等）を赤字で表示。
              if (article.status == ConvertStatus.failed &&
                  article.error != null) ...[
                const SizedBox(height: 6),
                Text(
                  article.error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ready)
              IconButton(
                icon: const Icon(Icons.play_circle_fill, size: 36),
                onPressed: () => onOpen(article),
              ),
            PopupMenuButton<String>(
              onSelected: (_) => _confirmDelete(context),
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Text(_inProgress ? 'コンバートをキャンセル' : '削除'),
                ),
              ],
            ),
          ],
        ),
        onTap: ready ? () => onOpen(article) : null,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final ConvertStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ConvertStatus.pending => ('受付済み・待機中', Colors.grey),
      ConvertStatus.processing => ('コンバート中…', Colors.orange),
      ConvertStatus.ready => ('準備完了', Colors.green),
      ConvertStatus.failed => ('失敗', Colors.red),
    };
    // 処理中（待機中/コンバート中）は小さなスピナーを添えて進行中を明示する。
    final inProgress =
        status == ConvertStatus.pending || status == ConvertStatus.processing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inProgress) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 6),
          ],
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

/// 追加ダイアログ上部に出す ElevenLabs 残クレジット表示。
/// 取得中はスピナー、取得失敗時は何も出さない（登録の妨げにしない）。
class _RemainingCredits extends StatelessWidget {
  final Future<int?> Function() fetch;
  const _RemainingCredits({required this.fetch});

  static String _fmt(int n) => n.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FutureBuilder<int?>(
        future: fetch(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('音声クレジット残量を確認中…',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            );
          }
          final remaining = snap.data;
          if (remaining == null) return const SizedBox.shrink();
          final low = remaining < 5000; // 残りわずかは警告色に
          final color = low ? Colors.orange.shade800 : Colors.grey.shade600;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(low ? Icons.warning_amber : Icons.bolt, size: 14, color: color),
              const SizedBox(width: 4),
              Text('音声クレジット残り ${_fmt(remaining)} 字',
                  style: TextStyle(fontSize: 12, color: color)),
            ],
          );
        },
      ),
    );
  }
}
