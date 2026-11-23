#!/bin/bash
# P660 bcmdhd 云端编译主脚本
# 目标: 4.14.78 aarch64 / CONFIG_MODVERSIONS=y / BCM4339 / AP+P2P 全功能
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
KVER=imx_4.14.78_1.0.0_ga
KURL="https://codeload.github.com/nxp-imx/linux-imx/tar.gz/refs/heads/${KVER}"
WORK=${WORK:-$PWD/work}
KERNEL=$WORK/linux-imx
JOBS=$(nproc)

# 4.14 老内核与新 GCC 兼容性差，优先使用较老的 host gcc
HOSTCC_BIN=gcc
for c in gcc-10 gcc-11 gcc-9; do
  if command -v "$c" >/dev/null 2>&1; then HOSTCC_BIN=$c; break; fi
done
echo "HOSTCC = $HOSTCC_BIN ($("$HOSTCC_BIN" --version 2>/dev/null | head -1))"
echo "JOBS   = $JOBS"

mkdir -p "$WORK"

echo "===== [1/7] 下载 NXP 内核源码 ====="
if [ ! -d "$KERNEL" ]; then
  curl -L --retry 5 --retry-delay 3 -o "$WORK/kernel.tar.gz" "$KURL"
  tar xzf "$WORK/kernel.tar.gz" -C "$WORK"
  mv "$WORK/linux-imx-${KVER}" "$KERNEL"
fi
echo "kernel tree size: $(du -sh "$KERNEL" | cut -f1)"

echo "===== [2/7] 兼容性修补 (-fcommon for dtc yylloc) ====="
cd "$KERNEL"
if ! grep -q -- '-fcommon' Makefile; then
  sed -i '/^KBUILD_HOSTCFLAGS/s/$/ -fcommon/' Makefile
  echo "patched KBUILD_HOSTCFLAGS"
fi
grep -m1 '^KBUILD_HOSTCFLAGS' Makefile

echo "===== [3/7] 应用车机内核配置 ====="
cp "$SRC/config/p660_hsae.config" "$KERNEL/.config"

echo "===== [4/7] 集成 bcmdhd 驱动 ====="
bash "$SRC/scripts/patch_tree.sh" "$KERNEL"
echo "driver files: $(ls "$KERNEL/drivers/net/wireless/broadcom/bcmdhd" | wc -l)"

echo "===== [5/7] olddefconfig ====="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC="$HOSTCC_BIN" olddefconfig 2>&1 | tail -5
grep -E "^CONFIG_BCMDHD" .config || { echo "ERROR: CONFIG_BCMDHD missing"; exit 1; }

echo "===== [6/7] 编译 vmlinux (生成带真实 CRC 的 Module.symvers) ====="
if ! make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC="$HOSTCC_BIN" -j"$JOBS" vmlinux > vmlinux_build.log 2>&1; then
  echo "!!! vmlinux build FAILED. Last 80 lines:"
  tail -80 vmlinux_build.log
  exit 1
fi
tail -3 vmlinux_build.log
echo "--- Module.symvers ---"
wc -l Module.symvers

echo "===== [7/7] 编译 bcmdhd.ko ====="
if ! make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC="$HOSTCC_BIN" \
      M=drivers/net/wireless/broadcom/bcmdhd modules > module_build.log 2>&1; then
  echo "!!! module build FAILED. Last 80 lines:"
  tail -80 module_build.log
  exit 1
fi
tail -6 module_build.log

KO=$(find drivers/net/wireless/broadcom/bcmdhd -name '*.ko' | head -1)
echo "KO file: $KO"
ls -la "$KO"
python3 - "$KO" <<'PY'
import sys, re
data = open(sys.argv[1],'rb').read()
m = re.search(rb'vermagic=([\x20-\x7e]+)', data)
print("VERMAGIC:", m.group(1).decode() if m else "NOT FOUND")
print("KO SIZE:", len(data))
PY

echo "===== CRC 核对 ====="
python3 "$SRC/scripts/crc_check.py" "$KERNEL/Module.symvers" "$SRC/crc/crc_p660.txt" || true

mkdir -p "$WORK/out"
cp "$KO" "$WORK/out/"
cp vmlinux_build.log module_build.log "$WORK/out/" 2>/dev/null || true
echo "DONE: $WORK/out/$(basename "$KO")"
