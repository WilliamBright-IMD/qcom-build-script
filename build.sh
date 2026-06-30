#!/bin/bash
#
# build.sh - Build and deploy kernel for Qualcomm QCS8550 IMDT SBC
#
# Usage: ./build.sh [--via-pi | --via-ssh] [--dtb-only] [KERNEL_DIR] [DTB_OVERRIDE]
#
#   --via-pi      Deploy through a Raspberry Pi that is connected to the target
#                 over ADB, instead of flashing directly from this host.
#                 Artifacts are copied to pi@192.168.1.207:~/qcom-kernel and the
#                 ADB flashing steps are run remotely on the Pi.
#   --via-ssh     Deploy straight to the board over SSH (root@192.168.1.207:2222)
#                 instead of using ADB. The board runs a full Linux userspace
#                 with sshd, so artifacts are copied directly into place via scp.
#   --dtb-only    Only build and deploy the DTBs/DTBOs. Skips the kernel Image
#                 and modules entirely (no Image build, no modules build/install,
#                 no module transfer) for fast device-tree iteration.
#   KERNEL_DIR    Path to the kernel source directory.
#                 Defaults to 'imdt-qcom-oss-linux-dev'.
#                 If the directory does not exist, the repo will be cloned
#                 from git@github.com:imd-tec/imdt-qcom-oss-linux-dev.git
#   DTB_OVERRIDE  Optional DTB filename to install as the active board DTB.
#
# This script will:
#   1. Clone the kernel repo if not already present
#   2. Merge defconfig with qcom and BSP config fragments
#   3. Build the kernel Image, DTBs and modules
#   4. Deploy the artifacts to the target device via ADB, either directly from
#      this host or (with --via-pi) through a Raspberry Pi.
#
set -e

# Parse arguments
VIA_PI=false
VIA_SSH=false
DTB_ONLY=false
POSITIONAL=()
while [ $# -gt 0 ]; do
	case "$1" in
	--via-pi)
		VIA_PI=true
		shift
		;;
	--via-ssh)
		VIA_SSH=true
		shift
		;;
	--dtb-only)
		DTB_ONLY=true
		shift
		;;
	*)
		POSITIONAL+=("$1")
		shift
		;;
	esac
done
set -- "${POSITIONAL[@]}"

if [ "$VIA_PI" = true ] && [ "$VIA_SSH" = true ]; then
	echo "error: --via-pi and --via-ssh are mutually exclusive" >&2
	exit 1
fi

KERNEL_DIR=${1:-imdt-qcom-oss-linux-dev}
DTB_OVERRIDE=${2:-}
INSTALL_MOD_PATH="$KERNEL_DIR/modules_out"
EFI_PART=/boot/
APPLY_DISPLAY_OVERLAY=true

# Raspberry Pi that is wired up to the target over ADB (used with --via-pi).
PI_HOST=pi@192.168.1.207
PI_DIR=qcom-kernel # relative to the Pi user's home directory

# Target board, reachable over SSH on the network (used with --via-ssh).
BOARD_HOST=root@192.168.1.207
BOARD_PORT=2222

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
	"$SCRIPT_DIR/bsp-additions.cfg" \
	"$SCRIPT_DIR/imdt.cfg"

if [ "$DTB_ONLY" = true ]; then
	# Fast path: build the device trees only, skipping the Image and modules.
	echo "=== Building DTBs only ==="
	make DTC_FLAGS="-@" -j$(nproc) dtbs
else
	# Build kernel, DTBs and modules
	echo "=== Building kernel, DTBs and modules ==="
	#make DTC_FLAGS="=@" clean
	make DTC_FLAGS="-@" -j$(nproc) Image dtbs modules

	# Install modules to a temporary directory
	echo "=== Installing modules locally ==="
	rm -rf "$INSTALL_MOD_PATH"
	make INSTALL_MOD_PATH="$INSTALL_MOD_PATH" modules_install
fi

# Stage all artifacts into a single, deploy-ready layout:
#
#   $STAGE_DIR/
#     Image
#     dtb/qcs8550-imdt-*.dtb*
#     modules/<version>/...
#
# Both the local and --via-pi paths consume this exact layout, so the ADB
# flashing logic below can be identical regardless of where it runs.
STAGE_DIR="$(pwd)/deploy_staging"
echo "=== Staging artifacts in ${STAGE_DIR} ==="
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/dtb" "$STAGE_DIR/modules"
cp arch/arm64/boot/dts/qcom/qcs8550-imdt-*.dtb* "$STAGE_DIR/dtb/"
if [ "$DTB_ONLY" != true ]; then
	cp arch/arm64/boot/Image "$STAGE_DIR/"
	cp -a "$INSTALL_MOD_PATH"/lib/modules/. "$STAGE_DIR/modules/"
fi
if [ -n "$DTB_OVERRIDE" ]; then
	# Make sure the override DTB is present in the staging dir even if its name
	# doesn't match the glob above.
	cp "arch/arm64/boot/dts/qcom/${DTB_OVERRIDE}" "$STAGE_DIR/dtb/"
fi

