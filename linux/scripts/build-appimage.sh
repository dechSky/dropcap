#!/usr/bin/env bash
# 리눅스 설치 파일(AppImage)을 만든다: ./scripts/build-appimage.sh
# 결과: dist/Dropcap-<버전>-<아키텍처>.AppImage
# 필요: Rust, GTK4·libadwaita·WebKitGTK 6·gtk4-layer-shell 개발 꾸러미(README 참고), 인터넷(고정 버전 linuxdeploy 받기·SHA-256 확인)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
ARCH=${ARCH:-$(uname -m)}
VERSION=$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)"/\1/')
FEATURES=${DROPCAP_FEATURES:-linux}

cargo build --release -p dropcap-gtk --features "$FEATURES"

APPDIR=$ROOT/dist/AppDir
rm -rf "$APPDIR" && mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/dropcap/fonts" \
  "$APPDIR/usr/share/applications" "$APPDIR/usr/share/metainfo" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" "$APPDIR/usr/share/icons/hicolor/symbolic/apps"
install -m755 target/release/dropcap "$APPDIR/usr/bin/dropcap"
cp resources/Readability.js "$APPDIR/usr/share/dropcap/"
cp resources/fonts/PretendardVariable.ttf resources/fonts/Pretendard-LICENSE.txt "$APPDIR/usr/share/dropcap/fonts/"
cp resources/icons/dropcap-newspaper*-symbolic.svg "$APPDIR/usr/share/dropcap/"
cp resources/icons/dropcap-newspaper*-symbolic.svg "$APPDIR/usr/share/icons/hicolor/symbolic/apps/"
cp resources/icons/io.github.dechsky.Dropcap.svg "$APPDIR/usr/share/icons/hicolor/scalable/apps/"
cp packaging/io.github.dechsky.Dropcap.desktop "$APPDIR/usr/share/applications/"
cp packaging/io.github.dechsky.Dropcap.metainfo.xml "$APPDIR/usr/share/metainfo/"
# 데스크톱 검색(GNOME 검색 공급자·KRunner)·D-Bus 실행 파일: AppImage 는 시스템에 설치되지 않으므로 사본만 담는다(README 의 설치 안내)
mkdir -p "$APPDIR/usr/share/dropcap/integration"
cp packaging/io.github.dechsky.Dropcap.search-provider.ini packaging/io.github.dechsky.Dropcap.service \
  packaging/io.github.dechsky.Dropcap.krunner.desktop "$APPDIR/usr/share/dropcap/integration/"
cp ../THIRD_PARTY_NOTICES.md ../LICENSE "$APPDIR/usr/share/dropcap/" 2>/dev/null || true

# 256px PNG 아이콘(일부 데스크톱은 PNG 만 읽음)
if command -v rsvg-convert >/dev/null; then
  mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
  rsvg-convert -w 256 -h 256 resources/icons/io.github.dechsky.Dropcap.svg -o "$APPDIR/usr/share/icons/hicolor/256x256/apps/io.github.dechsky.Dropcap.png"
fi

# linuxdeploy + GTK 플러그인으로 공유 라이브러리를 담는다.
# 공급망 안전: 버전(릴리스 태그·커밋)을 고정하고 SHA-256 을 확인한다. 올릴 때는 아래 값을 함께 바꾼다.
LD_TAG=1-alpha-20251107-1
GTKP_COMMIT=7a3fbc31a9e5075073ff8790f26effbac5f84453
case "$ARCH" in
  x86_64)  LD_SHA=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d ;;
  aarch64) LD_SHA=620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff ;;
  *) echo "지원하지 않는 아키텍처: $ARCH" >&2; exit 1 ;;
esac
GTKP_SHA=b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171
TOOLS=$ROOT/dist/tools && mkdir -p "$TOOLS"
LD=$TOOLS/linuxdeploy-$ARCH.AppImage
GTKP=$TOOLS/linuxdeploy-plugin-gtk.sh
fetch() { # 주소 파일 sha256
  if [ ! -f "$2" ] || ! echo "$3  $2" | sha256sum -c --status; then
    curl -fsSL -o "$2.part" "$1"
    echo "$3  $2.part" | sha256sum -c --status || { echo "SHA-256 불일치: $1" >&2; rm -f "$2.part"; exit 1; }
    mv "$2.part" "$2"
  fi
  chmod +x "$2"
}
fetch "https://github.com/linuxdeploy/linuxdeploy/releases/download/$LD_TAG/linuxdeploy-$ARCH.AppImage" "$LD" "$LD_SHA"
fetch "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/$GTKP_COMMIT/linuxdeploy-plugin-gtk.sh" "$GTKP" "$GTKP_SHA"
export DEPLOY_GTK_VERSION=4
export PATH="$TOOLS:$PATH"
export LDAI_OUTPUT="$ROOT/dist/Dropcap-$VERSION-$ARCH.AppImage"
# FUSE 가 없는 빌드 서버에서도 돌게
export APPIMAGE_EXTRACT_AND_RUN=1
"$LD" --appdir "$APPDIR" --plugin gtk \
  --desktop-file "$APPDIR/usr/share/applications/io.github.dechsky.Dropcap.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/io.github.dechsky.Dropcap.svg" \
  --output appimage
echo "완료: $LDAI_OUTPUT"
