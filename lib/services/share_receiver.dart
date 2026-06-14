import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// 受け取ったURLを処理するコールバック。
typedef UrlHandler = void Function(String url);

/// ブラウザの共有メニュー（OS共有シート）から渡されたURLを受け取る（PRD 3-1）。
///
/// 2系統を扱う:
///   - コールドスタート: 共有シートからアプリが起動された場合（`getInitialMedia`）
///   - ホット: アプリ起動中に共有された場合（`getMediaStream`）
///
/// ※ Web では OS 共有Intent が無いため何もしない（`kIsWeb` ガード）。
///   実機検証は Android/iOS のネイティブ設定（docs/native_setup.md）が前提。
class ShareReceiver {
  StreamSubscription<List<SharedMediaFile>>? _sub;

  // 共有テキスト中から最初の http(s) URL を拾う。
  final RegExp _urlRe = RegExp(r'https?://[^\s]+');

  /// 受け取りを開始する。URL を検出するたび [onUrl] を呼ぶ。
  Future<void> start(UrlHandler onUrl) async {
    if (kIsWeb) return; // Web は共有Intent非対応

    // 起動中に共有された場合
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) {
        final url = _extract(files);
        if (url != null) onUrl(url);
      },
      onError: (Object e) => debugPrint('ShareReceiver stream error: $e'),
    );

    // 共有シートからアプリが起動された場合（最初の1件）
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    final url = _extract(initial);
    if (url != null) onUrl(url);

    // 同じ共有を再処理しないようにクリアする
    ReceiveSharingIntent.instance.reset();
  }

  String? _extract(List<SharedMediaFile> files) {
    for (final f in files) {
      final match = _urlRe.firstMatch(f.path);
      if (match != null) return match.group(0);
    }
    return null;
  }

  void dispose() => _sub?.cancel();
}
