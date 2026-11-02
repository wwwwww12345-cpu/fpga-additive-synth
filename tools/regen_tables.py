# regen_tables.py -- 重出 harm_amp_vel_C4.hex 与 harm_decay_ctrl_C4.hex（只写暂存目录）
#
# 口径（与审计报告 109/112/113 一致）:
#   * 分音幅度：频域功率合并 sqrt(|XL|^2+|XR|^2)，窗 = 各自 onset+0.15s，长 0.3s，Hann
#   * 表值 = 该力度在 t=0 的初始幅度 = 窗内实测幅度 × exp(t_mid/τ)，t_mid=0.30s
#     （引擎用指数衰减，只有把窗内电平反推回 onset 才是"初始化增益"）
#   * τ 用 mf 的实测值（RTL 只有一张 dec 表），dec = 2^32/(1525.9·τ)
#   * 三层锚点：layer0=pp, layer4=mf, layer7=ff；层间按 dB 线性插值
#   * 绝对定标：最后把层7 的引擎峰值缩放到与现表完全一致，保证 -12dB 口径不变
#
# 输出（不碰 rtl/rom）:
#   tools/staging/harm_amp_vel_C4_new.hex
#   tools/staging/harm_decay_ctrl_C4_new.hex
#   evidence/114_regen_tables.json
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, r"D:\采样音色\tools")
from engine_model import read_aiff, load_tables, render   # noqa: E402
from audit_run import measure_partials, F0                 # noqa: E402

FS = 48828.125
STAGE = r"D:\采样音色\tools\staging"
EV = r"D:\采样音色\evidence"
T_MID = 0.30
TARGET_FF_PEAK = 6155008          # 现表层7 峰值 (audit_run 实测)
GT = [("pp", r"D:\采样音色\Piano.pp.C4.aiff", 0.469),
      ("mf", r"D:\采样音色\Piano.mf.C4.aiff", 0.329),
      ("ff", r"D:\采样音色\Piano.ff.C4.aiff", 0.529)]


def amp_meas(path, onset):
    x, sr, bits = read_aiff(path)
    L = x[:, 0]
    R = x[:, 1] if x.shape[1] > 1 else x[:, 0]
    parts, cen, _ = measure_partials(L, R, sr, onset)
    return np.array([p["amp"] for p in parts], dtype=float), cen


def main():
    os.makedirs(STAGE, exist_ok=True)
    d113 = json.load(open(os.path.join(EV, "113_decay_tau.json"), encoding="utf-8"))
    tau_mf = np.array([(p["tau_s"] if p["tau_s"] else 0.5)
                       for p in d113["gt"]["mf"]["parts"]], dtype=float)
    tau_mf = np.clip(tau_mf, 0.15, 2.0)
    taub = []
    for nm, _, _ in GT:
        t = np.array([(p["tau_s"] if p["tau_s"] else 0.5)
                      for p in d113["gt"][nm]["parts"]], dtype=float)
        taub.append(np.clip(t, 0.15, 2.0))
    print("tau_mf:", " ".join("%.2f" % v for v in tau_mf))

    A = []
    cen = {}
    for nm, path, onset in GT:
        a, c = amp_meas(path, onset)
        cen[nm] = c
        A.append(a)
        print("%s centroid=%.0f Hz  k1=%.4g" % (nm, c, a[0]))
    A = np.array(A)                             # (3,16)

    # 反推到 t=0：引擎用 mf 的 τ 衰减所有层，所以统一用 tau_mf 反推
    A0 = A * np.exp(T_MID / tau_mf)[None, :]

    # 归一化：ff 的 k1 -> 12597（先给个初值，最后再按峰值细调）
    scale0 = 12597.0 / A0[2, 0]
    A0 *= scale0

    # 层间 dB 线性插值
    layers_db = np.zeros((8, 16))
    for k in range(16):
        db_pp, db_mf, db_ff = [20 * math.log10(max(v, 1e-9)) for v in (A0[0, k], A0[1, k], A0[2, k])]
        for l in range(8):
            if l <= 4:
                db = db_pp + (db_mf - db_pp) * l / 4.0
            else:
                db = db_mf + (db_ff - db_mf) * (l - 4) / 3.0
            layers_db[l, k] = db
    tbl = np.power(10.0, layers_db / 20.0)

    # 峰值定标：用现 ADSR 渲染层7，把峰值对齐到 TARGET_FF_PEAK
    dec = np.round(2.0 ** 32 / (1525.9 * tau_mf)).astype(np.int64)
    dec = np.clip(dec, 1, 2 ** 32 - 1)

    def quantize(t):
        return np.clip(np.round(t), 0, 65535).astype(np.int64)

    def write_hex(amp_t, dec_t, tag):
        p1 = os.path.join(STAGE, "harm_amp_vel_C4_%s.hex" % tag)
        p2 = os.path.join(STAGE, "harm_decay_ctrl_C4_%s.hex" % tag)
        with open(p1, "w", newline="\n") as f:
            for l in range(8):
                for k in range(16):
                    f.write("%04X\n" % int(amp_t[l, k]))
        with open(p2, "w", newline="\n") as f:
            for k in range(16):
                f.write("%08X\n" % int(dec_t[k]))
        return p1, p2

    t0 = load_tables()
    peaks = {}
    for it in range(3):
        amp_t = quantize(tbl)
        p1, p2 = write_hex(amp_t, dec, "tmp")
        tn = load_tables(amp_file=p1, dec_file=p2)
        y = render(tn, [7], int(2.6 * FS), adsr=(10923, 9, 0, 119), decay_on=True)[0]
        pk = int(np.max(np.abs(y)))
        print("iter%d scale=%.4f  ff_peak=%d  clip=%d" % (
            it, tbl[7, 0], pk, int(np.sum(np.abs(y) >= 8388607))))
        if abs(pk - TARGET_FF_PEAK) <= 2000:
            break
        tbl *= TARGET_FF_PEAK / pk
    amp_t = quantize(tbl)
    p1, p2 = write_hex(amp_t, dec, "new")

    # 报告：三层锚点的表值 vs 现表
    old = t0["amp"]
    print("\nlayer 0  k1..k8  新:", amp_t[0, :8].tolist(), " 旧:", old[0, :8].tolist())
    print("layer 4  k1..k8  新:", amp_t[4, :8].tolist(), " 旧:", old[4, :8].tolist())
    print("layer 7  k1..k8  新:", amp_t[7, :8].tolist(), " 旧:", old[7, :8].tolist())
    print("dec 新:", dec.tolist())
    print("dec 旧:", t0["dec"].tolist())

    json.dump(dict(tau_mf=tau_mf.tolist(), dec_new=dec.tolist(),
                   amp_new=amp_t.tolist(), amp_old=old.tolist(),
                   centroid_gt=cen),
              open(os.path.join(EV, "114_regen_tables.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("\nWROTE", p1, p2)


if __name__ == "__main__":
    main()
