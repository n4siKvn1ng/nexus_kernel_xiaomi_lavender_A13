#!/usr/bin/env bash

set -euo pipefail

# Local-only build script for Redmi Note 7 (lavender).
# Target ROM: CherishOS 4.8 UNOFFICIAL, Android 13, EAS QTI.

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
DIST_DIR="${DIST_DIR:-$KERNEL_DIR}"

MODEL="${MODEL:-Redmi Note 7}"
DEVICE="${DEVICE:-lavender}"
ROM_NAME="${ROM_NAME:-CherishOS}"
ROM_VERSION="${ROM_VERSION:-4.8}"
ANDROID_VERSION="${ANDROID_VERSION:-13}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-EAS-QTI}"
DEFCONFIG="${DEFCONFIG:-lavender_defconfig}"
# Keep this empty by default: lavender_defconfig already sets CONFIG_LOCALVERSION,
# and UTS_RELEASE must stay within 64 characters.
LOCALVERSION="${LOCALVERSION:-}"

IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
ZIP_BASENAME="${ZIP_BASENAME:-Nexus-${KERNEL_FLAVOR}-${ROM_NAME}-${ROM_VERSION}-Android${ANDROID_VERSION}-${DEVICE}}"
BUILD_DATE="$(date +"%Y%m%d-%H%M")"
FINAL_ZIP="${FINAL_ZIP:-${ZIP_BASENAME}-${BUILD_DATE}.zip}"

CLANG_DIR="${CLANG_DIR:-}"
GCC64_DIR="${GCC64_DIR:-}"
GCC32_DIR="${GCC32_DIR:-}"
AK3_DIR="${AK3_DIR:-$KERNEL_DIR/AnyKernel3}"
JOBS="${JOBS:-$(nproc --all)}"
VERBOSE="${VERBOSE:-0}"
CLEAN="${CLEAN:-0}"
PACKAGE="${PACKAGE:-1}"
CLONE_MISSING="${CLONE_MISSING:-1}"
CLANG_REPO="${CLANG_REPO:-https://gitlab.com/Project-Nexus/nexus-clang.git}"
CLANG_BRANCH="${CLANG_BRANCH:-nexus-14}"
AK3_REPO="${AK3_REPO:-https://github.com/Projects-aRise/AnyKernel3}"
AK3_BRANCH="${AK3_BRANCH:-}"

log() {
	printf '[build] %s\n' "$*"
}

die() {
	printf '[build] error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --clean              Remove out/ before building
  --no-clone           Do not clone missing clang/AnyKernel3 dependencies
  --no-zip             Build Image.gz-dtb only, skip AnyKernel packaging
  --clang DIR          Use local clang directory
  --gcc64 DIR          Use local aarch64 GCC directory
  --gcc32 DIR          Use local arm32 GCC directory
  --ak3 DIR            Use local AnyKernel3 directory
  --jobs N             Parallel build jobs
  --defconfig NAME     Kernel defconfig
  -h, --help           Show this help

Environment overrides:
  CLANG_DIR, GCC64_DIR, GCC32_DIR, AK3_DIR, OUT_DIR, DIST_DIR, JOBS,
  DEFCONFIG, LOCALVERSION, FINAL_ZIP, PACKAGE, VERBOSE, CLONE_MISSING,
  CLANG_REPO, CLANG_BRANCH, AK3_REPO, AK3_BRANCH

By default this script clones missing dependencies, but all build outputs stay
local. Use --no-clone or CLONE_MISSING=0 for offline-only builds. It never
uploads build results.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--clean)
			CLEAN=1
			;;
		--no-clone)
			CLONE_MISSING=0
			;;
		--no-zip)
			PACKAGE=0
			;;
		--clang)
			CLANG_DIR="${2:?missing directory for --clang}"
			shift
			;;
		--gcc64)
			GCC64_DIR="${2:?missing directory for --gcc64}"
			shift
			;;
		--gcc32)
			GCC32_DIR="${2:?missing directory for --gcc32}"
			shift
			;;
		--ak3)
			AK3_DIR="${2:?missing directory for --ak3}"
			shift
			;;
		--jobs|-j)
			JOBS="${2:?missing value for --jobs}"
			shift
			;;
		--defconfig)
			DEFCONFIG="${2:?missing value for --defconfig}"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
	shift
done

pick_first_dir() {
	for dir in "$@"; do
		if [ -n "$dir" ] && [ -d "$dir" ]; then
			printf '%s\n' "$dir"
			return 0
		fi
	done
	return 1
}

tool_exists() {
	command -v "$1" >/dev/null 2>&1
}

clone_repo() {
	local repo="$1"
	local dest="$2"
	local branch="${3:-}"
	local args=(clone --depth=1)

	command -v git >/dev/null 2>&1 || die "git command not found"

	if [ -n "$branch" ]; then
		args+=(-b "$branch")
	fi

	args+=("$repo" "$dest")
	log "cloning $repo -> $dest"
	git "${args[@]}"
}

