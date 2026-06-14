#!/usr/bin/env bash
#
# setup_native.sh — Flutter ネイティブ足場の生成 + バックグラウンド音声設定の自動適用
#
# `docs/native_setup.md` の手作業（Info.plist / AndroidManifest / MainActivity）を
# 1コマンドに畳む。冪等（再実行しても二重挿入しない）。
#
# 前提: Flutter SDK がインストール済みのローカル環境で、リポジトリ直下から実行する。
#   $ bash scripts/setup_native.sh
#
# ※ この環境(CI/サンドボックス)では Flutter 不在のため未実行・未検証。
#   実機/ローカルでの実行を想定したスクリプト。
set -euo pipefail

ORG="com.syncnews"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v flutter >/dev/null || { echo "❌ flutter が見つかりません。Flutter SDK を導入してください。"; exit 1; }

echo "▶ 1/5 flutter create（既存 lib/ は上書きされない）"
flutter create . --org "$ORG" --platforms=ios,android,web

# ---------- iOS: UIBackgroundModes に audio を追加 ----------
echo "▶ 2/5 iOS Info.plist にバックグラウンド音声を追加"
PLIST="ios/Runner/Info.plist"
PB=/usr/libexec/PlistBuddy
if ! $PB -c "Print :UIBackgroundModes" "$PLIST" >/dev/null 2>&1; then
  $PB -c "Add :UIBackgroundModes array" "$PLIST"
fi
if ! $PB -c "Print :UIBackgroundModes" "$PLIST" 2>/dev/null | grep -q "audio"; then
  $PB -c "Add :UIBackgroundModes:0 string audio" "$PLIST"
  echo "  ✓ UIBackgroundModes: audio を追加"
else
  echo "  = 既に設定済み（スキップ）"
fi

# ---------- Android: MainActivity を AudioServiceActivity 継承へ ----------
echo "▶ 3/5 MainActivity を AudioServiceActivity 継承へ書き換え"
MAIN_KT="$(find android/app/src/main/kotlin -name MainActivity.kt | head -1)"
if [ -z "$MAIN_KT" ]; then echo "❌ MainActivity.kt が見つかりません"; exit 1; fi
PKG="$(grep -m1 '^package ' "$MAIN_KT" | awk '{print $2}')"
cat > "$MAIN_KT" <<EOF
package $PKG

import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity()
EOF
echo "  ✓ $MAIN_KT （package=$PKG）"

# ---------- Android: AndroidManifest に権限/service/receiver を挿入 ----------
echo "▶ 4/5 AndroidManifest.xml に権限・AudioService・MediaButtonReceiver を挿入"
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("android/app/src/main/AndroidManifest.xml")
xml = p.read_text(encoding="utf-8")

if "com.ryanheise.audioservice.AudioService" in xml:
    print("  = 既に挿入済み（スキップ）"); raise SystemExit

perms = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
"""
# <application 直前に権限を挿入
xml = re.sub(r"(\n\s*<application\b)", "\n" + perms + r"\1", xml, count=1)

service = """
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
"""
# </application> 直前に service/receiver を挿入
xml = xml.replace("</application>", service + "    </application>", 1)

# MainActivity の <activity> に共有(text/URL)受け取りの intent-filter を挿入
if "android.intent.action.SEND" not in xml:
    share_filter = """            <!-- ブラウザ等の共有メニューから text/URL を受け取る (PRD 3-1) -->
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="text/*"/>
            </intent-filter>
"""
    # 最初の </activity>（=MainActivity）の直前に挿入
    xml = xml.replace("</activity>", share_filter + "        </activity>", 1)

p.write_text(xml, encoding="utf-8")
print("  ✓ 権限・service・receiver・共有intent-filter を挿入")
PY

echo "▶ 5/5 完了。次の手順:"
cat <<'EOF'
  flutter pub get
  flutter run \
    --dart-define=SUPABASE_URL=... \
    --dart-define=SUPABASE_ANON_KEY=...

  実機で docs/native_setup.md の「動作確認チェックリスト」を消し込むこと。
EOF
