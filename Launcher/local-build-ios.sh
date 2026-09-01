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
# Supports the same --profile {base|retro-rewind|both} local-build.sh does. Unlike Linux (and
# unlike WiiCompiled generally - see WiiCompiled.Setup.Common/RetroRewindSource.cs: "Wheel Wizard
# owns [Retro Rewind] and passes it... each installer only resolves, reads, and records it, never
# packages or copies it"), this script *does* accept the Retro Rewind distribution as a zip
# (--retro-rewind-zip, as downloaded from rwfc.net) in addition to an already-extracted folder
# (--retro-rewind-dir/local-build.sh's --retro-rewind-package-dir), since there is no Wheel-Wizard
# equivalent driving this script.
#
# Produces an UNSIGNED .ipa. Every iOS install path (a paid Apple Developer account, a free-tier
# sideloading tool such as AltStore/Sideloadly/Impactor, TrollStore, etc.) needs the user's own
# Apple ID and signing tool regardless of how the IPA was built, so this script deliberately stops
# at the last step it can actually automate and leaves signing to whatever the user already uses.
#
# --simulator skips all of that: the Simulator needs no signing at all, so instead of packaging an
# .ipa this builds for SIMULATORARM64, installs the .app straight into a booted (or freshly booted)
# iOS Simulator, and launches it with its console streamed live - a fast dev loop with no device,
# no sideloading tool, and no --output-dir.
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

to_absolute() {
    # Unlike resolve_retro_rewind_dir's `cd ... && pwd -P`, this must not require the path to
    # already exist - --output-dir/--base-output-dir are created later via mkdir -p. Needed
    # because the packaging step's `(cd "$build" && zip ...)` would otherwise resolve a relative
    # --output-dir against $build instead of the directory this script was invoked from.
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$PWD/$1" ;;
    esac
}

sha256_of() {
    # macOS has no sha256sum; this script only ever runs on macOS (it drives Xcode's iOS
    # toolchain), so shasum -a 256 needs no Linux fallback the way local-build.sh's sha256_of does.
    shasum -a 256 "$1" | awk '{print $1}'
}

