# 生成 KS RTL 用的表：三角步进 step = round(32767/(N/2))、起振包络（6ms 升余弦）
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

FS = 48828.125
n_tab = _read_hex("gtr_delay_n.hex")
steps = []
for n in n_tab:
    half = max(int(n) >> 1, 1)
    steps.append("%04X" % (((32767 + half // 2) // half) & 0xFFFF))
open(r"D:\piano_att\rtl\rom\gtr_tri_step.hex", "w", newline="\n").write("\n".join(steps) + "\n")

env = np.round(32767 * (0.5 - 0.5 * np.cos(np.pi * np.arange(288) / 288))).astype(int)
open(r"D:\piano_att\rtl\rom\gtr_env.hex", "w", newline="\n").write("\n".join("%04X" % v for v in env) + "\n")
print("wrote gtr_tri_step.hex (128) gtr_env.hex (288)")
