# build_pn_single_shape.py -- 用"一个音色"的谐波形状 + 每音电平，重建 128×4×16 的每音表
#
# 背景（2026-10-26）：
#   当前固件用 harm_amp_vel_pn4.hex（128 音 × 4 层 × 16 分音）。它的高音行是从 Iowa 采样
#   实测形状代进去的，而 Iowa 的高音采样本身就是"暗"的（mf C6 的 k2 −28dB、C7 −36dB，
#   连 ff 也只有 −21/−33dB）-> 高音听成单正弦。引擎没有读错段（地址 {note,layer,k} 已核对），
#   它只是忠实地复现了一张暗表。
#
# 做法（也是用户要的"用单个音色的表"）：
#   * 形状：取 C4（note 60）4 个力度层实测的谐波形状 k2..k16 相对 k1（dB）
#   * 电平：每个音/每层保留当前表的 k1（响度不变）
#   * 截断：k*f0 > 0.47*FS 的分音置 0（避免混叠成"怪音"）
#   输出 harm_amp_vel_pn4_single.hex（旧表保留做 A/B）
#
# 用法: .venv\Scripts\python.exe tools/build_pn_single_shape.py
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

ROM = r"D:\piano_att\rtl\rom"
SRC = ROM + r"\harm_amp_vel_pn4.hex"
OUT = ROM + r"\harm_amp_vel_pn4_single.hex"
FTW = _read_hex(ROM + r"\note_ftw_48828.hex") >> 8
FS = 48828.125


def main():
    pn = _read_hex(SRC).reshape(128, 4, 16).astype(np.float64)
    c4 = pn[60]                                     # 形状参考
    shape_db = 20 * np.log10(np.maximum(c4, 1e-9) / np.maximum(c4[:, :1], 1e-9))
    print("参考形状（C4，k2..k16 相对 k1 dB）：")
    for l in range(4):
        print("  L%d: %s" % (l, " ".join("%6.1f" % v for v in shape_db[l][1:])))

    out = np.zeros_like(pn)
    for n in range(128):
        f0 = FTW[n] * FS / (1 << 24)
        kmax = int(np.floor(0.47 * FS / max(f0, 1.0)))
        for l in range(4):
            k1 = max(pn[n, l, 0], 1.0)
            row = np.round(k1 * (10 ** (shape_db[l] / 20.0))).astype(np.int64)
            row = np.clip(row, 0, 65535)
            row[shape_db[l] <= -70.0] = 0
            if kmax < 16:
                row[kmax:] = 0                        # Nyquist 截断（k 从 0 起算 = 分音 k+1）
            out[n, l] = row

    lines = []
    for n in range(128):
        for l in range(4):
            for k in range(16):
                lines.append("%04X" % int(out[n, l, k]))
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT, len(lines), "lines")

    for n in (36, 60, 72, 84, 96, 108):
        f0 = FTW[n] * FS / (1 << 24)
        kmax = int(np.floor(0.47 * FS / max(f0, 1.0)))
        row = out[n, 3].astype(float)
        db = 20 * np.log10(np.maximum(row, 1e-9) / max(row[0], 1e-9))
        print("note %3d f0=%7.1f kmax=%2d L3 k1=%5d  k2..k8 dB: %s"
              % (n, f0, kmax, row[0], " ".join("%6.1f" % v for v in db[1:8])))


if __name__ == "__main__":
    main()
