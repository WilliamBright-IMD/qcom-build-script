#!/bin/bash
#
# build.sh - Build and deploy kernel for Qualcomm QCS8550 IMDT SBC
#
# Usage: ./build.sh [KERNEL_DIR]
#
#   KERNEL_DIR  Path to the kernel source directory.
#               Defaults to 'imdt-qcom-oss-linux-dev'.
#               If the directory does not exist, the repo will be cloned
#               from git@github.com:imd-tec/imdt-qcom-oss-linux-dev.git
#
# This script will:
#   1. Clone the kernel repo if not already present
#   2. Merge defconfig with qcom and BSP config fragments
#   3. Build the kernel Image, DTBs and modules
#   4. Deploy the artifacts to the target device via ADB
#
set -e

KERNEL_DIR=${1:-imdt-qcom-oss-linux-dev}
INSTALL_MOD_PATH="$KERNEL_DIR/modules_out"
EFI_PART=/boot/
APPLY_DISPLAY_OVERLAY=true

if [ ! -d "$KERNEL_DIR" ]; then
  echo "=== Cloning kernel repo ==="
  git clone git@github.com:imd-tec/imdt-qcom-oss-linux-dev.git "$KERNEL_DIR"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$KERNEL_DIR"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Configure
echo "=== Configuring kernel ==="

scripts/kconfig/merge_config.sh \
  arch/arm64/configs/defconfig \
  arch/arm64/configs/prune.config \
  arch/arm64/configs/qcom.config \
  "$SCRIPT_DIR/bsp-additions.config"

# Build kernel, DTBs and modules
echo "=== Building kernel, DTBs and modules ==="
make -j$(nproc) Image dtbs modules

# Install modules to a temporary directory
echo "=== Installing modules locally ==="
rm -rf "$INSTALL_MOD_PATH"
make INSTALL_MOD_PATH="$INSTALL_MOD_PATH" modules_install
adb wait-for-device
# Mount the EFI partition
echo "=== Mounting EFI partition ==="

# Push via ADB
echo "=== Pushing kernel Image ==="
adb push arch/arm64/boot/Image ${EFI_PART}/

echo "=== Pushing DTB ==="
adb shell "mkdir -p ${EFI_PART}/dtb/qcom/"
adb pull ${EFI_PART}/dtb/qcom/ /tmp/
adb push arch/arm64/boot/dts/qcom/qcs8550-imdt-*.dtb* ${EFI_PART}/
if [ -n "$2" ]; then
  echo "Overriding DTB with ${2}"
  adb push arch/arm64/boot/dts/qcom/${2} /boot/qcs8550-imdt-sbc.dtb
fi

echo "=== Pushing kernel modules ==="
adb push "$INSTALL_MOD_PATH"/lib/modules/* /lib/modules/

# Clean up local modules
rm -rf "$INSTALL_MOD_PATH"

adb shell sync
adb shell umount ${EFI_PART}
adb shell sync

echo "=== Done ==="
