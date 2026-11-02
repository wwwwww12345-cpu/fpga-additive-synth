# gtr_note_tables.py -- 吉他的每音延迟长度 N 与循环增益 g（fs = 48828.125）
import os
import sys

import numpy as np

FS = 48828.125
# 参考版本拟合的 g（C4/E4/G4/B3）
ANCH = {59: 0.9925, 60: 0.9910, 64: 0.9960, 67: 0.9930}


def g_of(note):
    if note in ANCH:
        return ANCH[note]
    # 在锚点间线性插值（log 频率），范围外取最近
    ks = sorted(ANCH)
    if note <= ks[0]:
        return ANCH[ks[0]]
    if note >= ks[-1]:
        return ANCH[ks[-1]]
    for a, b in zip(ks, ks[1:]):
        if a <= note <= b:
            t = (note - a) / (b - a)
            return ANCH[a] * (1 - t) + ANCH[b] * t
    return 0.993


rows_n, rows_g = [], []
for note in range(128):
    f0 = 440.0 * 2 ** ((note - 69) / 12.0)
    n = int(round(FS / f0))
    n = max(8, min(n, 640))
    rows_n.append("%03X" % (n & 0x3FF))
    rows_g.append("%04X" % int(round(g_of(note) * 32768)))

p1 = r"D:\piano_att\rtl\rom\gtr_delay_n.hex"
p2 = r"D:\piano_att\rtl\rom\gtr_loop_g.hex"
open(p1, "w", newline="\n").write("\n".join(rows_n) + "\n")
open(p2, "w", newline="\n").write("\n".join(rows_g) + "\n")
print("wrote", p1, p2)
for note in (60, 64, 67, 59):
    f0 = 440.0 * 2 ** ((note - 69) / 12.0)
    print("note", note, "f0 %.2f" % f0, "N", int(round(FS / f0)), "g", g_of(note))