setup_toolchain() {
	if [ -z "$CLANG_DIR" ]; then
		CLANG_DIR="$(pick_first_dir \
			"$KERNEL_DIR/clang" \
			"$KERNEL_DIR/../toolchains/clang-r450784d" \
			"$KERNEL_DIR/../toolchains/clang-r498229b" \
			"")" || true
	fi

	if [ -z "$CLANG_DIR" ] && [ "$CLONE_MISSING" = "1" ]; then
		CLANG_DIR="$KERNEL_DIR/clang"
		clone_repo "$CLANG_REPO" "$CLANG_DIR" "$CLANG_BRANCH"
	fi

	if [ -z "$GCC64_DIR" ]; then
		GCC64_DIR="$(pick_first_dir \
			"$KERNEL_DIR/gcc64" \
			"$KERNEL_DIR/../toolchains/gcc64" \
			"")" || true
	fi

	if [ -z "$GCC32_DIR" ]; then
		GCC32_DIR="$(pick_first_dir \
			"$KERNEL_DIR/gcc32" \
			"$KERNEL_DIR/../toolchains/gcc32" \
			"")" || true
	fi

	[ -n "$CLANG_DIR" ] || die "local clang not found. Pass --clang DIR or set CLANG_DIR."
	[ -x "$CLANG_DIR/bin/clang" ] || die "clang not executable: $CLANG_DIR/bin/clang"

	export PATH="$CLANG_DIR/bin:$PATH"

	if [ -n "$GCC64_DIR" ]; then
		export PATH="$GCC64_DIR/bin:$PATH"
	fi

	if [ -n "$GCC32_DIR" ]; then
		export PATH="$GCC32_DIR/bin:$PATH"
	fi

	export KBUILD_COMPILER_STRING
	KBUILD_COMPILER_STRING="$("$CLANG_DIR/bin/clang" --version | head -n 1 | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"

	if tool_exists aarch64-linux-android-gcc; then
		CROSS_COMPILE_PREFIX="aarch64-linux-android-"
	elif tool_exists aarch64-linux-gnu-gcc; then
		CROSS_COMPILE_PREFIX="aarch64-linux-gnu-"
	else
		CROSS_COMPILE_PREFIX="aarch64-linux-android-"
		log "warning: aarch64 GCC prefix not found in PATH; relying on clang/LLVM"
	fi

	if tool_exists arm-linux-androideabi-gcc; then
		CROSS_COMPILE_ARM32_PREFIX="arm-linux-androideabi-"
	elif tool_exists arm-linux-gnueabi-gcc; then
		CROSS_COMPILE_ARM32_PREFIX="arm-linux-gnueabi-"
	elif tool_exists arm-eabi-gcc; then
		CROSS_COMPILE_ARM32_PREFIX="arm-eabi-"
	else
		CROSS_COMPILE_ARM32_PREFIX=""
		log "warning: arm32 GCC prefix not found; CROSS_COMPILE_ARM32 will be omitted"
	fi
}

make_common_args() {
	MAKE_ARGS=(
		O="$OUT_DIR"
		ARCH=arm64
		SUBARCH=arm64
		LOCALVERSION="$LOCALVERSION"
		CC=clang
		CLANG_TRIPLE=aarch64-linux-gnu-
		CROSS_COMPILE="$CROSS_COMPILE_PREFIX"
		LLVM=1
		LLVM_IAS=0
		LD=ld.lld
		AR=llvm-ar
		NM=llvm-nm
		OBJCOPY=llvm-objcopy
		OBJDUMP=llvm-objdump
		STRIP=llvm-strip
		READELF=llvm-readelf
		OBJSIZE=llvm-size
		V="$VERBOSE"
	)

	if [ -n "$CROSS_COMPILE_ARM32_PREFIX" ]; then
		MAKE_ARGS+=(CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32_PREFIX")
	fi
}

build_kernel() {
	cd "$KERNEL_DIR"

	if [ "$CLEAN" = "1" ]; then
		log "cleaning $OUT_DIR"
		rm -rf "$OUT_DIR"
	fi

	mkdir -p "$OUT_DIR" "$DIST_DIR"

	log "target: ${ROM_NAME} ${ROM_VERSION} UNOFFICIAL | Android ${ANDROID_VERSION}"
	log "device: $MODEL ($DEVICE)"
	log "flavor: $KERNEL_FLAVOR"
	log "defconfig: $DEFCONFIG"
	log "compiler: $KBUILD_COMPILER_STRING"

	make "${MAKE_ARGS[@]}" "$DEFCONFIG"
	make -j"$JOBS" "${MAKE_ARGS[@]}" 2>&1 | tee "$DIST_DIR/build.log"

	[ -f "$IMAGE" ] || die "kernel image not found: $IMAGE"
	cp "$IMAGE" "$DIST_DIR/Image.gz-dtb"
	log "image: $DIST_DIR/Image.gz-dtb"
}

package_kernel() {
	if [ "$PACKAGE" != "1" ]; then
		log "packaging skipped (--no-zip)"
		return 0
	fi

	if [ ! -d "$AK3_DIR" ] && [ "$CLONE_MISSING" = "1" ]; then
		clone_repo "$AK3_REPO" "$AK3_DIR" "$AK3_BRANCH"
	fi

	if [ ! -d "$AK3_DIR" ]; then
		log "AnyKernel3 not found at $AK3_DIR"
		log "zip skipped; set AK3_DIR, pass --ak3 DIR, or enable cloning"
		return 0
	fi

	command -v zip >/dev/null 2>&1 || die "zip command not found"

	PACK_DIR="$OUT_DIR/anykernel"
	rm -rf "$PACK_DIR"
	mkdir -p "$PACK_DIR"
	cp -a "$AK3_DIR"/. "$PACK_DIR"/
	cp "$IMAGE" "$PACK_DIR/Image.gz-dtb"

	(
		cd "$PACK_DIR"
		rm -rf .git .github
		zip -r9 "$DIST_DIR/$FINAL_ZIP" ./*
	)

	MD5CHECK="$(md5sum "$DIST_DIR/$FINAL_ZIP" | cut -d' ' -f1)"
	log "zip: $DIST_DIR/$FINAL_ZIP"
	log "md5: $MD5CHECK"
}

export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-local}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-$(id -un 2>/dev/null || printf local)}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"

START="$(date +%s)"
setup_toolchain
make_common_args
build_kernel
package_kernel
END="$(date +%s)"

log "done in $(( (END - START) / 60 ))m $(( (END - START) % 60 ))s"
