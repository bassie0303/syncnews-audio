import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
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

  /// 割り込み（電話・他アプリ）で一時停止したか。終了後の自動再開判定に使う。
  bool _interruptedWhilePlaying = false;

  /// 記事全体のリピート再生フラグ。末尾到達時に先頭へ戻して再生し直す。
  bool _repeat = false;

  /// 同期プレーヤーが購読する再生位置（ミリ秒精度）。
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  AudioPlayer get player => _player;

  SyncAudioHandler() {
    // just_audio の状態を audio_service(=OSセッション) の PlaybackState へ橋渡し。
    _player.playbackEventStream.map(_toPlaybackState).pipe(playbackState);

    // リピート: 記事末尾に達したら、ONなら先頭へ戻して再生し直す。
    // LoopMode.one は setUrl 単一音源だと環境により効かないため、完了イベントで
    // 明示的にループさせる（確実・予測可能）。
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _repeat) {
        _player.seek(Duration.zero);
        _player.play();
      }
    });
  }

  /// オーディオフォーカスと割り込み制御を設定する（main から init 時に1回）。
  ///
  /// これを呼ばないと、フォーカス未取得で「音が出ない／途中で止まる」、
  /// ダッキング（通知音などでの一時減音）から戻らず「音が極端に小さいまま」、
  /// 割り込み後に再生が再開しない、といった不具合が起きる。
  Future<void> configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // 割り込み（電話・他アプリの音声・通知音など）への対応。
    //
    // 重要: ダッキング（一時減音）は Android が OS レベルで自動的に行い、
    // 解除も OS が行う。アプリが自前で setVolume を下げると、復帰イベントを
    // 取りこぼした際に「小音量のまま固定」される事故になる（数分で音量が下がる症状）。
    // そのため duck では音量を下げず、復帰方向（1.0 へ戻す）だけ持つ。
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            // OS のダッキングに任せる（自前では何もしない）。
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            // 再生中だったら覚えておき、割り込み終了後に自動再開する。
            _interruptedWhilePlaying = _player.playing;
            if (_interruptedWhilePlaying) _player.pause();
        }
      } else {
        // 割り込み終了。いずれの種類でも音量は必ず全開へ戻す（減音残りの保険）。
        _player.setVolume(1.0);
        if (_interruptedWhilePlaying) {
          _interruptedWhilePlaying = false;
          _player.play();
        }
      }
    });

    // ヘッドホンが抜かれたら一時停止（スピーカーから突然鳴るのを防ぐ）。
    session.becomingNoisyEventStream.listen((_) => _player.pause());
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
    // 念のため音量を全開に戻す（前トラックでダッキングが残ると、特に言語切替後の
    // 英語音声が小さいままになる事故を防ぐ防御的リセット）。
    await _player.setVolume(1.0);
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

  /// 記事全体のリピート再生のON/OFF。実際のループは完了イベント監視で行う
  /// （constructor の processingStateStream 参照）。LoopMode は使わない
  /// （単一音源だと完了イベントが来ず、逆にループ検知できなくなるため OFF のまま）。
  Future<void> setRepeat(bool on) async {
    _repeat = on;
  }

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
Future<SyncAudioHandler> initAudioService() async {
  final handler = await AudioService.init(
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
  // フォーカス・割り込み制御を有効化（再生開始前に確定させる）。
  await handler.configureSession();
  return handler;
}
