#!/usr/bin/env bash
# iOS build automation: translate -> emit build shards -> configure -> compile -> package into an
# unsigned .ipa.
#
# Counterpart to Launcher/local-build.sh (Linux): same translate/build pipeline and the same
# conventions (log_step markers, fingerprinted translation reuse, tool overrides), but packaging
# targets iOS's app-bundle/IPA format instead of a plain published directory, and the native
# configure step needs several iOS-cross-compile-specific CMake flags no other platform needs -
# see configure-native below for why each one is there.
#
# This must run on macOS: it drives Xcode's iOS SDK/toolchain, which is not available anywhere
# else. It has no Windows/Linux counterpart to stay in sync with beyond local-build.sh's general
# shape, since neither of those platforms builds for iOS.
#
# Scope: base game only for now, no --profile/retro-rewind support - the underlying translator
# commands are platform-agnostic (see local-build.sh's --profile handling for the pattern), but
# Retro Rewind has not been built or tested on iOS at all, so this script does not claim to
# support it yet rather than ship untested mod-profile code paths.
#
# Produces an UNSIGNED .ipa. Every iOS install path (a paid Apple Developer account, a free-tier
# sideloading tool such as AltStore/Sideloadly/Impactor, TrollStore, etc.) needs the user's own
# Apple ID and signing tool regardless of how the IPA was built, so this script deliberately stops
# at the last step it can actually automate and leaves signing to whatever the user already uses.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_step() {
    # $1 = machine-readable step id, $2 = human sentence. Same convention as local-build.sh /
    # LocalBuild.ps1's Write-MkwBuildStep: the id is a stable marker a future installer could
    # parse from the log, the sentence is for the human reading the terminal.
    printf 'MKWCBUILD:STEP:%s %s\n' "$1" "$2"
}

fail() {
    echo "local-build-ios.sh: error: $*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "$2 is missing: $1"
}

assert_dir() {
    [[ -d "$1" ]] || fail "$2 is missing: $1"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool '$1' was not found on PATH (override with --$2)"
}

sha256_of() {
    # macOS has no sha256sum; this script only ever runs on macOS (it drives Xcode's iOS
    # toolchain), so shasum -a 256 needs no Linux fallback the way local-build.sh's sha256_of does.
    shasum -a 256 "$1" | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd "$script_dir/.." && pwd)
output_dir=""
platform=device
deployment_target=16.0
bundle_id="dev.wiicompiled.game"
bundle_name="WiiCompiled"
bundle_version="1"
bundle_short_version="1.0"
ios_toolchain_override=""
force_clean_build=0
parallel_override=0
cmake_override=""
ninja_override=""
dotnet_override=""
translator_dll_override=""
translator_bin_override=""

usage() {
    cat <<'EOF'
Usage: local-build-ios.sh --output-dir DIR [options]

  --workspace DIR              Repository root (default: this script's parent directory)
  --output-dir DIR             Where the built .ipa is published (required)
  --platform {device|simulator}  Build target (default: device). Device uses a prebuilt Dawn
                                package (fast); simulator builds Dawn from source (slow, but lets
                                you iterate without a physical device or a signing step at all).
  --deployment-target VERSION  Minimum iOS version (default: 16.0 - Dawn's std::atomic::wait
                                usage needs iOS Simulator 14.0+; 16.0 leaves headroom with no real
                                downside since sideloading a much older device is uncommon)
  --bundle-id ID                CFBundleIdentifier (default: dev.wiicompiled.game)
  --bundle-name NAME            CFBundleName / CFBundleExecutable display name (default: WiiCompiled)
  --bundle-version VERSION      CFBundleVersion, a build number (default: 1)
  --bundle-short-version VER    CFBundleShortVersionString, a user-facing version (default: 1.0)
  --ios-toolchain PATH          ios-cmake's ios.toolchain.cmake (default: WORKSPACE/ios.toolchain.cmake
                                if present, otherwise downloaded once into the build directory)
  --force-clean-build           Discard every translation/build cache first
  --parallel N                  Pin translator threads, translated-shard job pool, and Ninja parallelism to N
  --cmake PATH / --ninja PATH   Build tools (default: on PATH)
  --dotnet PATH                 dotnet executable (default: on PATH)
  --translator-dll PATH         Pre-built Translator.Cli.dll (skips building the translator; still needs --dotnet to run it)
  --translator-bin PATH         Self-contained Translator.Cli executable (skips building AND needs no dotnet at all)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) workspace=$(cd "$2" && pwd); shift 2 ;;
        --output-dir) output_dir=$2; shift 2 ;;
        --platform) platform=$2; shift 2 ;;
        --deployment-target) deployment_target=$2; shift 2 ;;
        --bundle-id) bundle_id=$2; shift 2 ;;
        --bundle-name) bundle_name=$2; shift 2 ;;
        --bundle-version) bundle_version=$2; shift 2 ;;
        --bundle-short-version) bundle_short_version=$2; shift 2 ;;
        --ios-toolchain) ios_toolchain_override=$2; shift 2 ;;
        --force-clean-build) force_clean_build=1; shift ;;
        --parallel) parallel_override=$2; shift 2 ;;
        --cmake) cmake_override=$2; shift 2 ;;
        --ninja) ninja_override=$2; shift 2 ;;
        --dotnet) dotnet_override=$2; shift 2 ;;
        --translator-dll) translator_dll_override=$2; shift 2 ;;
        --translator-bin) translator_bin_override=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[[ -n "$output_dir" ]] || { usage; fail "--output-dir is required"; }
