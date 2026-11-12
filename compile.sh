#!/bin/bash
#
# compile.sh — Capybara GKI kernel compiler script
# Usage: ./compile.sh [noksu|ksu|both|auto] DATE ARTIFACT_DIR
#
set -euo pipefail

readonly KERNEL_DIR="$(pwd)"
readonly DIR="$(readlink -f .)"
readonly MODE="${1:-auto}"
readonly DATE="${2:-$(date +%Y%m%d%H%M)}"
readonly ARTIFACT="${3:-${KERNEL_DIR}/artifact}"
readonly CLANG_DIR="${KERNEL_DIR}/toolchains/clang"
readonly OUT_DIR="${KERNEL_DIR}/out"
readonly ZIMAGE_DIR="${OUT_DIR}/arch/arm64/boot"
readonly ANYKERNEL_SRC_DIR="${KERNEL_DIR}/anykernel"
readonly JOBS="$(nproc --all)"

ZIP_PREFIX="rethinking-GKI"
BUILD_START="$(date +%s)"
TEMP_ANY_KERNEL_DIR=""

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

BUILD_VARIANT() {
    local variant="$1"
    local zip_tag="$2"

    export ARCH=arm64
    export SUBARCH=arm64

    INFO "Generating kernel config (gki_defconfig) for variant: ${variant}..."
    make O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" gki_defconfig \
        || DIE "Failed to generate defconfig for ${variant}"

    local has_ksu=false
    if grep -qE '^CONFIG_KSU=y' "${OUT_DIR}/.config"; then
        has_ksu=true
        INFO "CONFIG_KSU=y detected in .config"
    else
        INFO "CONFIG_KSU not found in .config"
    fi

    if [[ "${variant}" == "ksu" && "${has_ksu}" == false ]]; then
        INFO "Enabling CONFIG_KSU explicitly for KSU variant..."
        scripts/config --enable CONFIG_KSU --file "${OUT_DIR}/.config"
        make O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig \
            || DIE "Failed olddefconfig after enabling CONFIG_KSU"
    fi

    if [[ "${variant}" == "noksu" && "${has_ksu}" == true ]]; then
        INFO "Disabling CONFIG_KSU explicitly for NoKSU variant..."
        scripts/config --disable CONFIG_KSU --file "${OUT_DIR}/.config"
        make O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig \
            || DIE "Failed olddefconfig after disabling CONFIG_KSU"
    fi

    INFO "Starting kernel compilation with ${JOBS} job(s) (variant: ${variant})..."
    make -j"${JOBS}" O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" \
        || DIE "Kernel build failed for ${variant}"

    OK "Kernel compilation finished (variant: ${variant})."

    local kernel_image=""
    for candidate in "Image.lz4" "Image.gz" "Image"; do
        if [ -f "${ZIMAGE_DIR}/${candidate}" ]; then
            kernel_image="${ZIMAGE_DIR}/${candidate}"
            break
        fi
    done
    [ -n "${kernel_image}" ] || DIE "No kernel image output found in ${ZIMAGE_DIR}"

    local time
    time="$(date "+%Y%m%d-%H%M%S")"
    TEMP_ANY_KERNEL_DIR="$(mktemp -d "${KERNEL_DIR}/anykernel_temp.XXXXXX")"

    INFO "Preparing AnyKernel3..."
    [ -d "${ANYKERNEL_SRC_DIR}" ] || git clone https://github.com/xiaomi-klee-devs/android_AnyKernel3.git "${ANYKERNEL_SRC_DIR}"
    cp -r "${ANYKERNEL_SRC_DIR}/." "${TEMP_ANY_KERNEL_DIR}/"

    cp -v "${kernel_image}" "${TEMP_ANY_KERNEL_DIR}/"

    local zip_name="${ZIP_PREFIX}-${zip_tag}-${time}.zip"
    INFO "Creating zip package: ${zip_name}..."
    (
        cd "${TEMP_ANY_KERNEL_DIR}"
        zip -r9 "${ARTIFACT}/${zip_name}" ./* > /dev/null
    )

    OK "Zip package created: ${zip_name}"
}

MAIN() {
    CHECK_CLANG || {
        DOWNLOAD_CLANG \
            "https://github.com/ZyCromerZ/Clang/releases/download/23.0.0git-20260130-release/Clang-23.0.0git-20260130.tar.gz"
        CHECK_CLANG || DIE "Clang not found even after download — check archive layout"
    }

    mkdir -p "${ARTIFACT}"

    local variants=()
    case "${MODE}" in
        both)
            variants=("noksu" "ksu")
            ;;
        ksu)
            variants=("ksu")
            ;;
        noksu|*)
            variants=("noksu")
            ;;
    esac

    if [[ "${MODE}" == "auto" ]]; then
        make O="${OUT_DIR}" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" gki_defconfig >/dev/null 2>&1 || true
        if grep -qE '^CONFIG_KSU=y' "${OUT_DIR}/.config"; then
            INFO "Auto-detected CONFIG_KSU=y — building both noksu and ksu"
            variants=("noksu" "ksu")
        else
            INFO "Auto-detected no CONFIG_KSU — building noksu only"
            variants=("noksu")
        fi
    fi

    for variant in "${variants[@]}"; do
        BUILD_VARIANT "${variant}" "${variant}"
    done

    PRINT_SUMMARY
}

PRINT_SUMMARY() {
    local build_end diff
    build_end="$(date +%s)"
    diff=$((build_end - BUILD_START))

    echo -e "\n=========================================="
    echo "Build finished in $((diff / 60))m $((diff % 60))s"
    echo "Artifact dir: ${ARTIFACT}"
    ls -1 "${ARTIFACT}" 2>/dev/null || true
    echo "=========================================="
}

CLEAN_OLD_ZIPS() {
    INFO "Cleaning up old zip files..."
    find "${KERNEL_DIR}" -maxdepth 1 -type f -name "${ZIP_PREFIX}-*.zip" -exec rm -v {} \;
}

rm -rf compile.log "${OUT_DIR}"
MAIN "$@" | tee compile.log
