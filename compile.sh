#!/bin/bash
#
# compile.sh — Capybara GKI kernel compiler script
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly KERNEL_DIR="$(pwd)"
readonly DIR="$(readlink -f .)"
readonly KERNEL_DEFCONFIG="gki_defconfig"
readonly CLANG_DIR="${KERNEL_DIR}/toolchains/clang"
readonly OUT_DIR="${KERNEL_DIR}/out"
readonly ZIMAGE_DIR="${OUT_DIR}/arch/arm64/boot"
readonly ANYKERNEL_SRC_DIR="${KERNEL_DIR}/anykernel"
readonly JOBS="$(nproc --all)"

ZIP_PREFIX="rethinking-GKI"
BUILD_START="$(date +%s)"
TEMP_ANY_KERNEL_DIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
INFO()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
OK()    { echo -e "\e[1;32m[ OK ]\e[0m  $*"; }
WARN()  { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
ERROR() { echo -e "\e[1;31m[FAIL]\e[0m  $*" >&2; }

DIE() {
    ERROR "$*"
    exit 1
}

CLEANUP() {
    if [ -n "${TEMP_ANY_KERNEL_DIR}" ] && [ -d "${TEMP_ANY_KERNEL_DIR}" ]; then
        rm -rf "${TEMP_ANY_KERNEL_DIR}"
    fi
}
trap CLEANUP EXIT

SET_CONFIG() {
    local key="$1"; local val="$2"
    if [ "$val" = "y" ]; then sed -i "s/^# $key is not set/$key=y/; s/^$key=.*/$key=y/" "arch/arm64/configs/$KERNEL_DEFCONFIG"
    else sed -i "s/^$key=.*/# $key is not set/" "arch/arm64/configs/$KERNEL_DEFCONFIG"; fi
}

if [ "${1:-}" == "KSU" ]; then
    SET_CONFIG CONFIG_KSU y
else
    SET_CONFIG CONFIG_KSU n
fi

# ---------------------------------------------------------------------------
# Toolchain setup
# ---------------------------------------------------------------------------
CHECK_CLANG() {
    if [ -d "${CLANG_DIR}" ] && [ -x "${CLANG_DIR}/bin/clang" ]; then
        export PATH="${CLANG_DIR}/bin:${PATH}"
        KBUILD_COMPILER_STRING="$("${CLANG_DIR}/bin/clang" --version \
            | head -n 1 \
            | perl -pe 's/\(http.*?\)//gs' \
            | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
        export KBUILD_COMPILER_STRING
        INFO "Found existing Clang: ${KBUILD_COMPILER_STRING}"
        return 0
    fi
    return 1
}

DOWNLOAD_CLANG() {
    local url="$1"
    local archive="${KERNEL_DIR}/clang.tar.gz"

    mkdir -p "${CLANG_DIR}"
    wget -q --show-progress -O "${archive}" "${url}" || DIE "Download failed: ${url}"
    tar -xf "${archive}" -C "${CLANG_DIR}" || DIE "Failed to extract Clang archive"
    rm -f "${archive}"
}

INSTALL_CLANG() {
    WARN "No valid Clang found. Please choose a toolchain:"
    echo "  1) AOSP r510928"
    echo "  2) Zyc Clang 23.0"
    read -rp "Choice [1-2]: " clang_choice

    case "${clang_choice}" in
        1)
            DOWNLOAD_CLANG "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android15-release/clang-r510928.tar.gz"
            ;;
        2)
            DOWNLOAD_CLANG "https://github.com/ZyCromerZ/Clang/releases/download/23.0.0git-20260130-release/Clang-23.0.0git-20260130.tar.gz"
            ;;
        *)
            DIE "Invalid choice."
            ;;
    esac

    CHECK_CLANG || DIE "Clang installation failed."
}

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
BUILD_KERNEL() {
    export ARCH=arm64
    export SUBARCH=arm64

    INFO "Generating kernel config (${KERNEL_DEFCONFIG})..."
    make O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" "${KERNEL_DEFCONFIG}" \
        || DIE "Failed to generate defconfig"

    INFO "Starting kernel compilation with ${JOBS} job(s)..."
    make -j"${JOBS}" O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" \
        || DIE "Kernel build failed"

    OK "Kernel compilation finished."
}

CLEAN_OLD_ZIPS() {
    INFO "Cleaning up old zip files..."
    find "${KERNEL_DIR}" -maxdepth 1 -type f -name "${ZIP_PREFIX}-*.zip" -exec rm -v {} \;
}

PACKAGE_KERNEL() {
    [ -d "${ANYKERNEL_SRC_DIR}" ] || INFO "Clone AnyKernel3 repo..." && rm -rf "${ANYKERNEL_SRC_DIR}" && git clone https://github.com/xiaomi-klee-devs/android_AnyKernel3.git "${ANYKERNEL_SRC_DIR}"

    local time
    time="$(date "+%Y%m%d-%H%M%S")"
    TEMP_ANY_KERNEL_DIR="$(mktemp -d "${KERNEL_DIR}/anykernel_temp.XXXXXX")"

    INFO "Preparing AnyKernel3..."
    cp -r "${ANYKERNEL_SRC_DIR}/." "${TEMP_ANY_KERNEL_DIR}/"

    local kernel_image=""
    for candidate in "Image.lz4" "Image.gz" "Image"; do
        if [ -f "${ZIMAGE_DIR}/${candidate}" ]; then
            kernel_image="${ZIMAGE_DIR}/${candidate}"
            break
        fi
    done
    [ -n "${kernel_image}" ] || DIE "No kernel image output found in ${ZIMAGE_DIR}"

    cp -v "${kernel_image}" "${TEMP_ANY_KERNEL_DIR}/"

    INFO "Creating zip package..."
    ZIP_NAME="${ZIP_PREFIX}-${time}.zip"
    (
        cd "${TEMP_ANY_KERNEL_DIR}"
        zip -r9 "${KERNEL_DIR}/${ZIP_NAME}" ./* > /dev/null
    )

    OK "Zip package created: ${ZIP_NAME}"
}

PRINT_SUMMARY() {
    local build_end diff
    build_end="$(date +%s)"
    diff=$((build_end - BUILD_START))

    echo -e "\n=========================================="
    echo "Build finished in $((diff / 60))m $((diff % 60))s"
    echo "Final zip : ${KERNEL_DIR}/${ZIP_NAME}"
    echo "Zip size  : $(du -h "${KERNEL_DIR}/${ZIP_NAME}" | cut -f1)"
    echo "=========================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MAIN() {
    CHECK_CLANG || INSTALL_CLANG

    BUILD_KERNEL
    CLEAN_OLD_ZIPS
    PACKAGE_KERNEL
    PRINT_SUMMARY
}

rm -rf compile.log "${OUT_DIR}" "${TEMP_ANY_KERNEL_DIR}" KernelSU
git restore . && git clean -fd
MAIN "$@" | tee compile.log
