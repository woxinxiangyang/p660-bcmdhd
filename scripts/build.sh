#!/bin/bash
# P660 bcmdhd 云端编译主脚本
# 目标: linux 4.14.78 aarch64 / CONFIG_MODVERSIONS=y / BCM4339 / AP+P2P 全功能
set -euo pipefail

trap 'echo "!!! FAILED at line $LINENO: $BASH_COMMAND"' ERR

SRC=$(cd "$(dirname "$0")/.." && pwd)
KVER=imx_4.14.78_1.0.0_ga
KURL="https://codeload.github.com/nxp-imx/linux-imx/tar.gz/refs/heads/${KVER}"
WORK=${WORK:-$PWD/work}
KERNEL=$WORK/linux-imx
JOBS=$(nproc)

mkdir -p "$WORK"

# ---------- 编译器选择 ----------
# 宿主: 4.14 老内核必须用老 GCC（gcc-11 会误报/误编译）
HOSTCC_BIN=gcc
for c in gcc-10 gcc-9 gcc-11 gcc; do
  if command -v "$c" >/dev/null 2>&1; then HOSTCC_BIN=$c; break; fi
done

# 交叉: 优先 gcc-10 版 aarch64 交叉编译器，用 PATH 垫片方式切换
if command -v aarch64-linux-gnu-gcc-10 >/dev/null 2>&1; then
  mkdir -p "$WORK/xtool"
  rm -f "$WORK"/xtool/aarch64-linux-gnu-*
  for t in gcc g++ cpp; do
    src_bin=$(command -v "aarch64-linux-gnu-${t}-10" || true)
    [ -n "$src_bin" ] && ln -sf "$src_bin" "$WORK/xtool/aarch64-linux-gnu-${t}"
  done
  export PATH="$WORK/xtool:$PATH"
fi

# 宿主 HOSTCFLAGS: 4.14 的 scripts/dtc 在新 GCC(-fno-common 默认) 下会 yylloc 重复定义
HOST_FLAGS="-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon"

echo "HOSTCC  = $HOSTCC_BIN ($("$HOSTCC_BIN" --version 2>/dev/null | head -1))"
echo "CROSSCC = $(aarch64-linux-gnu-gcc --version 2>/dev/null | head -1)"
echo "JOBS    = $JOBS"

mk() {
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
       HOSTCC="$HOSTCC_BIN" HOSTCFLAGS="$HOST_FLAGS" HOSTCXXFLAGS="-O2" "$@"
}

echo "===== [1/7] 下载 NXP 内核源码 ====="
if [ ! -d "$KERNEL" ]; then
  curl -L --retry 5 --retry-delay 3 -o "$WORK/kernel.tar.gz" "$KURL"
  tar xzf "$WORK/kernel.tar.gz" -C "$WORK"
  mv "$WORK/linux-imx-${KVER}" "$KERNEL"
fi
echo "kernel tree size: $(du -sh "$KERNEL" | cut -f1)"
cd "$KERNEL"
head -5 Makefile | grep -E "VERSION|PATCHLEVEL|SUBLEVEL" || true
# HOSTCFLAGS 存在性自检（4.14 用的就是这个名字）
grep -m1 -n "^HOSTCFLAGS" Makefile || echo "WARN: no HOSTCFLAGS line found"

echo "===== [2/7] 应用车机内核配置 ====="
cp "$SRC/config/p660_hsae.config" "$KERNEL/.config"
echo "config lines: $(wc -l < .config)"

echo "===== [3/7] 集成 bcmdhd 驱动 ====="
bash "$SRC/scripts/patch_tree.sh" "$KERNEL"
ls drivers/net/wireless/broadcom/bcmdhd/*.c | wc -l
ls drivers/net/wireless/broadcom/bcmdhd/*.h | wc -l
grep -q "bcmdhd" drivers/net/wireless/broadcom/Kconfig && echo "Kconfig hooked"
grep -q "bcmdhd" drivers/net/wireless/broadcom/Makefile && echo "Makefile hooked"

echo "===== [4/7] olddefconfig ====="
mk olddefconfig > olddefconfig.log 2>&1 || { echo "!!! olddefconfig FAILED"; tail -40 olddefconfig.log; exit 1; }
grep -E "^CONFIG_(BCMDHD|MODVERSIONS|MODULES)=" .config || true
grep -q "^CONFIG_BCMDHD=m" .config || { echo "ERROR: CONFIG_BCMDHD not =m"; exit 1; }

echo "===== [5/7] 编译 vmlinux (生成带真实 CRC 的 Module.symvers) ====="
echo "start: $(date -u +%H:%M:%S)"
if ! mk -j"$JOBS" vmlinux > vmlinux_build.log 2>&1; then
  echo "!!! vmlinux build FAILED"
  echo "--- error lines ---"
  grep -E "error:|Error [0-9]|\*\*\*" vmlinux_build.log | head -40 || true
  echo "--- last 120 lines ---"
  tail -120 vmlinux_build.log
  exit 1
fi
echo "end: $(date -u +%H:%M:%S)"
tail -3 vmlinux_build.log
echo "Module.symvers entries: $(wc -l < Module.symvers)"

echo "===== [6/7] 编译 bcmdhd.ko ====="
if ! mk -j"$JOBS" M=drivers/net/wireless/broadcom/bcmdhd modules > module_build.log 2>&1; then
  echo "!!! module build FAILED"
  grep -E "error:|Error [0-9]" module_build.log | head -40 || true
  echo "--- last 100 lines ---"
  tail -100 module_build.log
  exit 1
fi
grep -E "warning:|error:" module_build.log | head -20 || true
tail -6 module_build.log

echo "===== [7/7] 产物检查 + CRC 核对 ====="
KO=$(find drivers/net/wireless/broadcom/bcmdhd -name '*.ko' | head -1)
echo "KO file: $KO"
ls -la "$KO"
python3 - "$KO" <<'PY'
import sys, re
data = open(sys.argv[1], 'rb').read()
m = re.search(rb'vermagic=([\x20-\x7e]+)', data)
print("VERMAGIC:", m.group(1).decode() if m else "NOT FOUND")
print("KO SIZE:", len(data))
PY

python3 "$SRC/scripts/crc_check.py" "$KERNEL/Module.symvers" "$SRC/crc/crc_p660.txt" || true

mkdir -p "$WORK/out"
cp "$KO" "$WORK/out/"
cp vmlinux_build.log module_build.log "$WORK/out/" 2>/dev/null || true
echo "DONE: $WORK/out/$(basename "$KO")"
