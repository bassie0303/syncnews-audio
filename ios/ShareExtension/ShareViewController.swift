import receive_sharing_intent

/// 共有シート（Safari/Chrome の「共有」）から渡された text/URL を本体アプリへ渡す拡張。
///
/// receive_sharing_intent が提供する `RSIShareViewController` を継承するだけでよい。
/// 受け取った内容は App Group 経由で本体アプリに渡り、`getInitialMedia` /
/// `getMediaStream` で受信される（lib/services/share_receiver.dart）。
///
/// ※ このファイルは雛形。Xcode で「Share Extension」ターゲットを追加し、
///   生成された ShareViewController をこの内容に置き換えること（docs/native_setup.md 参照）。
class ShareViewController: RSIShareViewController {
    /// 共有直後に本体アプリへ自動遷移する（既定 true）。
    override func shouldAutoRedirect() -> Bool {
        return true
    }
}
