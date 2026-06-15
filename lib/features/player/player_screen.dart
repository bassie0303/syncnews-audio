import 'package:flutter/material.dart';
import '../../models/article.dart';
import '../../models/sync_segment.dart';
import '../../services/audio_player_handler.dart';
import '../../theme/app_theme.dart';
import 'sync_controller.dart';

/// 同期プレーヤー詳細画面（PRD 3-3 / 3-4）。
///
/// - 再生中の文をアンバーでハイライトし、自動スクロールで画面内に保つ
/// - 文タップで音声がその位置へジャンプ
/// - テキスト言語 / 音声言語をそれぞれ独立に1タップ切替（現在地は引き継ぎ）
class PlayerScreen extends StatefulWidget {
  final Article article;
  final SyncAudioHandler audio;

  const PlayerScreen({super.key, required this.article, required this.audio});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final SyncController _sync = SyncController(widget.audio);
  final ItemScrollHelper _scroll = ItemScrollHelper();

  String _textLang = 'ja'; // 表示テキストの言語
  String _audioLang = 'ja'; // 再生音声の言語
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _loadAudio(_audioLang, initial: true);
    _sync.setSegments(_displaySegments);
    // 音声インデックス→テキストの自動スクロール
    _sync.currentIndex.addListener(() {
      _scroll.ensureVisible(_sync.currentIndex.value);
    });
  }

  List<SyncSegment> get _displaySegments =>
      widget.article.track(_textLang)?.segments ?? const [];

  Future<void> _loadAudio(String lang, {bool initial = false}) async {
    final track = widget.article.track(lang);
    if (track == null) return;
    await widget.audio.loadTrack(
      url: track.audioUrl,
      articleId: widget.article.id,
      title: widget.article.title,
      lang: lang,
    );
    await widget.audio.setSpeed(_speed);
    if (!initial) widget.audio.play();
  }

  // --- 言語切替（迷子防止: 現在地を新トラックへマップ）---
  Future<void> _switchAudioLang(String lang) async {
    if (lang == _audioLang) return;
    final oldPos = widget.audio.player.position;
    final newSegments = widget.article.track(lang)?.segments ?? const [];
    final mapped = _sync.mapPositionForLanguageSwitch(
      oldPosition: oldPos,
      newSegments: newSegments,
    );
    setState(() => _audioLang = lang);
    final track = widget.article.track(lang)!;
    await widget.audio.loadTrack(
      url: track.audioUrl,
      articleId: widget.article.id,
      title: widget.article.title,
      lang: lang,
      initialPosition: mapped,
    );
    await widget.audio.setSpeed(_speed);
    widget.audio.play();
  }

  void _switchTextLang(String lang) {
    if (lang == _textLang) return;
    setState(() => _textLang = lang);
    // テキストのセグメントを差し替えるが、ja/en は同じ index 体系なので
    // 現在のハイライト位置は維持する（一時停止中もハイライトが消えない）。
    _sync.setSegments(_displaySegments, keepIndex: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.article.title, maxLines: 1)),
      body: Column(
        children: [
          Expanded(child: _buildSyncedText()),
          _buildControls(),
        ],
      ),
    );
  }

  // --- 同期テキスト本文 ---
  Widget _buildSyncedText() {
    return ValueListenableBuilder<int>(
      valueListenable: _sync.currentIndex,
      builder: (context, active, _) {
        final segments = _displaySegments;
        return ListView.builder(
          controller: _scroll.controller,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          itemCount: segments.length,
          itemBuilder: (context, i) {
            final isActive = i == active;
            return GestureDetector(
              onTap: () => _sync.seekToSegment(i), // テキスト→音声ジャンプ
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                key: _scroll.keyFor(i),
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive ? AppColors.highlightBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  segments[i].text,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.6,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                    color: isActive
                        ? AppColors.highlight
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --- 下部コントロール ---
  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 言語切替スイッチ（テキスト/音声を独立に）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _LangToggle(
                label: 'テキスト',
                value: _textLang,
                onChanged: _switchTextLang,
              ),
              _LangToggle(
                label: '音声',
                value: _audioLang,
                onChanged: _switchAudioLang,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 再生トランスポート
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                iconSize: 34,
                icon: const Icon(Icons.replay_30),
                onPressed: widget.audio.rewind, // 30秒戻し
              ),
              StreamBuilder<bool>(
                stream: widget.audio.player.playingStream,
                builder: (context, snap) {
                  final playing = snap.data ?? false;
                  return IconButton.filled(
                    iconSize: 40,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed:
                        playing ? widget.audio.pause : widget.audio.play,
                  );
                },
              ),
              IconButton(
                iconSize: 34,
                icon: const Icon(Icons.forward_10), // 15秒送り（最寄りアイコン）
                onPressed: widget.audio.fastForward,
              ),
              _SpeedStepper(
                speed: _speed,
                onChanged: (s) {
                  setState(() => _speed = s);
                  widget.audio.setSpeed(s);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sync.dispose();
    super.dispose();
  }
}

/// 日/英の2値トグル
class _LangToggle extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  const _LangToggle(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'ja', label: Text('日')),
            ButtonSegment(value: 'en', label: Text('EN')),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

/// 再生速度ステッパー。− / ＋ で両方向に刻める（0.8〜2.0、両端で停止）。
class _SpeedStepper extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;
  const _SpeedStepper({required this.speed, required this.onChanged});

  static const _steps = [0.8, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0];

  /// 現在速度に最も近いステップの index（浮動小数のズレに強い）。
  int get _index {
    var best = 0;
    for (var i = 1; i < _steps.length; i++) {
      if ((_steps[i] - speed).abs() < (_steps[best] - speed).abs()) best = i;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final i = _index;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '遅く',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: i > 0 ? () => onChanged(_steps[i - 1]) : null,
        ),
        SizedBox(
          width: 46,
          child: Text(
            '${speed}x',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '速く',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: i < _steps.length - 1 ? () => onChanged(_steps[i + 1]) : null,
        ),
      ],
    );
  }
}

/// index 指定でその行を画面内に保つための簡易ヘルパー（自動スクロール）。
/// 本番では scrollable_positioned_list パッケージを推奨。
class ItemScrollHelper {
  final ScrollController controller = ScrollController();
  final Map<int, GlobalKey> _keys = {};

  GlobalKey keyFor(int index) => _keys.putIfAbsent(index, () => GlobalKey());

  void ensureVisible(int index) {
    final key = _keys[index];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300),
          alignment: 0.35,
          curve: Curves.easeInOut);
    }
  }
}
