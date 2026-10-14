#!/bin/zsh
# 맥 앱(.app)과 설치 파일(.dmg)을 만든다: ./scripts/build.sh
# 결과: build/Dropcap.app, build/Dropcap-<버전>.dmg (애플 실리콘·인텔 공용)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="build/Dropcap.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

# 단축어(App Intents): 컴파일러가 상수 정보(.swiftconstvalues)를 내게 해 두고, 아래에서 Metadata.appintents 로 만든다
INTENT_FLAGS=(-Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$ROOT/scripts/appintents-protocols.json" -Xswiftc -emit-const-values)
swift build -c release --arch arm64 --arch x86_64 "${INTENT_FLAGS[@]}"
BINDIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN=$BINDIR/Dropcap

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dropcap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Readability.js "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp ../shared/sources.json "$APP/Contents/Resources/"

# 위젯 확장: Contents/PlugIns/DropcapWidgets.appex (버전은 앱과 같게)
APPEX="$APP/Contents/PlugIns/DropcapWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BINDIR/DropcapWidgets" "$APPEX/Contents/MacOS/DropcapWidgets"
cp Resources/Widgets-Info.plist "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)" "$APPEX/Contents/Info.plist"

# 단축어 메타데이터: Contents/Resources/Metadata.appintents
META=build/appintents && mkdir -p "$META"
find "$ROOT/Sources/Dropcap" -name '*.swift' > "$META/sources.txt"
find "$ROOT/.build" -path '*/Release/Dropcap-p.build/*/arm64/*' -name '*.swiftconstvalues' > "$META/constvalues.txt"
TOOLCHAIN=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$TOOLCHAIN" --module-name Dropcap \
  --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
  --source-file-list "$META/sources.txt" --swift-const-vals-list "$META/constvalues.txt" --quiet-warnings
[[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || { echo "단축어 메타데이터를 만들지 못했습니다"; exit 1; }
rm -rf "$META"

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
# 안쪽(위젯 확장)부터 자기 권한으로 서명하고 앱을 서명한다. --deep 은 확장의 샌드박스 권한을 지워 버리므로 쓰지 않는다.
IDENTITY=${MAC_SIGN_IDENTITY:--}
codesign --force --options runtime --timestamp=none --entitlements Resources/Widgets.entitlements -s "$IDENTITY" "$APPEX"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# dmg: 앱 + 응용 프로그램 폴더 바로가기
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dropcap" -srcfolder "$STAGE" -ov -format UDZO "build/Dropcap-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "완료: $ROOT/build/Dropcap-$VERSION.dmg"
