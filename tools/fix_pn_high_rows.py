# fix_pn_high_rows.py -- 每音表里"实测坏掉"的高音行，用邻近可靠行做 dB 插值修补
#
# 依据（2026-10-26 夜间排查）：
#   harm_amp_vel_pn4.hex 的 note 92~108 行 k2 = −40~−50 dB（C7 基本只剩基音），
#   而相邻的 note 84 = −10.1、note 112 = −16.2；同一份 vel_layers.json 里
#   note 100 的 pp/mf/ff 是 −33.5/−39.0/−45.9（越响越暗，物理上反了）-> 高音这段测量失败。
#   所以不是"取段错"，是这几行的数据坏了。
#
# 做法（仍然是**每音自己的表**，不是所有音共用一个形状）：
#   * 判定坏行：L3 的 k2 < -28 dB
#   * 坏行的形状 = 在"最近的两个好行"之间按音高做 dB 线性插值（逐层、逐分音）
#   * **k1（每音每层响度）保持原表不变**
#   * k*f0 > 0.47*FS 的分音清零
# 输出 harm_amp_vel_pn4_fix.hex（原表保留）
#
# 用法: .venv\Scripts\python.exe tools/fix_pn_high_rows.py
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex  # noqa: E402

ROM = r"D:\piano_att\rtl\rom"
SRC = ROM + r"\harm_amp_vel_pn4.hex"
OUT = ROM + r"\harm_amp_vel_pn4_fix.hex"
FTW = _read_hex(ROM + r"\note_ftw_48828.hex") >> 8
FS = 48828.125
BAD_DB = -28.0


def shape_db(row):
    k1 = np.maximum(row[..., :1], 1e-9)
    return 20 * np.log10(np.maximum(row, 1e-9) / k1)


def main():
    pn = _read_hex(SRC).reshape(128, 4, 16).astype(np.float64)
    shp = shape_db(pn)                       # (128,4,16) 相对 k1 的 dB
    bad = shp[:, 3, 1] < BAD_DB              # L3 的 k2 判定
    good = [n for n in range(128) if not bad[n]]
    print("坏行（L3 k2 < %.0f dB）：%s" % (BAD_DB, [n for n in range(128) if bad[n]]))

    out = pn.copy()
    fixed = []
    for n in range(128):
        if not bad[n]:
            continue
        lo = max([g for g in good if g < n], default=None)
        hi = min([g for g in good if g > n], default=None)
        if lo is None and hi is None:
            continue
        if lo is None:
            lo = hi
        if hi is None:
            hi = lo
        w = 0.0 if hi == lo else (n - lo) / float(hi - lo)
        d = (1 - w) * shp[lo] + w * shp[hi]        # (4,16) 相对形状
        row = pn[n, :, :1] * (10 ** (d / 20.0))    # 保留每音每层 k1
        fixed.append((n, lo, hi, w, d[3, 1]))
        out[n] = row

    # Nyquist 截断 + 限幅
    for n in range(128):
        f0 = FTW[n] * FS / (1 << 24)
        kmax = int(np.floor(0.47 * FS / max(f0, 1.0)))
        if kmax < 16:
            out[n, :, kmax:] = 0
    out = np.clip(np.round(out), 0, 65535).astype(np.int64)

    lines = []
    for n in range(128):
        for l in range(4):
            for k in range(16):
                lines.append("%04X" % int(out[n, l, k]))
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT, len(lines), "lines")
    for n, lo, hi, w, k2 in fixed:
        print("  note %3d <- 在 %3d/%3d 之间插值 w=%.2f，新 k2 = %6.1f dB" % (n, lo, hi, w, k2))

    # 修完后的抽查
    print("\n修完后 note 84~116 的 L3 k2/k3（dB）:")
    shp2 = shape_db(out.astype(np.float64))
    for n in range(84, 120, 4):
        print("  note %3d  k2=%6.1f  k3=%6.1f" % (n, shp2[n, 3, 1], shp2[n, 3, 2]))


if __name__ == "__main__":
    main()