case "$platform" in
    device|simulator) ;;
    *) fail "--platform must be device or simulator" ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || fail "this script drives Xcode's iOS SDK and must run on macOS"

# ---------------------------------------------------------------------------
# Tool resolution and prerequisite checks
# ---------------------------------------------------------------------------

dotnet_bin=${dotnet_override:-dotnet}
cmake_bin=${cmake_override:-cmake}
ninja_bin=${ninja_override:-ninja}

if [[ -z "$translator_bin_override" ]]; then
    require_command "$dotnet_bin" dotnet
fi
require_command "$cmake_bin" cmake
require_command "$ninja_bin" ninja
require_command xcodebuild xcode
require_command zip zip
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || \
    fail "no iOS SDK found (xcrun --sdk iphoneos --show-sdk-path failed) - install Xcode, not just the Command Line Tools"

project=$workspace/projects/mkwii/recomp.yml
assets=$workspace/Assets
generated=$workspace/generated
functions=$generated/functions
base_metadata=$generated/base_translation_output.json
base_manifest_dir=$workspace/build/base
base_manifest=$base_manifest_dir/mkwii_base_manifest.json
shards=$generated/build_shards
build=$workspace/ios-build-$platform
translation_provenance=$generated/translation-provenance.json

assert_file "$project" "Translation project"
assert_file "$assets/main.dol" "Extracted main.dol (see translator/README.md - owning the game is required; nodtool extract your own disc image into Assets/ first)"
assert_file "$assets/StaticR.rel" "Extracted StaticR.rel (see translator/README.md - owning the game is required; nodtool extract your own disc image into Assets/ first)"
assert_dir "$assets/DATA" "Extracted DATA directory (nodtool extract your own disc image into Assets/DATA - this gets bundled into the app)"

