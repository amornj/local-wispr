#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="$PWD"
sdk_dir="$(xcrun --show-sdk-path)"
mkdir -p .build dist

if [ ! -f .build/vendor/whisper.cpp/include/whisper.h ]; then
    mkdir -p .build/vendor
    git clone --depth 1 --branch v1.8.2 https://github.com/ggml-org/whisper.cpp.git .build/vendor/whisper.cpp
fi
if [ ! -f models/ggml-base.bin ]; then
    mkdir -p models
    curl -fL --retry 3 -o models/ggml-base.bin.download https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
    mv models/ggml-base.bin.download models/ggml-base.bin
fi
model_digest="$(shasum -a 256 models/ggml-base.bin | awk '{print $1}')"
if [ "$model_digest" != "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe" ]; then
    echo "The Whisper model checksum did not match. Remove models/ggml-base.bin and run the build again." >&2
    exit 1
fi
if command -v cmake >/dev/null 2>&1; then
    cmake_bin="$(command -v cmake)"
else
    if [ ! -x .build/tools-venv/bin/cmake ]; then
        python3 -m venv .build/tools-venv
        .build/tools-venv/bin/pip install cmake==4.4.5
    fi
    cmake_bin="$project_dir/.build/tools-venv/bin/cmake"
fi
"$cmake_bin" -S .build/vendor/whisper.cpp -B .build/whisper \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF \
    "-DCMAKE_CXX_FLAGS=-isystem $sdk_dir/usr/include/c++/v1"
"$cmake_bin" --build .build/whisper --target whisper-cli -j 6

xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -isysroot "$sdk_dir" -isystem "$sdk_dir/usr/include/c++/v1" \
    -I .build/vendor/whisper.cpp/include -I .build/vendor/whisper.cpp/ggml/include \
    -c Sources/WhisperBridge.cpp -o .build/WhisperBridge.o

app_dir="$project_dir/dist/Local Wispr.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -import-objc-header Sources/WhisperBridge.h \
    Sources/Main.swift Sources/AppModel.swift Sources/ContentView.swift Sources/SpeechEngine.swift Sources/DictationFormatting.swift Sources/OllamaClient.swift Sources/FnKeyMonitor.swift Sources/TextInsertion.swift \
    .build/WhisperBridge.o \
    .build/whisper/src/libwhisper.a .build/whisper/ggml/src/libggml.a \
    .build/whisper/ggml/src/libggml-base.a .build/whisper/ggml/src/libggml-cpu.a \
    .build/whisper/ggml/src/ggml-blas/libggml-blas.a \
    -lc++ -framework Accelerate -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices \
    -o "$app_dir/Contents/MacOS/LocalWispr"
cp -c models/ggml-base.bin "$app_dir/Contents/Resources/ggml-base.bin"
if [ ! -f "$app_dir/Contents/Resources/AppIcon.icns" ]; then
    xcrun swift scripts/make-icon.swift .build/AppIcon.iconset
    iconutil -c icns .build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
fi
cp .build/vendor/whisper.cpp/LICENSE "$app_dir/Contents/Resources/whisper.cpp-LICENSE.txt"
signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')"
if [ -z "$signing_identity" ]; then signing_identity="-"; fi
codesign --force --sign "$signing_identity" "$app_dir"
echo "Built $app_dir"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    ditto "$app_dir" "$HOME/Applications/Local Wispr.app"
    echo "Installed $HOME/Applications/Local Wispr.app"
fi
