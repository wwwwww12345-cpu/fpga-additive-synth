# fix_pn_outliers.py -- 每音表后处理：去掉离群形状 / 抹平八度间的响度台阶
#
# 症状（用户 2026-10-26）：升八度的 B4（B5）"电子感特别重"；原调 D4 "特别特别响"。
# 查表（harm_amp_vel_pn4_fix.hex, L3）：
#   note 62 (D4) k2 = +10.0 dB（二次谐波比基频还响 -> 能量翻倍，听感"特别响"）
#   note 63 (D#4) k2 = +5.2 dB，note 75/79 k2 = -1.5/-0.7 dB（同类离群）
#   note 48~59 的 k1 = 3131，而 60~71 = 6723 —— C4 处整整一个 6.5 dB 台阶（八度段拼出来的）
#   B5(83) k2=-20.8, k3=-30.4 -> 余音偏"薄/纯"，配合固定初相听成"电子味"
#
# 做法（仍然**每音一行**，只是把测量里明显不靠谱的地方收一收）：
#   1) k1：沿音高做 25 音宽的移动平均（log 域），抹平八度台阶
#   2) 形状：每个分音的相对 dB 沿音高做 5 音宽中值滤波，去单音离群
#   3) 钳位：任何分音不得超过基频 −2 dB（钢琴上"二次谐波比基频响 10 dB"不可能）
#   4) Nyquist 截断
# 输出 harm_amp_vel_pn4_smooth.hex
#
# 用法: .venv\Scripts\python.exe tools/fix_pn_outliers.py
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

ROM = r"D:\piano_att\rtl\rom"
SRC = ROM + r"\harm_amp_vel_pn4_fix.hex"
OUT = ROM + r"\harm_amp_vel_pn4_smooth.hex"
FTW = _read_hex(ROM + r"\note_ftw_48828.hex") >> 8
FS = 48828.125
KW = 25          # k1 平滑窗(音)
KS = 5           # 形状中值窗(音)
CLAMP_DB = -2.0  # 分音相对基频的上限


def medfilt(x, w):
    n = len(x)
    h = w // 2
    out = np.copy(x)
    for i in range(n):
        lo, hi = max(0, i - h), min(n, i + h + 1)
        out[i] = np.median(x[lo:hi])
    return out


def main():
    pn = _read_hex(SRC).reshape(128, 4, 16).astype(np.float64)
    k1 = pn[:, :, 0]                                  # (128,4)
    shp = 20 * np.log10(np.maximum(pn, 1e-9) / np.maximum(k1[:, :, None], 1e-9))

    # 1) k1 平滑（log 域移动平均）
    k1s = np.zeros_like(k1)
    h = KW // 2
    for l in range(4):
        lg = np.log2(np.maximum(k1[:, l], 1.0))
        for i in range(128):
            lo, hi = max(0, i - h), min(128, i + h + 1)
            k1s[i, l] = 2 ** np.mean(lg[lo:hi])

    # 2) 形状沿音高中值滤波（逐层逐分音）
    shps = np.zeros_like(shp)
    for l in range(4):
        for k in range(16):
            shps[:, l, k] = medfilt(shp[:, l, k], KS)

    # 3) 钳位 + 4) Nyquist
    out = np.zeros_like(pn)
    for n in range(128):
        f0 = FTW[n] * FS / (1 << 24)
        kmax = int(np.floor(0.47 * FS / max(f0, 1.0)))
        for l in range(4):
            d = shps[n, l].copy()
            d[1:] = np.minimum(d[1:], CLAMP_DB)
            d = np.maximum(d, -75.0)
            row = np.round(k1s[n, l] * (10 ** (d / 20.0))).astype(np.int64)
            row = np.clip(row, 0, 65535)
            if kmax < 16:
                row[kmax:] = 0
            out[n, l] = row

    lines = []
    for n in range(128):
        for l in range(4):
            for k in range(16):
                lines.append("%04X" % int(out[n, l, k]))
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT, len(lines), "lines")

    print("\n关键音自检（L3: k1, k2 dB, k3 dB）:")
    for n in (48, 55, 60, 62, 63, 67, 72, 83, 84, 96):
        r = out[n, 3].astype(float)
        k2 = 20 * np.log10(max(r[1], 1e-9) / max(r[0], 1e-9))
        k3 = 20 * np.log10(max(r[2], 1e-9) / max(r[0], 1e-9))
        print("  note %3d  k1=%6.0f  k2=%6.1f  k3=%6.1f" % (n, r[0], k2, k3))
    print("\nk1 台阶检查（C3 段 vs C4 段）: ")
    for n in (48, 54, 59, 60, 66, 71, 72):
        print("  note %3d k1=%6.0f" % (n, out[n, 3, 0]))


if __name__ == "__main__":
    main()
