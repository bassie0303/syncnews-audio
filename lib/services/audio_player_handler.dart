import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// バックグラウンド音声再生の中核（PRD 3-4 / 技術課題①）。
///
/// audio_service が OS のメディアセッションを保持することで、
///   - 画面ロック中も再生継続
///   - ロック画面 / コントロールセンターの再生・停止・スキップ
///   - イヤホン物理ボタン / AVRCP / OS標準メディアコマンド
/// が「追加実装なし」で `skipToNext` / `play` 等のコールバックに流れ込む。
///
/// just_audio が実際の再生・速度変更・seek・positionStream を担当する。
class SyncAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  /// 同期プレーヤーが購読する再生位置（ミリ秒精度）。
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  AudioPlayer get player => _player;

  SyncAudioHandler() {
    // just_audio の状態を audio_service(=OSセッション) の PlaybackState へ橋渡し。
    _player.playbackEventStream.map(_toPlaybackState).pipe(playbackState);
  }

  /// 指定言語トラックの音声をロードして再生準備。
  Future<void> loadTrack({
    required String url,
    required String articleId,
    required String title,
    required String lang,
    Duration initialPosition = Duration.zero,
  }) async {
    mediaItem.add(MediaItem(
      id: '$articleId#$lang',
      title: title,
      artist: lang == 'ja' ? '日本語' : 'English',
      // duration はロード後に確定するので後段で更新される
    ));
    await _player.setUrl(url, initialPosition: initialPosition);
    final dur = _player.duration;
    if (dur != null) {
      mediaItem.add(mediaItem.value!.copyWith(duration: dur));
    }
  }

  // --- OS / イヤホン / ロック画面から飛んでくるコマンド群 ---
  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  /// 速度変更 0.8〜2.0倍 (PRD 3-4)
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// 「30秒巻き戻し」: ボタン & SeekHandler 経由の rewind 両対応
  @override
  Future<void> rewind() => _seekBy(const Duration(seconds: -30));

  /// 「15秒早送り」(PRD 3-4)
  @override
  Future<void> fastForward() => _seekBy(const Duration(seconds: 15));

  /// イヤホンのダブルタップ（次トラック）→ 15秒送りへ割り当て。
  /// 多くのイヤホン/OSは double-tap を skipToNext として送出するため、
  /// 隙間時間の「少し進める」操作を物理ジェスチャーだけで完結させる。
  @override
  Future<void> skipToNext() => fastForward();

  /// イヤホンのトリプルタップ（前トラック）→ 30秒戻しへ割り当て。
  @override
  Future<void> skipToPrevious() => rewind();

  Future<void> _seekBy(Duration delta) async {
    final target = _player.position + delta;
    final dur = _player.duration ?? Duration.zero;
    await _player.seek(target < Duration.zero
        ? Duration.zero
        : (target > dur ? dur : target));
  }

  PlaybackState _toPlaybackState(PlaybackEvent event) {
    final playing = _player.playing;
    return PlaybackState(
      controls: [
        MediaControl.rewind, // 30秒戻し
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward, // 15秒送り
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.rewind,
        MediaAction.fastForward,
        MediaAction.setSpeed,
        // イヤホンのダブル/トリプルタップを skipToNext/Previous として受け取る
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    );
  }
}

/// main() で一度だけ呼び出してハンドラを起動する。
Future<SyncAudioHandler> initAudioService() {
  return AudioService.init(
    builder: () => SyncAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.syncnews.audio.channel',
      androidNotificationChannelName: 'SyncNews Audio',
      androidNotificationOngoing: true,
      // 30秒戻し / 15秒送りの刻みをOS通知のスワイプにも反映
      rewindInterval: Duration(seconds: 30),
      fastForwardInterval: Duration(seconds: 15),
    ),
  );
}
