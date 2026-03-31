# imdt-qcom-oss-linux-build-script

Build and deploy script for the Qualcomm QCS8550 IMD-T SBC kernel.

## Prerequisites

- AArch64 cross-compiler (`aarch64-linux-gnu-`)
- ADB connected to the target device
- SSH key access to the kernel repo (for initial clone)

## Usage

```bash
./build.sh [KERNEL_DIR]
```

- **KERNEL_DIR** - Path to the kernel source directory (default: `imdt-qcom-oss-linux-dev`).
  If the directory does not exist, it will be cloned automatically from
  `git@github.com:imd-tec/imdt-qcom-oss-linux-dev.git`.

## What it does

1. Clones the kernel repo if not already present
2. Copies `bsp-additions.config` into the kernel tree
3. Merges config fragments (`defconfig`, `prune.config`, `qcom.config`, `bsp-additions.config`)
4. Builds the kernel Image, DTBs, and modules
5. Pushes the Image, DTB, and modules to the target device via ADB

## Files

- `build.sh` - Main build and deploy script
- `bsp-additions.config` - BSP-specific kernel config fragment
