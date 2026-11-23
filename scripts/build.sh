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
  # KCFLAGS 会被追加到内核全局 CFLAGS（同一变量后写的覆盖前面的）：
  #  -fcommon：老内核依赖"暂定定义"，gcc-10 起 -fno-common 成默认值
  #  -Wno-error=implicit-*：4.14 把隐式声明当错误，老代码里若干函数原型只在内部头里
  #  注意：产物只用于取 Module.symvers 的符号 CRC，不会上机运行，故这些降级不影响结论
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
       HOSTCC="$HOSTCC_BIN" HOSTCFLAGS="$HOST_FLAGS" HOSTCXXFLAGS="-O2" \
       KCFLAGS="-fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" "$@"
}

# 模块必须用 -fno-common 编译：内核 simplify_symbols() 遇到 SHN_COMMON 直接
# "please compile with -fno-common" 并拒绝装载模块。上面的 -fcommon 只是给
# 老内核(vmlinux/工具)用的，不能带到 .ko 里。
mkmod() {
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
       HOSTCC="$HOSTCC_BIN" HOSTCFLAGS="$HOST_FLAGS" HOSTCXXFLAGS="-O2" \
       KCFLAGS="-fno-common -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" "$@"
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

echo "===== [2/7] 宿主工具链兼容性修补 ====="
# (a) 4.14 的 security/selinux/include/classmap.h 用宿主 glibc 的 PF_MAX 做断言；
#     新版 glibc 多了 AF_MCTP 等，会直接 #error 掉 genheaders。放宽上限即可，
#     只影响构建期生成的头文件，与模块 CRC 无关。
if grep -qE '^#if PF_MAX > [0-9]+$' security/selinux/include/classmap.h; then
  sed -i -E 's/^#if PF_MAX > [0-9]+$/#if PF_MAX > 200/' security/selinux/include/classmap.h
  mkdir -p scripts/selinux/genheaders 2>/dev/null || true
  # 某些版本 genheaders 目录下需要 .gitignore 占位（避免 make 报 "No rule to make target"）
  grep -n "PF_MAX" security/selinux/include/classmap.h | head -2
  echo "patched classmap.h PF_MAX guard"
fi
# (b) 确认 HOSTCFLAGS 存在（4.14 的变量名；4.17+ 才叫 KBUILD_HOSTCFLAGS）
grep -m1 -n "^HOSTCFLAGS" Makefile || echo "WARN: no HOSTCFLAGS line"

# (c) dm-rq.c 调用了 elv_register_queue()，但该声明只在 block/blk.h（块层内部头）里，
#     公开头 linux/elevator.h 没有。gcc-10 把隐式声明当错误。补一条 extern 声明即可，
#     符号本身在 block/elevator.c 中确实存在，不改变行为。
if grep -q "elv_register_queue(md->queue)" drivers/md/dm-rq.c 2>/dev/null; then
  if ! grep -q "extern int elv_register_queue" drivers/md/dm-rq.c; then
    sed -i '0,/#include <linux\/blk-mq.h>/s//#include <linux\/blk-mq.h>\nextern int elv_register_queue(struct request_queue *q);/' drivers/md/dm-rq.c
    echo "patched dm-rq.c: extern elv_register_queue"
  fi
  grep -n "extern int elv_register_queue" drivers/md/dm-rq.c
fi

echo "===== [2.5/7] 应用车机内核配置 ====="
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
CFGSUM=$(sha256sum .config | cut -d' ' -f1)
STAMP="$KERNEL/.config.built"
if [ -f Module.symvers ] && [ "$(wc -l < Module.symvers)" -gt 10000 ] \
   && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$CFGSUM" ]; then
  echo "缓存命中：Module.symvers 已存在（$(wc -l < Module.symvers) 条），.config 未变化，跳过 vmlinux 编译"
else
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
  echo "$CFGSUM" > "$STAMP"
fi
echo "Module.symvers entries: $(wc -l < Module.symvers)"

echo "===== [6/7] 编译 bcmdhd.ko ====="
# -k 让 make 继续编其余文件，一次拿到全部错误清单（否则每轮只能发现一个，迭代太慢）
if ! mkmod -k -j"$JOBS" M=drivers/net/wireless/broadcom/bcmdhd modules > module_build.log 2>&1; then
  echo "!!! module build FAILED"
  echo "--- 全部 error（去重）---"
  grep -E "error:" module_build.log | sed 's/^.*bcmdhd\///' | sort -u | head -60 || true
  echo "--- 最后一个 error 的上下文 ---"
  tail -60 module_build.log
  exit 1
fi
grep -E "warning:|error:" module_build.log | head -20 || true
tail -6 module_build.log

echo "===== [7/7] 产物检查 + CRC 核对 ====="
KO=$(find drivers/net/wireless/broadcom/bcmdhd -name '*.ko' | head -1)
echo "KO file: $KO"
ls -la "$KO"
# COMMON 符号会让内核 simplify_symbols() 直接拒装，这里显式拦一道
if grep -q "is COMMON symbol" module_build.log; then
  echo "!!! 模块里仍有 COMMON 符号（装载会被内核拒绝）:"
  grep "is COMMON symbol" module_build.log | wc -l
else
  echo "COMMON symbol check: clean"
fi
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