# Literal line matching against the manifest's fixed shape, not a YAML dependency - the same
# approach local-build.sh and NativeBuildFlags.ps1's Get-MkwProjectPins use, kept here only for
# the one field this script actually needs from the manifest.
entry_point=$(awk '
    /^translation:/ { in_translation = 1 }
    in_translation && /^[[:space:]]*-[[:space:]]*0[xX][0-9a-fA-F]+[[:space:]]*$/ {
        gsub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
    }
' "$project")
[[ -n "$entry_point" ]] || fail "Could not find a translation entry point in $project"

# ios-cmake (BSD-licensed, https://github.com/leetal/ios-cmake) is deliberately not vendored into
# this repo, the same way CMake or Ninja themselves aren't - if the workspace doesn't already have
# a copy, fetch the one known-working revision once into the build directory rather than trusting
# a moving `master` branch to keep behaving the same way build to build.
ios_toolchain=$ios_toolchain_override
if [[ -z "$ios_toolchain" ]]; then
    if [[ -f "$workspace/ios.toolchain.cmake" ]]; then
        ios_toolchain=$workspace/ios.toolchain.cmake
    else
        mkdir -p "$build"
        ios_toolchain=$build/ios.toolchain.cmake
        if [[ ! -f "$ios_toolchain" ]]; then
            log_step fetch-ios-toolchain "Downloading the ios-cmake toolchain file"
            curl -fsSL -o "$ios_toolchain" \
                https://raw.githubusercontent.com/leetal/ios-cmake/4.5.0/ios.toolchain.cmake
        fi
    fi
fi
assert_file "$ios_toolchain" "ios-cmake toolchain file"

translator_bin=$translator_bin_override
translator_dll=$translator_dll_override
if [[ -n "$translator_bin" ]]; then
    assert_file "$translator_bin" "Translator.Cli executable"
    translator() { "$translator_bin" "$@"; }
else
    if [[ -z "$translator_dll" ]]; then
        translator_dll=$workspace/translator/src/Translator.Cli/bin/Release/net8.0/Translator.Cli.dll
        log_step build-translator "Building the translator"
        "$dotnet_bin" build "$workspace/translator/src/Translator.Cli/Translator.Cli.csproj" -c Release
    fi
    assert_file "$translator_dll" "Translator.Cli.dll"
    translator() { "$dotnet_bin" "$translator_dll" "$@"; }
fi

# ---------------------------------------------------------------------------
# Parallelism: same three knobs and reasoning as local-build.sh, via macOS's sysctl instead of
# Linux's nproc//proc/meminfo.
# ---------------------------------------------------------------------------

cpu_count=$(sysctl -n hw.ncpu)
mem_gib=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
(( mem_gib < 1 )) && mem_gib=1

if (( parallel_override > 0 )); then
    translator_threads=$parallel_override
    translated_jobs=$parallel_override
    global_jobs=$parallel_override
else
    translator_threads=$(( cpu_count < 16 ? cpu_count : 16 ))
    (( translator_threads < 1 )) && translator_threads=1
    mem_based_cap=$(( mem_gib / 2 ))
    (( mem_based_cap < 1 )) && mem_based_cap=1
    translated_jobs=$(( cpu_count < mem_based_cap ? cpu_count : mem_based_cap ))
    (( translated_jobs < 1 )) && translated_jobs=1
    global_jobs=$(( translated_jobs > cpu_count ? translated_jobs : cpu_count ))
fi

# ---------------------------------------------------------------------------
# Translation cache: same fingerprint-and-reuse approach as local-build.sh. Hash the game inputs
# the translation actually depends on; a match plus every expected output file present means the
# previous translation is still good.
# ---------------------------------------------------------------------------

if (( force_clean_build )); then
    log_step force-clean "A clean build was requested; discarding every translation and build cache"
    rm -rf "$generated" "$base_manifest_dir" "$build"
fi

translation_fingerprint=$(cat "$assets/main.dol" "$assets/StaticR.rel" "$project" | shasum -a 256 | awk '{print $1}')
reuse_base=0
if [[ -f "$translation_provenance" ]]; then
    recorded=$(grep -o '"TranslationFingerprint" *: *"[^"]*"' "$translation_provenance" 2>/dev/null | sed 's/.*"\([0-9a-f]*\)"$/\1/' || true)
    if [[ "$recorded" == "$translation_fingerprint" && -f "$base_metadata" && -f "$base_manifest" ]]; then
        reuse_base=1
    fi
fi

if (( reuse_base )); then
    log_step reuse-base-translation "Reusing the completed base translation"
else
    rm -f "$translation_provenance"
    mkdir -p "$generated" "$base_manifest_dir"

    log_step translate-base "Translating the user-owned base game"
    translator translate-recursive "$entry_point" --project "$project" \
        --outdir "$functions" --output-metadata "$base_metadata" \
        --production-source-bundle "$generated/base_translation_sources.bin" \
        --no-function-files --prune-stale --threads "$translator_threads"

    log_step emit-base-manifest "Creating the local base translation manifest"
    translator emit-base-manifest --project "$project" --out "$base_manifest_dir" \
        --functions-dir "$functions" --translation-output-metadata "$base_metadata" --region P

    printf '{"SchemaVersion":1,"TranslationFingerprint":"%s"}' "$translation_fingerprint" \
        > "$translation_provenance"
fi

log_step generate-data-init "Generating local game data initialization"
translator generate-data-init --project "$project"

log_step emit-build-shards "Preparing local native build shards"
translator emit-build-shards --project "$project" --base-metadata "$base_metadata" \
    --base-functions-dir "$functions" --native-source-dir "$workspace/runtime/src" --out "$shards"

# ---------------------------------------------------------------------------
# Native configure + build. Every flag below exists specifically for cross-compiling to iOS - see
# the comment on each; none of them apply to (or are needed by) local-build.sh's native-Linux path.
# ---------------------------------------------------------------------------

case "$platform" in
    device)
        cmake_platform=OS64
        # A prebuilt Dawn package exists for real iOS devices (unlike the simulator, see below),
        # so device builds skip Dawn's from-source compile entirely - verified this session to cut
        # build time from minutes to well under one.
        dawn_provider_args=(-DAURORA_DAWN_PROVIDER=package
            -DAURORA_DAWN_PACKAGE_URL=https://github.com/encounter/dawn-build/releases/download/v20260603.191052/dawn-ios-arm64.tar.gz)
        ;;
    simulator)
        cmake_platform=SIMULATORARM64
        # No prebuilt Dawn package exists for the simulator target, so this builds Dawn from
        # source. AURORA_DAWN_VERSION's default (see aurora-main/CMakeLists.txt) is a
        # dawn-build *release* tag, not a real google/dawn git tag/commit; this is the actual
        # upstream commit that release was built from (its own GitHub release notes name it).
        dawn_provider_args=(-DAURORA_DAWN_PROVIDER=vendor
            -DAURORA_DAWN_VERSION=13abc3bc8ea2d3c2050f9e77a12d012108ceee24)
        ;;
