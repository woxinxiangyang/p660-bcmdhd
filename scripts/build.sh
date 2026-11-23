#!/bin/bash
# P660 bcmdhd 云端编译主脚本
# 目标: 4.14.78 aarch64 / CONFIG_MODVERSIONS=y / BCM4339 / AP+P2P 全功能
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
KVER=imx_4.14.78_1.0.0_ga
KURL="https://codeload.github.com/nxp-imx/linux-imx/tar.gz/refs/heads/${KVER}"
WORK=${WORK:-$PWD/work}
KERNEL=$WORK/linux-imx

mkdir -p "$WORK"

echo "===== [1/7] 下载 NXP 内核源码 ====="
if [ ! -d "$KERNEL" ]; then
  curl -L --retry 5 --retry-delay 3 -o "$WORK/kernel.tar.gz" "$KURL"
  tar xzf "$WORK/kernel.tar.gz" -C "$WORK"
  mv "$WORK/linux-imx-${KVER}" "$KERNEL"
fi

echo "===== [2/7] 应用车机内核配置 ====="
cp "$SRC/config/p660_hsae.config" "$KERNEL/.config"

echo "===== [3/7] 集成 bcmdhd 驱动 ====="
bash "$SRC/scripts/patch_tree.sh" "$KERNEL"

echo "===== [4/7] olddefconfig ====="
cd "$KERNEL"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig 2>&1 | tail -5
grep -E "^CONFIG_BCMDHD" .config || { echo "ERROR: CONFIG_BCMDHD missing"; exit 1; }

echo "===== [5/7] 编译 vmlinux (生成带 CRC 的 Module.symvers) ====="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" vmlinux 2>&1 | tail -20

echo "===== [6/7] 编译 bcmdhd.ko ====="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=drivers/net/wireless/broadcom/bcmdhd modules 2>&1 | tail -30

KO=$(find drivers/net/wireless/broadcom/bcmdhd -name '*.ko' | head -1)
echo "KO file: $KO"
ls -la "$KO"
python3 - "$KO" <<'PY'
import sys, re
data = open(sys.argv[1],'rb').read()
m = re.search(rb'vermagic=([\x20-\x7e]+)', data)
print("VERMAGIC:", m.group(1).decode() if m else "NOT FOUND")
PY

echo "===== [7/7] CRC 核对 ====="
python3 "$SRC/scripts/crc_check.py" "$KERNEL/Module.symvers" "$SRC/crc/crc_p660.txt"

mkdir -p "$WORK/out"
cp "$KO" "$WORK/out/"
echo "DONE: $WORK/out/$(basename "$KO")"
