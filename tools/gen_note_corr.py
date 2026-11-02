# 生成按音修正表 note_corr.hex（128 音 × 16 分音，8 bit，255≈1.0）
# 依据：per_note_shapes.json（C4..C8 逐音实测）+ octave_shapes.json（C2/C3 等八度均值）
import json
import os
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

ROOT = r"D:\采样音色"
FLOOR = -75.0
shp = json.load(open(os.path.join(ROOT, "tools", "per_note_shapes.json"), encoding="utf-8"))
octs = json.load(open(os.path.join(ROOT, "tools", "octave_shapes.json"), encoding="utf-8"))["octave_mean_lin"]
amp = _read_hex(r"D:\piano_att\rtl\rom\harm_amp_vel_oct.hex").reshape(8, 8, 16)   # 8 段×8 层×16

THR = [(36, 0), (48, 1), (60, 2), (72, 3), (84, 4), (96, 5), (108, 6)]
SEG_OCT = {0: "2", 1: "3", 2: "4", 3: "5", 4: "6", 5: "7", 6: "7"}


def seg_of(note):
    seg = 0
    for thr, s in THR:
        if note >= thr:
            seg = s
    return min(seg, 7) if seg <= 5 else 5


def target(note):
    key = str(note)
    if key in shp:
        return np.array([FLOOR if v is None else max(float(v), FLOOR) for v in shp[key]])
    seg = seg_of(note)
    key = SEG_OCT[seg]
    return np.array([FLOOR if v is None else max(float(v), FLOOR) for v in octs[key]])


corr = np.zeros((128, 16), dtype=np.int64)
for n in range(128):
    seg = seg_of(n)
    a = amp[seg][4].astype(np.float64)          # mf 层
    S = 20 * np.log10(np.maximum(a, 1e-9) / max(a[0], 1e-9))
    T = target(n)
    d = T - S
    c = np.round(255.0 * (10 ** (d / 20.0)))
    c = np.clip(c, 0, 255).astype(np.int64)
    c[T <= -70.0] = 0
    corr[n] = c

p = r"D:\piano_att\rtl\rom\note_corr.hex"
with open(p, "w", newline="\n") as f:
    for n in range(128):
        for k in range(16):
            f.write("%02X\n" % int(corr[n, k]))
print("wrote", p, "lines", 128 * 16)
for n in (60, 72, 79, 84, 96):
    print("note", n, "corr k1..k8:", corr[n, :8].tolist())
