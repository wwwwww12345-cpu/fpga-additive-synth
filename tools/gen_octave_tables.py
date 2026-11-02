# gen_octave_tables.py -- 生成"按八度"的钢琴幅度表（v16：八度 2..7 各一张）
#
# 数据：tools/octave_shapes.json（Iowa mf 采样实测，每八度 C/E/G/B 平均）
# 基准：v12 的 harm_amp_vel_C4.hex（与 C4 采样 0 LSB 拟合）
# 规则：新表 = 旧表 × 10^(Δ/20)，Δ = clip(目标八度包络 − 当前合成包络, −60, +10)
#       —— 高音只衰减；低音（C2/C3）需要**提升**谐波（原声 k2 比 k1 还强），所以允许 +10 dB。
#
# 段序（RTL 8 段）：0=C2 八度, 1=C3, 2=C4, 3=C5, 4=C6, 5=C7, 6/7=重复 C7
# 输出：tools/tables_v13/harm_amp_vel_oct.hex（8×128 行）并落盘到 piano_att/rtl/rom
#
# 用法: .venv\Scripts\python.exe tools/gen_octave_tables.py
import json
import os
import sys

import numpy as np
from scipy.signal import resample_poly

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import _read_hex, load_tables, render  # noqa: E402
from analyze_octave_shapes import spec_mag, harm_levels  # noqa: E402

ROOT = r"D:\采样音色"
OUT = os.path.join(ROOT, "tools", "tables_v13")
FS = 48000.0
FS_ENG = 48828.125
FLOOR = -75.0           # 实测噪声底：低于它的当静音
MAX_CUT = -60.0         # 单个分音最多砍 60 dB
MAX_BOOST = 10.0        # 低音最多抬 10 dB（原声低音的 k2/k3 比基频强）
OCT_TARGET = {0: "2", 1: "3", 2: "4", 3: "5", 4: "6", 5: "7"}
OCT_WEIGHTS = {3: {"C5": 1, "E5": 1}}   # 八度 5 按用户重点听的 C5/E5 加权


def synth_shape():
    """当前 v12 合成的谐波包络（与实测同口径）"""
    t = load_tables()
    ftw = int(_read_hex("note_ftw_48828.hex")[60]) >> 8
    y = render(t, [4], int(2.0 * FS_ENG), adsr=(10923, 9, 0, 119), decay_on=True,
               ftw=ftw, atk_noise=42000, atk_dec=1638, note_vel=72)[0].astype(np.float64) / 8388608
    from math import gcd
    g = gcd(48000, 48828)
    y = resample_poly(y, 48000 // g, 48828 // g)
    y = np.repeat(y[:, None], 2, axis=1)
    f, mag = spec_mag(y, FS)
    f0 = ftw * FS_ENG / (1 << 24)
    return harm_levels(mag, f, f0)


def peak_estimate(tab, note, layer=7):
    """用 1/4 表渲染估算真实峰值（避免直接渲染被削顶测不准）"""
    b = load_tables()
    t = dict(b)
    t["amp"] = np.maximum((np.asarray(tab) / 4.0).astype(np.int64), 0)
    ftw = int(_read_hex("note_ftw_48828.hex")[note]) >> 8
    y = render(t, [layer], int(1.2 * FS_ENG), adsr=(10923, 9, 0, 119), decay_on=True,
               ftw=ftw, atk_noise=42000, atk_dec=1638, note_vel=127)[0]
    return float(np.abs(y).max()) * 4.0


def main():
    os.makedirs(OUT, exist_ok=True)
    shp = json.load(open(os.path.join(ROOT, "tools", "octave_shapes.json"), encoding="utf-8"))
    S = synth_shape()
    print("当前合成包络 S:", " ".join("%6.1f" % v for v in S))

    old = _read_hex(os.path.join(r"D:\piano_att\rtl\rom", "harm_amp_vel_C4.hex")).reshape(8, 16)
    lvl = np.maximum(old.astype(np.float64), 1e-9)

    def write_hex(path, tab):
        with open(path, "w", newline="\n") as f:
            for l in range(8):
                for k in range(16):
                    f.write("%04X\n" % int(max(0, min(65535, tab[l, k]))))

    corr = {}
    segs = []
    for seg, key in OCT_TARGET.items():
        if seg in OCT_WEIGHTS:
            w = OCT_WEIGHTS[seg]
            names = list(w)
            mats = np.array([shp["notes"][n]["levels"] for n in names], dtype=np.float64)
            ww = np.array([w[n] for n in names], dtype=np.float64)[:, None]
            lin = (np.nansum(ww * 10 ** (mats / 20.0), axis=0)
                   / np.nansum(ww * (~np.isnan(mats)), axis=0))
            T = np.maximum(20 * np.log10(lin + 1e-15), FLOOR)
            print("seg%d(八度 %s) 目标 = 加权平均 %s" % (seg, key, w))
        else:
            T = np.array([FLOOR if v is None else max(float(v), FLOOR)
                          for v in shp["octave_mean_lin"][key]])
        d = np.clip(T - S, MAX_CUT, MAX_BOOST)
        new = np.round(lvl * (10 ** (d / 20.0))).astype(np.int64)
        new = np.clip(new, 0, 65535)
        zero_cols = np.where(T <= -70.0)[0]
        if len(zero_cols):
            new[:, zero_cols] = 0
        # 峰值保护 + 各八度等响度：按 layer7 估峰值，整段缩放到目标（0.40 FS @ layer6 由 layer7 近似）
        seg_note = {0: 36, 1: 48, 2: 60, 3: 72, 4: 84, 5: 96}[seg]
        pk = peak_estimate(new, seg_note)
        g = 0.55 * 8388608 / max(pk, 1.0)
        new = np.maximum(np.minimum(np.round(new * g), 65535), 0).astype(np.int64)
        print("seg%d 峰值 %.2f FS -> 整段 ×%.2f（目标 0.55 FS @ layer7）"
              % (seg, pk / 8388608.0, g))
        write_hex(os.path.join(OUT, "harm_amp_vel_oct%d.hex" % seg), new)
        corr["oct%d" % seg] = dict(target=[round(float(v), 2) for v in T],
                                   delta_db=[round(float(v), 2) for v in d])
        print("seg%d(八度 %s) 目标:" % (seg, key), " ".join("%6.1f" % v for v in T))
        print("seg%d(八度 %s) 修正:" % (seg, key), " ".join("%6.1f" % v for v in d))
        segs.append(new)

    # 8 段：6/7 段重复八度 7（C7 以上）
    segs.append(segs[5])
    segs.append(segs[5])
    comb = []
    for o in range(8):
        tab = segs[o]
        for l in range(8):
            for k in range(16):
                comb.append("%04X" % int(max(0, min(65535, tab[l, k]))))
    p_comb = os.path.join(OUT, "harm_amp_vel_oct.hex")
    with open(p_comb, "w", newline="\n") as f:
        f.write("\n".join(comb) + "\n")
    print("WROTE %s (%d lines)" % (p_comb, len(comb)))
    p_rom = os.path.join(r"D:\piano_att\rtl\rom", "harm_amp_vel_oct.hex")
    with open(p_rom, "w", newline="\n") as f:
        f.write("\n".join(comb) + "\n")
    print("WROTE %s" % p_rom)

    with open(os.path.join(OUT, "corrections.json"), "w", encoding="utf-8") as f:
        json.dump(dict(synth=S.tolist(), **corr), f, ensure_ascii=False, indent=1)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
