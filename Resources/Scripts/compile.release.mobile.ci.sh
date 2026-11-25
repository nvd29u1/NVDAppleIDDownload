#!/bin/zsh

set -euo pipefail

SRCROOT=$(realpath "$1")
TARGET_IPA=$2

WORKSPACE="$SRCROOT/Asspp.xcworkspace"
SCHEME="NVDAppleIDDownload"
BUILD_PRODUCT="NVDAppleIDDownload.app"

cd $SRCROOT

git clean -fdx -f
git reset --hard

# Generate Developer.xcconfig for CI (codesign completely disabled)
cat >"$SRCROOT/Configuration/Developer.xcconfig" <<'EOF'
// CI-generated Developer.xcconfig
// Code signing is completely disabled for CI builds
DEVELOPMENT_TEAM =
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY =
CODE_SIGN_IDENTITY[sdk=macosx*] =
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
EOF

# Build the Rust pairing bridge (libsayoidev.a, from SayoSign) for iOS.
# The app target links it only for the iphoneos SDK
# (OTHER_LDFLAGS[sdk=iphoneos*] in the project); a missing .a fails the
# link, so check it exists here with a clear error instead of a cryptic
# linker failure. Runs after `git clean` above, so the target dir is fresh.
if ! command -v cargo >/dev/null 2>&1; then
    echo "[-] cargo not found: the Rust toolchain is required to build rust/sayoidev (libsayoidev.a)"
    exit 1
fi
if command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-apple-ios
fi
IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build --release --target aarch64-apple-ios --manifest-path "$SRCROOT/rust/sayoidev/Cargo.toml"
if [ ! -f "$SRCROOT/rust/sayoidev/target/aarch64-apple-ios/release/libsayoidev.a" ]; then
    echo "[-] libsayoidev.a was not built (rust/sayoidev/target/aarch64-apple-ios/release/)"
    exit 1
fi
echo "[+] libsayoidev.a built"

# Reassemble the SAP runtime WASM (iPadn login, 2.1 build 20).
# sap.wasm is ~50 MB, too large for a single Git Data API blob, so the repo
# stores it split as NVDAppleIDDownload/SAPRuntime/sap.wasm.part00..05
# (8 MB each); reassemble it here, after `git clean`/`git reset` above,
# and verify the SHA-256 from vendor/SAPRuntime/manifest.json before the build.
if [ ! -f "$SRCROOT/NVDAppleIDDownload/SAPRuntime/sap.wasm" ]; then
    cat "$SRCROOT/NVDAppleIDDownload/SAPRuntime/sap.wasm.part"* > "$SRCROOT/NVDAppleIDDownload/SAPRuntime/sap.wasm"
fi
if [ "$(shasum -a 256 "$SRCROOT/NVDAppleIDDownload/SAPRuntime/sap.wasm" | awk '{print $1}')" != "b7150bb4d31a03c1a813d310c0b5d7211be2510f7ee970b273f4fce7ea134015" ]; then
    echo "[-] sap.wasm SHA-256 mismatch after reassembly (expected b7150bb4...)"
    exit 1
fi
echo "[+] sap.wasm reassembled and verified"

# The .part files are only needed for the reassembly above. The project
# uses a synchronized group, so Xcode would copy them flat into the app
# bundle as well (~50 MB wasted in the IPA). Move them out of the source
# tree before xcodebuild; the runner is ephemeral, no restore needed.
mkdir -p /tmp/sap-parts-build20
mv "$SRCROOT/NVDAppleIDDownload/SAPRuntime/sap.wasm.part"* /tmp/sap-parts-build20/
echo "[+] sap.wasm.part* moved out of the bundle"

xcodebuild -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$SRCROOT/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    build \
    DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" \
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES STRIP_INSTALLED_PRODUCT=NO \
    COPY_PHASE_STRIP=NO UNSTRIPPED_PRODUCT=NO \
    | xcbeautify

BUILD_PRODUCT_PATH=""
for i in $(find "$SRCROOT/build/DerivedDataApp" -name "$BUILD_PRODUCT"); do
    BUILD_PRODUCT_PATH=$i
    break
done
BUILD_PRODUCT_PATH=$(realpath "$BUILD_PRODUCT_PATH")

if [ -z "$BUILD_PRODUCT_PATH" ]; then
    echo "[-] build product not found"
    exit 1
fi

echo "[+] build product path: $BUILD_PRODUCT_PATH"

echo "[+] packaging..."
pushd "$SRCROOT/build"
mkdir -p Payload
cp -r "$BUILD_PRODUCT_PATH" Payload
zip -r "$TARGET_IPA" Payload
rm -rf Payload
popd

echo "[+] done"
