# ネイティブ設定（バックグラウンド音声 / ロック画面 / イヤホン連携）

`audio_service` + `just_audio` を **OSレベルで有効化**するための iOS / Android 設定。
ここを入れないと「画面ロックで音が止まる」「ロック画面に出ない」「イヤホン操作が効かない」
という Step2 のコア要件（PRD 3-4 / 技術課題①）が満たせない。

> 前提: `flutter create . --org com.syncnews` でネイティブ足場を生成済みであること。
> 既存の `lib/` は上書きされない。

> ⚡ **自動適用**: 下記の手作業（Info.plist / AndroidManifest / MainActivity）は
> `bash scripts/setup_native.sh` で一括適用できる（`flutter create` 込み・冪等）。
> 仕組みを理解したうえで使うこと。以下は手動で行う場合の詳細。

---

## iOS

### 1. `ios/Runner/Info.plist`
バックグラウンドオーディオモードを宣言する。

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

### 2. Xcode の Capability（任意だが推奨）
`Runner` ターゲット → Signing & Capabilities → **+ Background Modes** →
**Audio, AirPlay, and Picture in Picture** にチェック（上記 plist と同義）。

### 3. AVAudioSession
`audio_service` が内部で `audio_session` を使い、再生開始時に
`AVAudioSession` を `playback` カテゴリで activate する。**追加コード不要**。
- 通話・他アプリ割り込み時の中断/再開、Bluetooth ルーティングも自動処理。
- ロック画面のアートワーク／タイトルは `MediaItem`（`loadTrack()` で設定済み）から表示。

### 4. イヤホン操作（iOS）
- シングルタップ（再生/一時停止）→ `play()` / `pause()`
- AirPods 等のダブル/トリプルタップ → OS が `skipToNext` / `skipToPrevious` を送出
  → ハンドラで **15秒送り / 30秒戻し** に割り当て済み（`SyncAudioHandler`）。

---

## Android

### 1. `android/app/src/main/AndroidManifest.xml`
`<manifest>` 直下に権限、`<application>` 内に service と receiver を追加。

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<!-- Android 14 (API 34) 以降は型別の権限が必須 -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<!-- Android 13 (API 33) 以降はメディア通知の表示に必要 -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

<application ...>
  <!-- 既存の <activity android:name=".MainActivity" ...> はそのまま -->

  <service
      android:name="com.ryanheise.audioservice.AudioService"
      android:foregroundServiceType="mediaPlayback"
      android:exported="true">
    <intent-filter>
      <action android:name="android.media.browse.MediaBrowserService"/>
    </intent-filter>
  </service>

  <receiver
      android:name="com.ryanheise.audioservice.MediaButtonReceiver"
      android:exported="true">
    <intent-filter>
      <action android:name="android.intent.action.MEDIA_BUTTON"/>
    </intent-filter>
  </receiver>
</application>
```

### 2. `MainActivity` を `AudioServiceActivity` に差し替え
`android/app/src/main/kotlin/.../MainActivity.kt`:

```kotlin
package com.syncnews.audio   // ← --org に合わせる

import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity()
```

`FlutterActivity` を継承していると音声サービスと UI が別エンジンになり
バックグラウンドで切れる。**必ず `AudioServiceActivity` を継承**する。

### 3. SDK バージョン
`android/app/build.gradle`:
- `minSdkVersion 23`（audio_service 推奨。21でも可だが foregroundServiceType の都合で23+が無難）
- `compileSdkVersion 34` / `targetSdkVersion 34`

### 4. 通知チャンネル
`initAudioService()` の `AudioServiceConfig`（`lib/services/audio_player_handler.dart`）で
`androidNotificationChannelId/Name`・`rewindInterval=30s`・`fastForwardInterval=15s` を設定済み。
Android 13+ では初回再生時に `POST_NOTIFICATIONS` のランタイム許可ダイアログを出すこと。

### 5. イヤホン操作（Android）
有線/Bluetooth の MEDIA_BUTTON は `MediaButtonReceiver` 経由で
`SyncAudioHandler` のコールバックへ流入：
- 再生/一時停止 → `play()` / `pause()`
- 次/前（ダブル/トリプルタップ・AVRCP）→ `skipToNext()` / `skipToPrevious()`
  = **15秒送り / 30秒戻し**

---

## 共有メニュー受け取り（PRD 3-1 方法2 / `receive_sharing_intent`）

ブラウザの「共有」→「SyncNews Audio」でURLを渡す経路。Dart側の受信は
`lib/services/share_receiver.dart`（`HomeShell` が購読）で実装済み。OS側設定が以下。

### Android（`setup_native.sh` で自動適用済み）
`AndroidManifest.xml` の `MainActivity` の `<activity>` に、`text/*` を受け取る
intent-filter を追加済み：

```xml
<intent-filter>
    <action android:name="android.intent.action.SEND"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <data android:mimeType="text/*"/>
</intent-filter>
```

→ これでブラウザの共有シートに「SyncNews Audio」が出る。エミュレータ/実機で確認可。

### iOS（Xcode での手動作業が必須 ※未検証）
iOS は **Share Extension ターゲット**と **App Group** が必要で、`flutter create` では
作られない。雛形は `ios/ShareExtension/`（`ShareViewController.swift` / `Info.plist`）に用意済み。
**フルXcode が要る**ため、ここは手動・未検証。手順:

1. Xcode で `ios/Runner.xcworkspace` を開く → File ▸ New ▸ Target ▸ **Share Extension**
   （Product Name 例: `ShareExtension`、言語 Swift）。
2. 生成された `ShareViewController.swift` / `Info.plist` を `ios/ShareExtension/` の雛形で置換。
   ストーリーボードは使わない（`Info.plist` が `NSExtensionPrincipalClass` 方式）。
3. **App Group** を Runner と ShareExtension の両ターゲットに追加:
   Signing & Capabilities ▸ + App Groups ▸ `group.com.syncnews.syncnewsAudio`。
4. ShareExtension の Deployment Target を Runner と揃える（最低 iOS 13+）。
5. ShareExtension ターゲットに `receive_sharing_intent` を Pod 連携（`pod install` を再実行）。
6. （任意）`Runner/Info.plist` に `AppGroupId` を追加して app group を明示。

> 公式手順は `receive_sharing_intent` の README が版依存で最も正確。上記と差異が出たら README を優先。

---

## 動作確認チェックリスト（実機推奨）

### バックグラウンド音声 / イヤホン
- [ ] 再生中にロック → 音が継続する
- [ ] ロック画面 / コントロールセンターに タイトル・再生・±スキップが出る
- [ ] ロック画面のボタンで再生/一時停止/±スキップが効く
- [ ] イヤホンのシングルタップで再生/一時停止
- [ ] イヤホンのダブルタップで15秒送り、トリプルタップで30秒戻し
- [ ] 電話着信 → 自動で一時停止、終話後に再開（iOS/Android とも）
- [ ] 他アプリで音楽再生 → 本アプリが適切に中断/復帰
- [ ] バックグラウンド中も `positionStream` が流れ、復帰時にハイライトが正しい位置

### 共有メニュー受け取り
- [ ] ブラウザの共有シートに「SyncNews Audio」が表示される（Android/iOS）
- [ ] アプリ未起動から共有 → 起動してURLを受け取り、変換が始まる（コールドスタート）
- [ ] アプリ起動中に共有 → スナックバー表示＋変換が始まる（ホット）
```