esac

keep_native_build=0
if [[ -f "$build/CMakeCache.txt" ]]; then
    expected_home=$workspace/runtime
    cache_home=$(grep '^CMAKE_HOME_DIRECTORY:INTERNAL=' "$build/CMakeCache.txt" | cut -d= -f2- || true)
    if [[ -n "$cache_home" && "$(cd "$cache_home" 2>/dev/null && pwd)" == "$expected_home" ]]; then
        keep_native_build=1
    fi
fi
if [[ -d "$build" && "$keep_native_build" -eq 0 && ! -f "$build/CMakeCache.txt" ]]; then
    : # freshly created above just to hold a downloaded ios.toolchain.cmake; nothing to discard
elif [[ -d "$build" && "$keep_native_build" -eq 0 ]]; then
    echo "MKWCBUILD: The native build cache does not belong to this workspace path; rebuilding from scratch"
    rm -rf "$build"
elif [[ "$keep_native_build" -eq 1 ]]; then
    echo "MKWCBUILD: Reusing the incremental native build directory"
fi

log_step configure-native "Configuring the iOS toolchain ($platform)"
"$cmake_bin" -S "$workspace/runtime" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ios_toolchain" \
    -DPLATFORM="$cmake_platform" \
    -DDEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$ninja_bin" \
    -DMKW_TRANSLATED_COMPILE_JOBS="$translated_jobs" \
    -DCMAKE_SYSTEM_IGNORE_PATH=/opt/homebrew \
    -DCMAKE_IGNORE_PATH=/opt/homebrew \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    "${dawn_provider_args[@]}" \
    -DAURORA_SDL3_PROVIDER=vendor

log_step compile "Compiling WiiCompiled for iOS ($platform)"
"$cmake_bin" --build "$build" --target WiiCompiled --parallel "$global_jobs"

# ---------------------------------------------------------------------------
# Package: patch the placeholder Info.plist ios.toolchain.cmake generates, bundle the extracted
# game data into the app (there is no on-device way to point a fresh install at a dvd_root outside
# its own sandboxed container - see runtime_config.h's ResolvedDvdRoot), and zip into an unsigned
# .ipa. No codesign step anywhere in this script, deliberately - see the file header.
# ---------------------------------------------------------------------------

app_bundle=$build/$bundle_name.app
assert_dir "$app_bundle" "Built .app bundle"

case "$platform" in
    device) supported_platform=iPhoneOS; dt_platform_name=iphoneos ;;
    simulator) supported_platform=iPhoneSimulator; dt_platform_name=iphonesimulator ;;
esac

log_step patch-info-plist "Writing the app's Info.plist"
cat > "$app_bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>$bundle_name</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$bundle_name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$bundle_short_version</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>$bundle_version</string>
	<key>CSResourcesFileMapped</key>
	<true/>
	<key>MinimumOSVersion</key>
	<string>$deployment_target</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$supported_platform</string>
	</array>
	<key>DTPlatformName</key>
	<string>$dt_platform_name</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
</dict>
</plist>
PLIST

log_step bundle-data "Bundling the extracted game data into the app"
rsync -a --delete "$assets/DATA/" "$app_bundle/DATA/"

log_step package-ipa "Packaging an unsigned .ipa"
payload_dir=$build/Payload
rm -rf "$payload_dir"
mkdir -p "$payload_dir"
cp -R "$app_bundle" "$payload_dir/"
mkdir -p "$output_dir"
ipa_path=$output_dir/$bundle_name.ipa
rm -f "$ipa_path"
(cd "$build" && zip -r -X -y "$ipa_path" "Payload") >/dev/null
rm -rf "$payload_dir"

dol_sha=$(sha256_of "$assets/main.dol")
rel_sha=$(sha256_of "$assets/StaticR.rel")
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$output_dir/local-build-ios.json" <<JSON
{
  "SchemaVersion": 1,
  "Platform": "$platform",
  "DeploymentTarget": "$deployment_target",
  "BundleIdentifier": "$bundle_id",
  "BuiltUtc": "$built_utc",
  "DolSha256": "$dol_sha",
  "RelSha256": "$rel_sha",
  "Signed": false
}
JSON

echo "MKWCBUILD:OUTPUT=$ipa_path"
