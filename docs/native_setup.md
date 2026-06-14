# ネイティブ設定（バックグラウンド音声 / ロック画面 / イヤホン連携）

`audio_service` + `just_audio` を **OSレベルで有効化**するための iOS / Android 設定。
ここを入れないと「画面ロックで音が止まる」「ロック画面に出ない」「イヤホン操作が効かない」
という Step2 のコア要件（PRD 3-4 / 技術課題①）が満たせない。

> 前提: `flutter create . --org com.syncnews` でネイティブ足場を生成済みであること。
> 既存の `lib/` は上書きされない。

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

## 動作確認チェックリスト（実機推奨）

- [ ] 再生中にロック → 音が継続する
- [ ] ロック画面 / コントロールセンターに タイトル・再生・±スキップが出る
- [ ] ロック画面のボタンで再生/一時停止/±スキップが効く
- [ ] イヤホンのシングルタップで再生/一時停止
- [ ] イヤホンのダブルタップで15秒送り、トリプルタップで30秒戻し
- [ ] 電話着信 → 自動で一時停止、終話後に再開（iOS/Android とも）
- [ ] 他アプリで音楽再生 → 本アプリが適切に中断/復帰
- [ ] バックグラウンド中も `positionStream` が流れ、復帰時にハイライトが正しい位置
```
