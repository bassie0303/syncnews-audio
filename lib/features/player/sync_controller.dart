import 'package:flutter/foundation.dart';
import '../../models/sync_segment.dart';
import '../../services/audio_player_handler.dart';

/// テキスト⇄音声のリアルタイム同期エンジン（PRD 3-3 / 技術課題②）。
///
/// 責務:
///   1. 音声→テキスト: positionStream を購読し、現在再生中のセグメントindexを算出
///      → UIはこの ValueListenable を listen してハイライト＆自動スクロール。
///   2. テキスト→音声: タップされたセグメントの start へ player.seek。
///   3. 言語切替時の「迷子防止」: 現在位置を相対(0.0〜1.0)で保持し、
///      別言語トラックへ載せ替えても同じ進捗位置に着地させる。
class SyncController extends ChangeNotifier {
  final SyncAudioHandler audio;

  SyncController(this.audio) {
    _sub = audio.positionStream.listen(_onPosition);
  }

  late final dynamic _sub;
  List<SyncSegment> _segments = const [];

  /// 現在ハイライトすべきセグメントの index（無ければ -1）。
  final ValueNotifier<int> currentIndex = ValueNotifier<int>(-1);

  List<SyncSegment> get segments => _segments;

  /// 同期対象のセグメントを差し替える。
  ///
  /// [keepIndex] が true の場合、現在のハイライト位置（文番号）を維持する。
  /// テキスト言語の切替は ja/en が同じ index 体系なので、位置を保てば
  /// 一時停止中でもハイライトが消えない。
  void setSegments(List<SyncSegment> segments, {bool keepIndex = false}) {
    final prev = currentIndex.value;
    _segments = segments;
    currentIndex.value =
        (keepIndex && prev >= 0 && prev < segments.length) ? prev : -1;
  }

  /// 音声位置 → セグメント探索。
  /// セグメントは時刻昇順なので、現在indexの近傍だけ見れば O(1) 償却で済む
  /// （毎フレーム全件線形探索しないことが同期のなめらかさの肝）。
  void _onPosition(Duration pos) {
    if (_segments.isEmpty) return;
    final cur = currentIndex.value;

    // 1) 現在indexがまだ有効ならそのまま
    if (cur >= 0 && cur < _segments.length && _segments[cur].contains(pos)) {
      return;
    }
    // 2) 隣（連続再生で最頻）を先に確認
    if (cur + 1 < _segments.length && _segments[cur + 1].contains(pos)) {
      currentIndex.value = cur + 1;
      return;
    }
    // 3) それ以外（seek/巻き戻し直後）は二分探索で確定
    currentIndex.value = _binarySearch(pos);
  }

  int _binarySearch(Duration pos) {
    int lo = 0, hi = _segments.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final s = _segments[mid];
      if (pos < s.start) {
        hi = mid - 1;
      } else if (pos >= s.end) {
        lo = mid + 1;
      } else {
        found = mid;
        break;
      }
    }
    return found;
  }

  /// テキストタップ → 音声をその文の先頭へジャンプ（テキスト→音声）。
  Future<void> seekToSegment(int index) async {
    if (index < 0 || index >= _segments.length) return;
    await audio.seek(_segments[index].start);
    currentIndex.value = index;
  }

  /// 言語切替の「現在地の引き継ぎ」。
  /// 旧トラックでの相対位置(0.0〜1.0)を、新トラックの同じ割合の位置へマップする。
  /// 文単位で揃っている場合は index ベースの方が正確なので index も併用する。
  Duration mapPositionForLanguageSwitch({
    required Duration oldPosition,
    required List<SyncSegment> newSegments,
  }) {
    final curIdx = currentIndex.value;
    // 文数が一致（翻訳が1:1対応）→ 同じ文の先頭へ
    if (curIdx >= 0 &&
        _segments.length == newSegments.length &&
        curIdx < newSegments.length) {
      return newSegments[curIdx].start;
    }
    // それ以外 → 相対進捗で着地（迷子防止のフォールバック）
    final oldTotal = _segments.isEmpty ? Duration.zero : _segments.last.end;
    final newTotal =
        newSegments.isEmpty ? Duration.zero : newSegments.last.end;
    if (oldTotal == Duration.zero) return Duration.zero;
    final ratio = oldPosition.inMilliseconds / oldTotal.inMilliseconds;
    return Duration(milliseconds: (newTotal.inMilliseconds * ratio).round());
  }

  @override
  void dispose() {
    _sub.cancel();
    currentIndex.dispose();
    super.dispose();
  }
}
