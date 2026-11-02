# 生成 v17 的衰减表：平滑单调（1.1^k）× 0.30（拉长余音）
import sys

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

import os

d0 = _read_hex(r"D:\piano_att\rtl\rom\harm_decay_ctrl_C4.hex")
base = int(d0[0])
vals = []
for k in range(16):
    v = int(round(base * (1.1 ** k) * 0.30))
    vals.append(max(1, min(v, 2 ** 32 - 1)))
p = r"D:\piano_att\rtl\rom\harm_decay_ctrl_slow.hex"
with open(p, "w", newline="\n") as f:
    for v in vals:
        f.write("%08X\n" % v)
print("wrote", p)
for k, v in enumerate(vals, 1):
    tau = (32 / 48828.125) * (2 ** 32) / v
    print("k%-2d dec=%10d tau=%.2f s (%.1f dB/s)" % (k, v, tau, 8.686 / tau))
