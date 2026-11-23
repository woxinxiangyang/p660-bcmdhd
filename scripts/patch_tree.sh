#!/bin/bash
# 把 bcmdhd 驱动集成进内核树
set -e

KERNEL=$1
SRC=$(cd "$(dirname "$0")/.." && pwd)

echo "== 复制驱动源码 =="
mkdir -p "$KERNEL/drivers/net/wireless/broadcom/bcmdhd"
cp -r "$SRC/bcmdhd/." "$KERNEL/drivers/net/wireless/broadcom/bcmdhd/"

echo "== 挂接 Kconfig =="
KCFG="$KERNEL/drivers/net/wireless/broadcom/Kconfig"
if ! grep -q 'bcmdhd/Kconfig' "$KCFG"; then
  sed -i 's#^source "drivers/net/wireless/broadcom/brcm80211/Kconfig"#source "drivers/net/wireless/broadcom/brcm80211/Kconfig"\nsource "drivers/net/wireless/broadcom/bcmdhd/Kconfig"#' "$KCFG"
fi

echo "== 挂接 Makefile =="
MKF="$KERNEL/drivers/net/wireless/broadcom/Makefile"
if ! grep -q 'CONFIG_BCMDHD' "$MKF"; then
  printf 'obj-$(CONFIG_BCMDHD)\t+= bcmdhd/\n' >> "$MKF"
fi

echo "== 集成完成 =="
grep -n bcmdhd "$KCFG" "$MKF"
