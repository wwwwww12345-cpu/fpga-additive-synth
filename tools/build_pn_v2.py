# build_pn_v2.py -- 每音表 v2：**保留原来的每音/每层响度(k1)**，只采用平滑后的谐波形状
#
# 背景：用户反馈上一版"钢琴开头又变明显了"。查下来是 fix_pn_outliers 把 k1 也平滑了
#   (C4: 6723 -> 4691，-3.1 dB)，而音头噪声幅度是固定的(-30dBFS)，音符变轻 -> 噪声相对更突出。
# 本版：k1 取 harm_amp_vel_pn4_fix.hex（原始每音电平），形状取 harm_amp_vel_pn4_smooth.hex
#   的相对形状（已做中值滤波 + 分音不超过基频 -2dB + 坏高音行修补 + Nyquist 截断）。
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

ROM = r"D:\piano_att\rtl\rom"
OUT = ROM + r"\harm_amp_vel_pn4_v2.hex"
FS = 48828.125
FTW = _read_hex(ROM + r"\note_ftw_48828.hex") >> 8


def main():
    fix = _read_hex(ROM + r"\harm_amp_vel_pn4_fix.hex").reshape(128, 4, 16).astype(np.float64)
    smo = _read_hex(ROM + r"\harm_amp_vel_pn4_smooth.hex").reshape(128, 4, 16).astype(np.float64)
    k1 = fix[:, :, 0]
    shp = 20 * np.log10(np.maximum(smo, 1e-9) / np.maximum(smo[:, :, :1], 1e-9))
    shp[:, :, 0] = 0.0
    out = np.clip(np.round(k1[:, :, None] * (10 ** (shp / 20.0))), 0, 65535).astype(np.int64)
    for n in range(128):
        f0 = int(FTW[n]) * FS / (1 << 24)
        kmax = int(np.floor(0.47 * FS / max(f0, 1.0)))
        if kmax < 16:
            out[n, :, kmax:] = 0

    lines = []
    for n in range(128):
        for l in range(4):
            for k in range(16):
                lines.append("%04X" % int(out[n, l, k]))
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT, len(lines), "lines")
    for n in (48, 60, 62, 64, 71, 83, 96):
        r = out[n, 3].astype(float)
        k2 = 20 * np.log10(max(r[1], 1) / max(r[0], 1))
        k3 = 20 * np.log10(max(r[2], 1) / max(r[0], 1))
        print("note %3d  k1=%6d  k2=%6.1f  k3=%6.1f" % (n, r[0], k2, k3))


if __name__ == "__main__":
    main()