resolve_retro_rewind_dir() {
    # Bash port of WiiCompiled.Setup.Common/RetroRewindSource.cs's ResolveRetroRewind6: accepts
    # the RetroRewind6 folder itself, a parent directory containing it directly, or (the shape
    # rwfc.net's own zip unpacks to) a parent containing exactly one child whose own RetroRewind6
    # subfolder has Binaries/Code.pul. `pwd -P` resolves symlinks to their physical path, the bash
    # equivalent of that C# code's explicit DirectoryInfo.ResolveLinkTarget step.
    local root=$1
    local -a candidates=()
    [[ -f "$root/Binaries/Code.pul" ]] && candidates+=("$root")
    [[ -f "$root/RetroRewind6/Binaries/Code.pul" ]] && candidates+=("$root/RetroRewind6")
    local child
    for child in "$root"/*/; do
        [[ -f "${child}RetroRewind6/Binaries/Code.pul" ]] && candidates+=("${child}RetroRewind6")
    done
    local -a resolved=()
    local c
    for c in "${candidates[@]}"; do
        resolved+=("$(cd "$c" && pwd -P)")
    done
    local unique
    unique=$(printf '%s\n' "${resolved[@]}" | sort -u)
    local count=0
    [[ -n "$unique" ]] && count=$(printf '%s\n' "$unique" | grep -c .)
    case "$count" in
        1) printf '%s\n' "$unique" ;;
        0) fail "$root does not contain RetroRewind6/Binaries/Code.pul (looked in the folder itself, a RetroRewind6 subfolder, and any single child's RetroRewind6 subfolder). Pass the exact folder, or the rwfc.net zip, via --retro-rewind-dir/--retro-rewind-zip." ;;
        *) fail "$root contains more than one RetroRewind6/Binaries/Code.pul; pass the exact folder via --retro-rewind-dir" ;;
    esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd "$script_dir/.." && pwd)
output_dir=""
base_output_dir=""
game_dump=""
run_simulator=0
profile=base
retro_rewind_zip=""
retro_rewind_dir=""
retro_wfc_offline_dir=""
skip_retro_wfc_payload=0
deployment_target=14.0
bundle_id="dev.wiicompiled.game"
bundle_name="WiiCompiled"
bundle_version="1"
bundle_short_version="1.0"
ios_toolchain_override=""
skip_ipa_packaging=0
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
  --base-output-dir DIR        Second output directory; required with --profile both
  --game PATH                  Your own Mario Kart Wii disc image (ISO/WBFS/etc, whatever nodtool
                                reads). Extracted into Assets/ via nodtool, validated against this
                                project's pinned game ID and main.dol/StaticR.rel hashes. Skipped if
                                Assets/ already has an extracted dump (see the plain assert_file
                                errors below for how to place one there yourself instead).
  --simulator                   Build for the iOS Simulator instead of a real device (from-source
                                Dawn, slower to configure but no signing step at all), skip .ipa
                                packaging, and instead install + launch the app directly in a
                                booted (or freshly booted) Simulator with its console streamed live.
                                --output-dir/--base-output-dir are not used and --profile both is
                                not supported (there would be two apps to launch).
  --profile {base|retro-rewind|both}   Build profile (default: base)
  --retro-rewind-zip PATH      The Retro Rewind distribution as downloaded from rwfc.net (a zip
                                containing RetroRewind6, possibly under one wrapper folder)
  --retro-rewind-dir PATH      An already-extracted RetroRewind6 folder, or a parent containing it
                                (exactly one of --retro-rewind-zip/--retro-rewind-dir is required
                                for a Retro Rewind build)
  --retro-wfc-offline-dir DIR  Offline Retro-WFC payload directory
  --skip-retro-wfc-payload     Build Retro Rewind without a Retro-WFC payload
                                (exactly one of the two Retro-WFC options above is required for a
                                Retro Rewind build)
  --deployment-target VERSION  Minimum iOS version (default: 14.0 - Dawn's std::atomic::wait usage
                                needs iOS Simulator 14.0+, which is this script's real floor; no
                                other code in this codebase is version-gated. Confirmed booting on
                                a real device at 14.8; untested below that within the 14.x/15.x
                                range)
  --bundle-id ID                 CFBundleIdentifier (default: dev.wiicompiled.game). A Retro
                                Rewind build always gets ID.retro so both can install at once.
  --bundle-name NAME             CFBundleName/CFBundleDisplayName, the home-screen icon label
                                (default: WiiCompiled). A Retro Rewind build always shows
                                "Retro Rewind" instead, so both are told apart once installed.
                                The .app folder and binary itself are always named after the CMake
                                target (WiiCompiled/RetroRewind), which this does not change.
  --bundle-version VERSION      CFBundleVersion, a build number (default: 1)
  --bundle-short-version VER    CFBundleShortVersionString, a user-facing version (default: 1.0)
  --ios-toolchain PATH          ios-cmake's ios.toolchain.cmake (default: WORKSPACE/ios.toolchain.cmake
                                if present, otherwise downloaded once into the build directory)
  --skip-ipa                    Skip zipping the built product into a .ipa; instead copy the plain
                                .app bundle straight into --output-dir (--base-output-dir too, with
                                --profile both). Not valid with --simulator, which never packages
                                an .ipa to begin with.
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
        --base-output-dir) base_output_dir=$2; shift 2 ;;
        --game) game_dump=$2; shift 2 ;;
        --simulator) run_simulator=1; shift ;;
        --profile) profile=$2; shift 2 ;;
        --retro-rewind-zip) retro_rewind_zip=$2; shift 2 ;;
        --retro-rewind-dir) retro_rewind_dir=$2; shift 2 ;;
        --retro-wfc-offline-dir) retro_wfc_offline_dir=$2; shift 2 ;;
        --skip-retro-wfc-payload) skip_retro_wfc_payload=1; shift ;;
        --deployment-target) deployment_target=$2; shift 2 ;;
        --bundle-id) bundle_id=$2; shift 2 ;;
        --bundle-name) bundle_name=$2; shift 2 ;;
        --bundle-version) bundle_version=$2; shift 2 ;;
        --bundle-short-version) bundle_short_version=$2; shift 2 ;;
        --ios-toolchain) ios_toolchain_override=$2; shift 2 ;;
        --skip-ipa) skip_ipa_packaging=1; shift ;;
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

case "$profile" in
    base|retro-rewind|both) ;;
    *) fail "--profile must be base, retro-rewind, or both" ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || fail "this script drives Xcode's iOS SDK and must run on macOS"

platform=device
if (( run_simulator )); then
    platform=simulator
    [[ "$profile" == "both" ]] && \
        fail "--simulator does not support --profile both (there would be two apps to launch) - pass --profile base or --profile retro-rewind."
    if [[ -n "$output_dir" || -n "$base_output_dir" ]]; then
        fail "--output-dir/--base-output-dir are not used with --simulator; the built app launches directly instead of being packaged."
    fi
    (( skip_ipa_packaging )) && fail "--skip-ipa is not used with --simulator; that mode never packages an .ipa to begin with."
else
    [[ -n "$output_dir" ]] || { usage; fail "--output-dir is required"; }
fi

builds_retro=0
[[ "$profile" == "retro-rewind" || "$profile" == "both" ]] && builds_retro=1
has_retro_source=0
[[ -n "$retro_rewind_zip" || -n "$retro_rewind_dir" ]] && has_retro_source=1
has_offline_retro_wfc=0
[[ -n "$retro_wfc_offline_dir" ]] && has_offline_retro_wfc=1

if [[ "$builds_retro" -eq 0 ]]; then
    if [[ "$has_retro_source" -eq 1 || "$has_offline_retro_wfc" -eq 1 || "$skip_retro_wfc_payload" -eq 1 ]]; then
        fail "Retro Rewind options are valid only for a Retro Rewind build (--profile retro-rewind or both)."
    fi
else
    if [[ -n "$retro_rewind_zip" && -n "$retro_rewind_dir" ]]; then
        fail "Choose exactly one Retro Rewind source: --retro-rewind-zip or --retro-rewind-dir."
    fi
    if [[ "$has_retro_source" -eq 0 ]]; then
        fail "--retro-rewind-zip or --retro-rewind-dir is required for a Retro Rewind build."
    fi
    if [[ "$has_offline_retro_wfc" -eq "$skip_retro_wfc_payload" ]]; then
        fail "Choose exactly one Retro-WFC mode: --retro-wfc-offline-dir or --skip-retro-wfc-payload."
    fi
fi
if [[ "$profile" == "both" && -z "$base_output_dir" ]]; then
    fail "--base-output-dir is required with --profile both; --output-dir receives the Retro Rewind product."
fi
if [[ "$profile" != "both" && -n "$base_output_dir" ]]; then
    fail "--base-output-dir is valid only with --profile both."
fi

[[ -n "$output_dir" ]] && output_dir=$(to_absolute "$output_dir")
[[ -n "$base_output_dir" ]] && base_output_dir=$(to_absolute "$base_output_dir")

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
[[ -n "$retro_rewind_zip" ]] && require_command unzip unzip
if [[ -n "$game_dump" ]]; then
    # No generic "override with --nodtool" hint (require_command's default message) - unlike this
    # script's other tools, nodtool has no prebuilt-release fetcher on macOS (NodToolProvider.cs's
    # AssetName() only knows Windows/Linux asset names), so the fix is always the same command.
    command -v nodtool >/dev/null 2>&1 || \
        fail "--game requires nodtool on PATH; install it with: cargo install --locked nodtool"
fi
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
# Always under the workspace root, never under --output-dir: --output-dir is caller-supplied and
# often not the same path across invocations (e.g. a temp/timestamped directory from a wrapper
# tool, or simply a different --output-dir per run), which would silently move the native build
# tree to a fresh, cache-less location every time - defeating the configure-fingerprint skip below
# and forcing a full reconfigure+rebuild on every single invocation regardless of whether anything
# actually changed. Keeping this at a fixed, workspace-relative path is what makes the tree
# reusable run to run; --output-dir only controls where the final packaged product lands (see
# package_built_product below), matching how --simulator's build tree already worked before
# --output-dir existed. A single tree even for --profile both (which publishes to two directories,
# --output-dir and --base-output-dir) - CMake builds both targets together, so there is only ever
# one native build to place.
build=$workspace/ios-build-$platform
translation_provenance=$generated/translation-provenance.json

# Must run before anything below extracts into $build (the Retro Rewind zip, the ios-cmake
# toolchain fetch) or writes $generated/$base_manifest_dir - otherwise a forced clean build would
# wipe out an extraction it had just done earlier in this same run, leaving e.g. retro_root
# pointing at a directory that no longer exists by the time Code.pul is read from it.
if (( force_clean_build )); then
    log_step force-clean "A clean build was requested; discarding every translation and build cache"
    rm -rf "$generated" "$base_manifest_dir" "$build"
fi

assert_file "$project" "Translation project"

# Bash port of WiiCompiled.Setup.Linux/DiscTool.cs's ValidateAndExtractAsync: same nodtool
# info/extract invocations, same game-ID-before-extracting fail-fast check, same
# main.dol/StaticR.rel sha256 pins (read here from recomp.yml, the same "literal line matching"
# approach ProjectManifest.cs and this script's entry_point parsing already use). Skips extraction
# entirely if Assets/ is already populated, so a repeat build never re-runs nodtool.
if [[ -n "$game_dump" ]]; then
    if [[ -d "$assets/DATA" && -f "$assets/main.dol" && -f "$assets/StaticR.rel" ]]; then
        log_step skip-extract-game "Assets/ already has an extracted game dump; skipping --game"
    else
        assert_file "$game_dump" "Game dump"

        pinned_game_id=$(awk '
            /^project:/ { in_project = 1; next }
            /^[A-Za-z0-9_]+:/ { in_project = 0 }
            in_project && /^[[:space:]]*game_id:/ {
                gsub(/^[[:space:]]*game_id:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
            }
        ' "$project")
        pinned_dol_sha=$(awk '
            /^inputs:/ { in_inputs = 1; next }
            /^[A-Za-z0-9_]+:/ { in_inputs = 0 }
            in_inputs && /^[[:space:]]{2}dol:[[:space:]]*$/ { in_dol = 1; next }
            in_inputs && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_dol = 0 }
            in_dol && /^[[:space:]]*sha256:/ {
                gsub(/^[[:space:]]*sha256:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
            }
        ' "$project")
        pinned_rel_sha=$(awk '
            /^inputs:/ { in_inputs = 1; next }
            /^[A-Za-z0-9_]+:/ { in_inputs = 0 }
            in_inputs && /^[[:space:]]{2}rel:[[:space:]]*$/ { in_rel = 1; next }
            in_inputs && /^[[:space:]]{2}[A-Za-z0-9_]+:[[:space:]]*$/ { in_rel = 0 }
            in_rel && /^[[:space:]]*sha256:/ {
                gsub(/^[[:space:]]*sha256:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit
            }
        ' "$project")
        [[ -n "$pinned_game_id" && -n "$pinned_dol_sha" && -n "$pinned_rel_sha" ]] || \
            fail "$project does not pin project.game_id/inputs.dol.sha256/inputs.rel.sha256; the project file is not the shape --game expects."

        log_step read-game-header "Reading the game dump's disc header"
        disc_info=$(nodtool info "$game_dump") || fail "nodtool could not read this disc image: $game_dump"
        disc_game_id=$(printf '%s\n' "$disc_info" | awk '/^Game ID: / { print $3; exit }')
        [[ "$disc_game_id" == "$pinned_game_id" ]] || \
            fail "$game_dump is '$disc_game_id', not the expected '$pinned_game_id'. Only your own legally-owned copy of that exact game/region can be used."

        log_step extract-game "Extracting the game dump into Assets/DATA"
        rm -rf "$assets/DATA"
        mkdir -p "$assets"
        nodtool extract "$game_dump" "$assets/DATA" -q

        game_dol=$assets/DATA/sys/main.dol
        game_rel=$assets/DATA/files/rel/StaticR.rel
        assert_file "$game_dol" "nodtool-extracted main.dol"
        assert_file "$game_rel" "nodtool-extracted StaticR.rel"

        game_dol_sha=$(sha256_of "$game_dol")
        [[ "$game_dol_sha" == "$pinned_dol_sha" ]] || \
            fail "main.dol sha256 mismatch: expected $pinned_dol_sha, got $game_dol_sha. This disc revision does not match what $project is pinned to."
        game_rel_sha=$(sha256_of "$game_rel")
        [[ "$game_rel_sha" == "$pinned_rel_sha" ]] || \
            fail "StaticR.rel sha256 mismatch: expected $pinned_rel_sha, got $game_rel_sha. This disc revision does not match what $project is pinned to."

        cp "$game_dol" "$assets/main.dol"
        cp "$game_rel" "$assets/StaticR.rel"
        log_step extract-game-done "Game dump validated and extracted"
    fi
fi

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

retro_root=""
if (( builds_retro )); then
    if [[ -n "$retro_rewind_zip" ]]; then
        assert_file "$retro_rewind_zip" "Retro Rewind zip"
        retro_extract_dir=$build/retro-rewind-extract
        if [[ -d "$retro_extract_dir" ]]; then
            log_step skip-extract-retro-rewind "$retro_extract_dir already exists; skipping Retro Rewind zip extraction"
        else
            log_step extract-retro-rewind "Extracting the Retro Rewind distribution"
            mkdir -p "$retro_extract_dir"
            unzip -q "$retro_rewind_zip" -d "$retro_extract_dir"
        fi
        retro_root=$(resolve_retro_rewind_dir "$retro_extract_dir")
    else
        assert_dir "$retro_rewind_dir" "Retro Rewind folder"
        retro_root=$(resolve_retro_rewind_dir "$(cd "$retro_rewind_dir" && pwd -P)")
    fi
    log_step resolve-retro-rewind "Using Retro Rewind at $retro_root"
fi

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

translation_fingerprint=$(cat "$assets/main.dol" "$assets/StaticR.rel" "$project" | shasum -a 256 | awk '{print $1}')
reuse_base=0
if [[ -f "$translation_provenance" ]]; then
    recorded=$(grep -o '"TranslationFingerprint" *: *"[^"]*"' "$translation_provenance" 2>/dev/null | sed 's/.*"\([0-9a-f]*\)"$/\1/' || true)
    if [[ "$recorded" == "$translation_fingerprint" && -f "$base_metadata" && -f "$base_manifest" ]]; then
        reuse_base=1
    fi
fi

if (( builds_retro )); then
    # The translator discovers the mod through the project file's workspace-relative profile
    # paths, and both the base and mod leg block leaf inlining at every address the profile
    # patches - so the selected Code.pul must sit at the profile's mod_root before either leg
    # runs, same as local-build.sh.
    source_pul=$retro_root/Binaries/Code.pul
    assert_file "$source_pul" "Retro Rewind Code.pul"
    staged_binaries=$workspace/PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries
    mkdir -p "$staged_binaries"
    staged_pul=$staged_binaries/Code.pul
    if [[ "$(cd "$(dirname "$source_pul")" && pwd)/$(basename "$source_pul")" != "$(cd "$(dirname "$staged_pul")" && pwd)/$(basename "$staged_pul")" ]]; then
        cp -f "$source_pul" "$staged_pul"
    fi
fi

if (( reuse_base )) && (( builds_retro )); then
    # A base tree that never saw this Code.pul would silently bake vanilla code into the modded
    # product - check-base-mod-awareness fails closed (anything but exit 0 forces a retranslation).
    retro_code_pul=$retro_root/Binaries/Code.pul
    assert_file "$retro_code_pul" "Retro Rewind Code.pul"
    pul_sha=$(sha256_of "$retro_code_pul")
    if ! grep -q "\"codePulSha256\":\"$pul_sha\"" "$base_metadata"; then
        if ! translator check-base-mod-awareness --project "$project" --profile retro-rewind \
            --translation-output-metadata "$base_metadata" --code-pul "$retro_code_pul"; then
            log_step retranslate-base "The base translation is stale; retranslating the base game for the new Code.pul"
            reuse_base=0
        fi
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

if (( builds_retro )); then
    code_pul=$retro_root/Binaries/Code.pul
    assert_file "$code_pul" "Retro Rewind Code.pul"
    retro_out=$workspace/build/mods/retro_rewind_full_cpp
    translate_mod_args=(translate-mod --project "$project" --profile retro-rewind
        --base-manifest "$base_manifest" --base-translation-output-metadata "$base_metadata"
        --code-pul "$code_pul" --mod-root "$retro_root" --mod-name "Retro Rewind"
        --region P --out "$retro_out" --prefer-cached-inputs --emit-cpp
        --threads "$translator_threads")
    if (( skip_retro_wfc_payload )); then
        translate_mod_args+=(--skip-retro-wfc)
    else
        # --retro-wfc-payload is resolved by the translator against the project's workspace_root
        # (Translator.Cli/Program.cs: `root = project?.WorkspaceRoot ?? Directory.GetCurrentDirectory()`,
        # then `Path.Combine(root, spec)`), not against this script's invoking directory - so a
        # relative --retro-wfc-offline-dir only worked by accident when run from the repo root.
        # Canonicalizing here makes it absolute, which Path.Combine passes through unchanged.
        assert_dir "$retro_wfc_offline_dir" "Offline Retro-WFC payload directory"
        offline_payload=$(cd "$retro_wfc_offline_dir" && pwd -P)/binary/payload.RMCPD00.bin
        assert_file "$offline_payload" "Offline Retro-WFC shared payload"
        translate_mod_args+=(--retro-wfc-payload "$offline_payload")
    fi
    log_step translate-mod "Translating the selected Retro Rewind Code.pul"
    translator "${translate_mod_args[@]}"
fi

log_step generate-data-init "Generating local game data initialization"
translator generate-data-init --project "$project"

shard_args=(emit-build-shards --project "$project" --base-metadata "$base_metadata"
    --base-functions-dir "$functions" --native-source-dir "$workspace/runtime/src" --out "$shards")
if (( builds_retro )); then
    retro_out=$workspace/build/mods/retro_rewind_full_cpp
    shard_args+=(--resolved-profile "$retro_out/resolved_dispatch_profile.json"
        --retro-cpp-dir "$retro_out/cpp")
fi
log_step emit-build-shards "Preparing local native build shards"
translator "${shard_args[@]}"

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

configure_args=(
    -DCMAKE_TOOLCHAIN_FILE="$ios_toolchain"
    -DPLATFORM="$cmake_platform"
    -DDEPLOYMENT_TARGET="$deployment_target"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_MAKE_PROGRAM="$ninja_bin"
    -DMKW_TRANSLATED_COMPILE_JOBS="$translated_jobs"
    -DCMAKE_SYSTEM_IGNORE_PATH=/opt/homebrew
    -DCMAKE_IGNORE_PATH=/opt/homebrew
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    "${dawn_provider_args[@]}"
    -DAURORA_SDL3_PROVIDER=vendor
)
# Re-running `cmake -S -B` unconditionally on every invocation - even against an already-configured,
# unchanged tree - regenerates build.ninja from scratch every time. Verified directly: doing that
# against an up-to-date ios-build-simulator tree made Ninja start recompiling vendored third-party
# code (cryptopp) that had not changed at all - CMake's from-scratch regeneration isn't guaranteed
# byte-identical run to run even with identical inputs, and Ninja treats any changed command line as
# reason enough to rebuild. Ninja's own CONFIGURE_DEPENDS-driven regenerate rule (the "Re-checking
# globbed directories..."/"Re-running CMake..." steps already visible in its own output, from
# runtime/CMakeLists.txt's `file(GLOB_RECURSE ... CONFIGURE_DEPENDS ...)`) is the cheap, correct way
# to catch real changes - it only actually reconfigures when a tracked input file changed. So: only
# pay for an explicit reconfigure when the exact configure inputs changed since the last one (a
# fingerprint of $configure_args, not individual CMakeCache.txt lookups - simpler than matching each
# cached variable's own :TYPE= suffix, and correct for any future flag added to this array); a
# reused cache with identical inputs skips straight to `cmake --build`, which is what invokes Ninja's
# own regenerate check.
configure_fingerprint_file=$build/.local-build-ios-configure-args
configure_fingerprint=$(printf '%s\n' "${configure_args[@]}" | shasum -a 256 | awk '{print $1}')
run_configure=1
if [[ "$keep_native_build" -eq 1 && -f "$configure_fingerprint_file" && \
    "$(cat "$configure_fingerprint_file")" == "$configure_fingerprint" ]]; then
    run_configure=0
fi

if (( run_configure )); then
    log_step configure-native "Configuring the iOS toolchain ($platform)"
    # --fresh (not a plain re-run on the existing cache): ios.toolchain.cmake computes
    # CMAKE_<LANG>_FLAGS by reading and appending onto whatever's already cached, rather than
    # overwriting it - so reconfiguring an existing build directory *without* --fresh leaves every
    # prior configure's -target flag sitting in CMAKE_C_FLAGS/CMAKE_CXX_FLAGS/etc alongside the new
    # one. Harmless if DEPLOYMENT_TARGET/PLATFORM never change (every accumulated copy agrees), but
    # verified directly to silently break the moment they do: changing --deployment-target on a
    # tree that had already been configured at the old value left both old and new -target flags on
    # the same command line, and clang's last-flag-wins rule picked whichever was stale, so the
    # build kept the old target regardless of what this script or Info.plist claimed. --fresh
    # forces CMake to discard CMakeCache.txt/CMakeFiles and recompute from scratch, same as the
    # rm -rf a few lines up already does for a build directory that does not belong to this
    # workspace at all - this only runs on the same (already rare, fingerprint-gated) path that
    # regenerates build.ninja from scratch anyway, so it does not add a cost the comment above this
    # block hasn't already accepted for that path.
    "$cmake_bin" --fresh -S "$workspace/runtime" -B "$build" -G Ninja "${configure_args[@]}"
    printf '%s' "$configure_fingerprint" > "$configure_fingerprint_file"
else
    log_step configure-native-skip "Configure inputs unchanged for ($platform); reusing the existing CMake configuration"
fi

case "$profile" in
    base) targets=(WiiCompiled) ;;
    retro-rewind) targets=(RetroRewind) ;;
    both) targets=(WiiCompiled RetroRewind) ;;
esac
build_args=(--build "$build")
for target in "${targets[@]}"; do build_args+=(--target "$target"); done
build_args+=(--parallel "$global_jobs")
log_step compile "Compiling ${targets[*]} for iOS ($platform)"
"$cmake_bin" "${build_args[@]}"

# ---------------------------------------------------------------------------
# Package: patch the placeholder Info.plist ios.toolchain.cmake generates, bundle the extracted
# game data into the app (there is no on-device way to point a fresh install at a dvd_root outside
# its own sandboxed container - see runtime_config.h's ResolvedDvdRoot), and either zip into an
# unsigned .ipa or (--simulator) install + launch it directly. No codesign step anywhere in this
# script, deliberately - see the file header.
# ---------------------------------------------------------------------------

case "$platform" in
    device) supported_platform=iPhoneOS; dt_platform_name=iphoneos ;;
    simulator) supported_platform=iPhoneSimulator; dt_platform_name=iphonesimulator ;;
esac
dol_sha=$(sha256_of "$assets/main.dol")
rel_sha=$(sha256_of "$assets/StaticR.rel")

resolve_target_identity() {
    # $1 = "base" or "retro-rewind". Sets this_bundle_id/this_bundle_name - deliberately not
    # `local`, since both prepare_app_bundle's Info.plist and launch_in_simulator's simctl launch
    # need the same values. RetroRewind needs a distinct CFBundleIdentifier from the base build so
    # both can be installed at once, the same way they are two separate products on Windows/Linux -
    # and a distinct SpringBoard name/icon label, so the two are told apart once both are installed.
    this_bundle_id=$bundle_id
    this_bundle_name=$bundle_name
    if [[ "$1" == "retro-rewind" ]]; then
        this_bundle_id="$bundle_id.retro"
        this_bundle_name="Retro Rewind"
    fi
}

prepare_app_bundle() {
    # $1 = CMake target name (WiiCompiled/RetroRewind - this, not --bundle-name, is what the
    # actual .app folder and the binary inside it are named; ios.toolchain.cmake names the bundle
    # after the CMake target regardless of what Info.plist says). $2 = "base" or "retro-rewind".
    # Leaves the patched .app at $build/$target.app - shared by IPA packaging and --simulator.
    local target=$1 provenance_profile=$2
    local app_bundle=$build/$target.app
    assert_dir "$app_bundle" "Built .app bundle"
    resolve_target_identity "$provenance_profile"

    # UILaunchScreen (even empty) is what tells iOS this app declares a modern launch screen at
    # all; without it (or a real .storyboard, which this script does not ship), iOS renders the
    # app in a legacy compatibility mode sized for pre-iPhone-6 screens and letterboxes/scales it
    # up instead of using the device's full native resolution.
    log_step "patch-info-plist-$target" "Writing $target's Info.plist"
    cat > "$app_bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>$target</string>
	<key>CFBundleIdentifier</key>
	<string>$this_bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$this_bundle_name</string>
	<key>CFBundleDisplayName</key>
	<string>$this_bundle_name</string>
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
	<key>UILaunchScreen</key>
	<dict/>
	<key>GCSupportsGameMode</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
</dict>
</plist>
PLIST

    log_step "bundle-data-$target" "Bundling the extracted game data into $target"
    rsync -a --delete "$assets/DATA/" "$app_bundle/DATA/"

    if [[ "$provenance_profile" == "retro-rewind" ]]; then
        # Code.pul alone only gets the compiled function overrides - Retro Rewind also needs its
        # menu archives/karts/drivers/courses live at runtime via a filesystem overlay (see
        # riivolution.cpp's RiivoDiscoverRoots). Windows/Linux point that overlay straight at the
        # user's own RetroRewind6 folder; there is no such persistent external path on iOS, so this
        # bundles the whole folder into the .app instead, next to the executable, where
        # RuntimeNandPath::RetroRewindOverlayPath() (nand_path.h) auto-discovers it.
        log_step "bundle-retro-overlay-$target" "Bundling the Retro Rewind overlay into $target"
        rsync -a --delete "$retro_root/" "$app_bundle/RetroRewind6/"
    fi
}

package_built_product() {
    # $1 = CMake target name, $2 = output directory, $3 = "base" or "retro-rewind" (also the
    # provenance file's Profile field).
    local target=$1 destination=$2 provenance_profile=$3
    prepare_app_bundle "$target" "$provenance_profile"
    local app_bundle=$build/$target.app
    resolve_target_identity "$provenance_profile"
    mkdir -p "$destination"

    local product_path
    if (( skip_ipa_packaging )); then
        # --skip-ipa: not every install path needs a .ipa specifically - some sideloading
        # tools/local Xcode device installs take a plain .app bundle directly, so zipping one into
        # Payload/*.ipa just to have the caller unzip it again is wasted work on that path. rsync
        # (not cp -R) so re-running over a stale .app already at $destination from a previous
        # build doesn't leave orphaned files behind, matching why prepare_app_bundle's own DATA/
        # bundling above uses --delete.
        log_step "package-app-$target" "Copying $target.app into $destination (skipping .ipa packaging)"
        local dest_app=$destination/$target.app
        rm -rf "$dest_app"
        rsync -a --delete "$app_bundle/" "$dest_app/"
        product_path=$dest_app
    else
        log_step "package-ipa-$target" "Packaging $target as an unsigned .ipa"
        local payload_dir=$build/Payload
        rm -rf "$payload_dir"
        mkdir -p "$payload_dir"
        cp -R "$app_bundle" "$payload_dir/"
        local ipa_path=$destination/$target.ipa
        rm -f "$ipa_path"
        (cd "$build" && zip -r -X -y "$ipa_path" "Payload") >/dev/null
        rm -rf "$payload_dir"
        product_path=$ipa_path
    fi

    local code_pul_sha=null
    if [[ "$provenance_profile" == "retro-rewind" ]]; then
        code_pul_sha=\"$(sha256_of "$retro_root/Binaries/Code.pul")\"
    fi
    local built_utc
    built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$destination/local-build-ios.json" <<JSON
{
  "SchemaVersion": 1,
  "Profile": "$provenance_profile",
  "Platform": "$platform",
  "DeploymentTarget": "$deployment_target",
  "BundleIdentifier": "$this_bundle_id",
  "BuiltUtc": "$built_utc",
  "DolSha256": "$dol_sha",
  "RelSha256": "$rel_sha",
  "CodePulSha256": $code_pul_sha,
  "Signed": false
}
JSON

    echo "MKWCBUILD:OUTPUT=$product_path"
}

find_or_boot_simulator() {
    # Prefers whatever is already booted (fast, and respects a device the caller picked by hand);
    # otherwise boots the first available iPhone simulator. Plain-text simctl output, not `-j`, to
    # avoid adding a jq dependency for the one field this needs - same tradeoff local-build-ios.sh
    # already makes for `nodtool info` elsewhere in this script.
    #
    # The caller captures this function's stdout as its return value (device_udid=$(...)), so
    # every other command's own output - log_step included, which is stdout by design elsewhere in
    # this script, see its own comment - is redirected to stderr here to keep that channel clean.
    local udid
    udid=$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-Fa-f-]{36}')
    if [[ -n "$udid" ]]; then
        printf '%s\n' "$udid"
        return
    fi

    log_step simulator-boot "No booted simulator found; booting one" >&2
    udid=$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE '[0-9A-Fa-f-]{36}')
    [[ -n "$udid" ]] || fail "no available iPhone simulator found (xcrun simctl list devices available) - create one in Xcode first"
    xcrun simctl boot "$udid" >&2
    open -a Simulator >&2
    xcrun simctl bootstatus "$udid" -b >&2
    printf '%s\n' "$udid"
}

launch_in_simulator() {
    # $1 = CMake target name, $2 = "base" or "retro-rewind".
    local target=$1 provenance_profile=$2
    prepare_app_bundle "$target" "$provenance_profile"
    local app_bundle=$build/$target.app
    resolve_target_identity "$provenance_profile"

    local device_udid
    device_udid=$(find_or_boot_simulator)
    log_step simulator-install "Installing $target into simulator $device_udid"
    xcrun simctl install "$device_udid" "$app_bundle"
    log_step simulator-launch "Launching $target - streaming its console (Ctrl+C to stop)"
    xcrun simctl launch --console "$device_udid" "$this_bundle_id"
}

if (( run_simulator )); then
    case "$profile" in
        retro-rewind) launch_in_simulator RetroRewind retro-rewind ;;
        base) launch_in_simulator WiiCompiled base ;;
    esac
    exit 0
fi

case "$profile" in
    both)
        package_built_product WiiCompiled "$base_output_dir" base
        package_built_product RetroRewind "$output_dir" retro-rewind
        ;;
    retro-rewind)
        package_built_product RetroRewind "$output_dir" retro-rewind
        ;;
    base)
        package_built_product WiiCompiled "$output_dir" base
        ;;
esac
