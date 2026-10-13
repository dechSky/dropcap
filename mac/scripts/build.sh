#!/bin/zsh
# 맥 앱(.app)과 설치 파일(.dmg)을 만든다: ./scripts/build.sh
# 결과: build/AI News Alert.app, build/AI-News-Alert-<버전>.dmg (애플 실리콘·인텔 공용)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="build/AI News Alert.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AINewsAlert

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AINewsAlert"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Readability.js "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp ../shared/sources.json "$APP/Contents/Resources/"

# 아이콘
ICON=build/icon && mkdir -p "$ICON/AppIcon.iconset"
swift scripts/make-icon.swift "$ICON/1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON/1024.png" --out "$ICON/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON/1024.png" --out "$ICON/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON"

# 서명(개발자 인증서가 없으면 이 Mac 전용 임시 서명)
IDENTITY=${MAC_SIGN_IDENTITY:--}
codesign --force --deep --options runtime --timestamp=none -s "$IDENTITY" "$APP"

# dmg: 앱 + 응용 프로그램 폴더 바로가기
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI News Alert" -srcfolder "$STAGE" -ov -format UDZO "build/AI-News-Alert-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "완료: $ROOT/build/AI-News-Alert-$VERSION.dmg"
