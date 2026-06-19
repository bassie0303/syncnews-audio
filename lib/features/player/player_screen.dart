import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import '../../models/article.dart';
import '../../models/sync_segment.dart';
import '../../services/audio_player_handler.dart';
import '../../theme/app_theme.dart';
import 'sync_controller.dart';

/// プレーヤーの言語選好。
/// - `textLang`/`audioLang`: 最後に使った「表示×音声」。新しく開く記事の既定にする（引き継ぎ）。
/// - `perArticle`: 記事ごとに最後に選んだ組。同じ記事を開き直したらそれを優先復元する。
/// アプリ起動中のみ保持（永続化は将来検討）。
class PlaybackPrefs {
  static String textLang = 'ja';
  static String audioLang = 'ja';
  static final Map<String, (String, String)> perArticle = {};

  /// 記事を開くときの初期 (textLang, audioLang)。記事個別の記録があればそれを、
  /// なければ直近に使った選好を返す。
  static (String, String) initialFor(String articleId) =>
      perArticle[articleId] ?? (textLang, audioLang);
}

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

  late String _textLang; // 表示テキストの言語（記事個別の記録 or 直近選好で初期化）
  late String _audioLang; // 再生音声の言語（同上）
  double _speed = 1.0;
  bool _repeat = false; // 記事全体のリピート再生

  Timer? _sleepTimer; // スリープタイマー（固定分。nullで無効）
  Duration? _sleepRemaining; // 残り時間（表示用）
  bool _sleepAtEnd = false; // 「この記事の最後まで」予約中か
  StreamSubscription<ProcessingState>? _stateSub;

  /// 表示×音声の4プリセット（PRD 3-1 / バックログ「1タップ切替」）。
  /// (textLang, audioLang) の組。
  static const List<(String, String)> _presets = [
    ('ja', 'ja'), // 日本語表示 × 日本語音声
    ('en', 'en'), // 英語表示 × 英語音声
    ('ja', 'en'), // 日本語表示 × 英語音声
    ('en', 'ja'), // 英語表示 × 日本語音声
  ];

  @override
  void initState() {
    super.initState();
    // 記事ごとの形式選択を復元（無ければ直近の選好を引き継ぐ）。
    final (t, a) = PlaybackPrefs.initialFor(widget.article.id);
    _textLang = t;
    _audioLang = a;
    _loadAudio(_audioLang, initial: true);
    _sync.setSegments(_displaySegments);
    // 音声インデックス→テキストの自動スクロール
    _sync.currentIndex.addListener(() {
      _scroll.ensureVisible(_sync.currentIndex.value);
    });
    // 「この記事の最後まで」予約が末尾で発火したらUIを解除して通知する
    // （実際の停止はハンドラがリピートより優先して行う）。
    _stateSub = widget.audio.player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _sleepAtEnd && mounted) {
        setState(() => _sleepAtEnd = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('スリープタイマーで再生を停止しました')),
        );
      }
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
    await widget.audio.setRepeat(_repeat);
    if (!initial) widget.audio.play();
  }

  /// プリセット適用: 表示・音声をまとめて切り替える（1タップ）。
  /// 既存の個別切替メソッドに委譲するので、差分だけが反映される
  /// （音声が同じならリロードしない／現在地マッピングもそのまま効く）。
  Future<void> _applyPreset(String textLang, String audioLang) async {
    _switchTextLang(textLang);
    await _switchAudioLang(audioLang);
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
    PlaybackPrefs.audioLang = lang; // 次の記事へ引き継ぐ
    _savePerArticle(); // この記事個別にも記録
    final track = widget.article.track(lang)!;
    await widget.audio.loadTrack(
      url: track.audioUrl,
      articleId: widget.article.id,
      title: widget.article.title,
      lang: lang,
      initialPosition: mapped,
    );
    await widget.audio.setSpeed(_speed);
    await widget.audio.setRepeat(_repeat);
    widget.audio.play();
  }

  void _switchTextLang(String lang) {
    if (lang == _textLang) return;
    setState(() => _textLang = lang);
    PlaybackPrefs.textLang = lang; // 次の記事へ引き継ぐ
    _savePerArticle(); // この記事個別にも記録
    // テキストのセグメントを差し替えるが、ja/en は同じ index 体系なので
    // 現在のハイライト位置は維持する（一時停止中もハイライトが消えない）。
    _sync.setSegments(_displaySegments, keepIndex: true);
  }

  /// いまの表示/音声の組をこの記事の選択として記録する。
  void _savePerArticle() {
    PlaybackPrefs.perArticle[widget.article.id] = (_textLang, _audioLang);
  }

  /// 再生位置を記事の先頭へ戻す（同期ハイライトも追従する）。
  void _restart() {
    widget.audio.seek(Duration.zero);
  }

  /// スリープタイマー設定。minutes: 0=オフ / -1=この記事の最後まで / それ以外=分。
  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    widget.audio.setStopAtEnd(false); // いったん「最後まで」予約を解除
    final messenger = ScaffoldMessenger.of(context);

    if (minutes == 0) {
      setState(() {
        _sleepTimer = null;
        _sleepRemaining = null;
        _sleepAtEnd = false;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('スリープタイマーをオフにしました')),
      );
      return;
    }

    if (minutes == -1) {
      // 「この記事の最後まで」は完了イベントで停止（リピートより優先・速度にも左右されない）。
      widget.audio.setStopAtEnd(true);
      setState(() {
        _sleepTimer = null;
        _sleepRemaining = null;
        _sleepAtEnd = true;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('スリープタイマー: この記事の最後で停止')),
      );
      return;
    }

    // 固定分は壁時計タイマーで停止（リピート中でも確実に止まる）。
    setState(() {
      _sleepAtEnd = false;
      _sleepRemaining = Duration(minutes: minutes);
    });
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (_sleepRemaining ?? Duration.zero) - const Duration(seconds: 1);
      if (left <= Duration.zero) {
        t.cancel();
        widget.audio.pause();
        if (mounted) {
          setState(() {
            _sleepTimer = null;
            _sleepRemaining = null;
          });
          messenger.showSnackBar(
            const SnackBar(content: Text('スリープタイマーで再生を停止しました')),
          );
        }
      } else {
        setState(() => _sleepRemaining = left);
      }
    });
    messenger.showSnackBar(
      SnackBar(content: Text('スリープタイマー: $minutes分後に停止')),
    );
  }

  static String _fmtRemaining(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.article.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (widget.article.publishedLabel != null)
              Text(
                widget.article.publishedLabel!,
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withOpacity(0.75)),
              ),
          ],
        ),
        actions: [_buildSleepAction()],
      ),
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
          // プリセット（表示×音声の4組を1タップ）＋ リピート
          _buildPresetRow(),
          const SizedBox(height: 12),
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
                iconSize: 30,
                tooltip: '最初に戻る',
                icon: const Icon(Icons.skip_previous),
                onPressed: _restart, // 記事の先頭へ
              ),
              IconButton(
                iconSize: 32,
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
                iconSize: 32,
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

  // --- スリープタイマー（AppBar右上）---
  Widget _buildSleepAction() {
    final active = _sleepTimer != null || _sleepAtEnd;
    return PopupMenuButton<int>(
      tooltip: 'スリープタイマー',
      onSelected: _setSleep,
      itemBuilder: (ctx) => const [
        PopupMenuItem(value: 0, child: Text('オフ')),
        PopupMenuItem(value: 15, child: Text('15分後')),
        PopupMenuItem(value: 30, child: Text('30分後')),
        PopupMenuItem(value: 45, child: Text('45分後')),
        PopupMenuItem(value: 60, child: Text('60分後')),
        PopupMenuItem(value: -1, child: Text('この記事の最後まで')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
            if (_sleepRemaining != null) ...[
              const SizedBox(width: 4),
              Text(_fmtRemaining(_sleepRemaining!),
                  style: const TextStyle(fontSize: 12)),
            ] else if (_sleepAtEnd) ...[
              const SizedBox(width: 4),
              const Text('最後', style: TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  // --- プリセット4種（表示×音声）＋ リピート ---
  Widget _buildPresetRow() {
    final primary = Theme.of(context).colorScheme.primary;
    String lbl(String l) => l == 'ja' ? '日' : '英';
    return Row(
      children: [
        // 表示=📄 / 音声=🔊 の凡例つきプリセットチップを横並び（はみ出す端末向けに横スクロール）
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (t, a) in _presets) ...[
                  ChoiceChip(
                    selected: t == _textLang && a == _audioLang,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.subject, size: 14),
                        Text(lbl(t)),
                        const SizedBox(width: 5),
                        const Icon(Icons.volume_up, size: 14),
                        Text(lbl(a)),
                      ],
                    ),
                    onSelected: (_) => _applyPreset(t, a),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        // リピート（記事全体の繰り返し）トグル
        IconButton(
          tooltip: _repeat ? 'リピート: ON' : 'リピート: OFF',
          icon: Icon(_repeat ? Icons.repeat_on : Icons.repeat),
          color: _repeat ? primary : null,
          onPressed: () {
            setState(() => _repeat = !_repeat);
            widget.audio.setRepeat(_repeat);
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _stateSub?.cancel();
    widget.audio.setStopAtEnd(false); // 画面を離れたら「最後まで」予約を残さない
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
