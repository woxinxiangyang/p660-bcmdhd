#!/usr/bin/env python3
"""对比新编译内核 Module.symvers 与车机原厂驱动 __versions 的符号 CRC

用法: crc_check.py Module.symvers crc_p660.txt
输出: 匹配/不匹配/缺失统计 + 明细报告
"""
import sys

def load_symvers(path):
    table = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            crc, sym = parts[0], parts[1]
            try:
                table[sym] = int(crc, 16)
            except ValueError:
                continue
    return table

def load_ref(path):
    table = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                table[parts[1]] = int(parts[0], 16)
            except ValueError:
                continue
    return table

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    new = load_symvers(sys.argv[1])
    ref = load_ref(sys.argv[2])

    ok, bad, missing = [], [], []
    for sym, crc in sorted(ref.items()):
        if sym not in new:
            missing.append(sym)
        elif new[sym] == crc:
            ok.append(sym)
        else:
            bad.append((sym, crc, new[sym]))

    total = len(ref)
    print(f"\n===== CRC 核对报告 =====")
    print(f"参考符号数(原厂驱动): {total}")
    print(f"  一致        : {len(ok)}  ({len(ok)*100//max(total,1)}%)")
    print(f"  CRC 不一致  : {len(bad)}")
    print(f"  新内核缺失  : {len(missing)}")

    if bad:
        print("\n--- CRC 不一致明细 ---")
        for sym, r, n in bad:
            print(f"  {sym}: ref=0x{r:08x} new=0x{n:08x}")
    if missing:
        print("\n--- 新内核未导出 ---")
        print("  " + ", ".join(missing))

    verdict = "PASS" if not bad and not missing else "FAIL"
    print(f"\nVERDICT: {verdict}")
    # 不一致时让 CI 失败但保留产物供分析
    sys.exit(0 if verdict == "PASS" else 1)

if __name__ == '__main__':
    main()