# The deploy step. This runs from inside the staging directory (so every path
# below is relative to it) and is shared verbatim by both deploy modes: locally
# it is run with bash, and with --via-pi it is piped to bash over SSH on the Pi.
DEPLOY=$(
	cat <<'REMOTE'
set -e

# Every adb command reads from </dev/null. With --via-pi this script is piped to
# the remote bash on stdin, and 'adb shell' would otherwise read from that same
# stdin and swallow the rest of the script (silently skipping the steps below).
adb wait-for-device </dev/null

if [ "${DTB_ONLY}" != true ]; then
  echo "=== Pushing kernel Image ==="
  adb push Image "${EFI_PART}/" </dev/null
fi

echo "=== Pushing DTB ==="
adb shell "mkdir -p ${EFI_PART}/dtb/qcom/" </dev/null
adb pull "${EFI_PART}/dtb/qcom/" /tmp/ </dev/null || true
adb push dtb/qcs8550-imdt-*.dtb* "${EFI_PART}/" </dev/null
if [ -n "${DTB_OVERRIDE}" ]; then
  echo "Overriding DTB with ${DTB_OVERRIDE}"
  adb push "dtb/${DTB_OVERRIDE}" /boot/qcs8550-imdt-sbc.dtb </dev/null
fi

if [ "${DTB_ONLY}" != true ]; then
  echo "=== Pushing kernel modules ==="
  adb shell "rm -rf /lib/modules/*" </dev/null
  adb push modules/* /lib/modules/ </dev/null
fi

adb shell sync </dev/null
adb shell umount "${EFI_PART}" </dev/null
adb shell sync </dev/null
REMOTE
)

if [ "$VIA_SSH" = true ]; then
	# Deploy straight to the board over SSH. The board runs a full Linux
	# userspace with sshd, so instead of going through ADB we copy the staged
	# artifacts directly into place. The board has no rsync, so we use scp.
	# Modules are shipped as a single tarball and unpacked on the board: there
	# are thousands of small .ko files and scp pays a round-trip per file, so
	# one tar stream is dramatically faster. We clear /lib/modules first so
	# stale modules from previously installed kernels don't linger (mirrors the
	# ADB path).
	#
	# As with --via-pi, no compression: the kernel Image + .ko payload is
	# largely incompressible, and we pin a hardware-accelerated cipher so SSH
	# crypto isn't the bottleneck.
	SSH="ssh -p ${BOARD_PORT}"
	SCP="scp -P ${BOARD_PORT} -c aes128-gcm@openssh.com"
	echo "=== Deploying directly to ${BOARD_HOST} over SSH (port ${BOARD_PORT}) ==="
	(
		cd "$STAGE_DIR"
		$SSH "$BOARD_HOST" "mkdir -p ${EFI_PART}/dtb/qcom/ /lib/modules"

		if [ "$DTB_ONLY" != true ]; then
			echo "=== Pushing kernel Image ==="
			$SCP Image "${BOARD_HOST}:${EFI_PART}/"
		fi

		echo "=== Pushing DTB ==="
		$SCP dtb/qcs8550-imdt-*.dtb* "${BOARD_HOST}:${EFI_PART}/"
		if [ -n "$DTB_OVERRIDE" ]; then
			echo "Overriding DTB with ${DTB_OVERRIDE}"
			$SCP "dtb/${DTB_OVERRIDE}" "${BOARD_HOST}:/boot/qcs8550-imdt-sbc.dtb"
		fi

		if [ "$DTB_ONLY" != true ]; then
			echo "=== Pushing kernel modules ==="
			tar -cf modules.tar -C modules .
			$SCP modules.tar "${BOARD_HOST}:/tmp/modules.tar"
			$SSH "$BOARD_HOST" "rm -rf /lib/modules/* && tar -xf /tmp/modules.tar -C /lib/modules && rm -f /tmp/modules.tar"
		fi

		$SSH "$BOARD_HOST" "sync"
	)
elif [ "$VIA_PI" = true ]; then
	# Sync the staged artifacts to the Pi with rsync. Folders stay in sync
	# (--delete prunes stale files) and only changed files cross the wire.
	#
	# No -z: the payload (kernel Image + .ko modules) is largely incompressible,
	# so compression buys almost nothing while burning CPU on the Pi, which is
	# wifi-attached and prone to thermal throttling. We also pin a
	# hardware-accelerated cipher (aes128-gcm on the Pi 5's ARM crypto
	# extensions) so SSH encryption isn't the bottleneck either.
	echo "=== Syncing artifacts to ${PI_HOST}:~/${PI_DIR} ==="
	ssh "$PI_HOST" "mkdir -p ~/${PI_DIR}"
	rsync -ah --delete --info=progress2 \
		-e 'ssh -c aes128-gcm@openssh.com' \
		"$STAGE_DIR"/ "$PI_HOST:${PI_DIR}/"

	echo "=== Flashing target via ADB on ${PI_HOST} ==="
	ssh "$PI_HOST" "adb root"
	ssh "$PI_HOST" "cd ~/${PI_DIR} && EFI_PART='${EFI_PART}' DTB_OVERRIDE='${DTB_OVERRIDE}' DTB_ONLY='${DTB_ONLY}' bash -s" <<<"$DEPLOY"
else
	# Run the shared deploy step locally from inside the staging directory.
	echo "=== Flashing target via ADB on this host ==="
	(cd "$STAGE_DIR" && EFI_PART="$EFI_PART" DTB_OVERRIDE="$DTB_OVERRIDE" DTB_ONLY="$DTB_ONLY" bash -c "$DEPLOY")
fi

# Clean up local artifacts
rm -rf "$STAGE_DIR" "$INSTALL_MOD_PATH"

echo "=== Done ==="
