#!/bin/sh
# 复扫雷 Android 版构建脚本：Zig 编游戏层 .o → NDK clang 编 C 平台层并链接 .so → aapt2 打包 → 签名
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ZIG=$ROOT/toolchain/zig/zig
NDK=$ROOT/toolchain/ndk
SDK=$ROOT/toolchain/sdk
BT=$SDK/build-tools/34.0.0
SRC=$HERE/app/src
OUT=$HERE/build
NDKBIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
GLUE=$NDK/sources/android/native_app_glue
PATH=$NDKBIN:$PATH
export PATH

APPNAME=complexsweeper
rm -rf "$OUT"
mkdir -p "$OUT"

# abi:zig目标:clang前缀
ABIS="arm64-v8a:aarch64-linux-android:aarch64-linux-android21
armeabi-v7a:arm-linux-androideabi:armv7a-linux-androideabi21
x86_64:x86_64-linux-android:x86_64-linux-android21
x86:x86-linux-android:i686-linux-android21"

echo "=== 1/5 编译四 ABI 原生库 ==="
for spec in $ABIS; do
    ABI=$(echo "$spec" | cut -d: -f1)
    ZT=$(echo "$spec" | cut -d: -f2)
    CC=$(echo "$spec" | cut -d: -f3)-clang
    mkdir -p "$OUT/lib/$ABI"
    "$ZIG" build-obj "$SRC/android_main.zig" -O ReleaseSmall -fPIC -target "$ZT" \
        -femit-bin="$OUT/lib/$ABI/android_main.o"
    "$CC" -O2 -fPIC -shared -Wl,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-s \
        -I"$GLUE" \
        -o "$OUT/lib/$ABI/lib$APPNAME.so" \
        "$SRC/platform.c" "$GLUE/android_native_app_glue.c" "$OUT/lib/$ABI/android_main.o" \
        -llog -lEGL -lGLESv2 -landroid -lOpenSLES -lz -lm
    rm -f "$OUT/lib/$ABI/android_main.o"
    printf "  %-12s %8s 字节\n" "$ABI" "$(stat -c%s "$OUT/lib/$ABI/lib$APPNAME.so")"
done

echo "=== 2/5 编译资源 ==="
"$BT/aapt2" compile --dir "$HERE/app/res" -o "$OUT/res.zip"

echo "=== 3/5 链接 APK ==="
"$BT/aapt2" link -o "$OUT/base.apk" \
    -I "$SDK/platforms/android-34/android.jar" \
    --manifest "$HERE/app/AndroidManifest.xml" \
    -R "$OUT/res.zip" \
    --min-sdk-version 21 --target-sdk-version 34 \
    --version-code 1 --version-name 1.2.0 \
    --auto-add-overlay

echo "=== 4/5 放入原生库并对其 ==="
cd "$OUT"
for spec in $ABIS; do
    ABI=$(echo "$spec" | cut -d: -f1)
    zip -q -0 base.apk "lib/$ABI/lib$APPNAME.so"
done
"$BT/zipalign" -f -p 4 base.apk aligned.apk

echo "=== 5/5 签名 ==="
KS=$HERE/debug.keystore
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Complexweeper Debug,O=Android,C=CN" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/$APPNAME.apk" aligned.apk

echo "完成：$OUT/$APPNAME.apk  $(stat -c%s "$OUT/$APPNAME.apk") 字节"
