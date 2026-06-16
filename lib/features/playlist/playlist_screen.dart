import 'package:flutter/material.dart';
import '../../models/article.dart';

/// プレイリスト / ストック画面（PRD 3-2）。
/// コンバート済み記事の一覧。URLペースト or 共有メニュー経由で追加する。
class PlaylistScreen extends StatelessWidget {
  final List<Article> articles;
  final bool loading;
  final Future<void> Function(String url) onAddUrl;
  final Future<void> Function(Article article) onOpen;

  const PlaylistScreen({
    super.key,
    required this.articles,
    required this.onAddUrl,
    required this.onOpen,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SyncNews Audio')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_link),
        label: const Text('記事URLを追加'),
        onPressed: () => _showAddDialog(context),
      ),
      body: loading && articles.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : articles.isEmpty
              ? const Center(child: Text('記事URLを追加してコンバートを始めましょう'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: articles.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) =>
                      _ArticleCard(article: articles[i], onOpen: onOpen),
                ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('記事URLを貼り付け'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'https://...'),
          autofocus: true,
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
  const _ArticleCard({required this.article, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final ready = article.status == ConvertStatus.ready;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(article.title,
            maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _StatusChip(status: article.status),
        ),
        trailing: ready ? const Icon(Icons.play_circle_fill, size: 36) : null,
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
