# engine_model.py -- v3 音频引擎的整数逐位模型 + 统一测量器
# 用途: 审计 Q1~Q5。RTL 仿真太慢(0.4s 音频 ~2min), 本模型按 partial_engine.v /
#       sine_lut_full.v 的整数运算逐拍复刻, 再用一次 RTL dump 做对拍验证。
# 不做任何 RTL / rtl/rom 表修改。
#
# 结构 (每样本):
#   对每个 (层, 分音):
#     ph2  = (ph + ((ftw*ratio)>>16)) & 0xFFFFFF
#     sine = sine_lut_full(ph2)   # 1024 满表 + 线性插值 + 四舍五入(+2048)>>12
#     gn2  = gn - ((gn*dec)>>32)  # 仅当 decay_en (每 32 样本一次)
#     contrib = ((sine>>8) * gn2) >> 23
#   acc = Σ contrib ; v = (acc*adsr_g)>>15 ; out = clip(v<<8, ±2^23)
#   注: 输出移位按 active_voices=1 -> sh=8 (partial_engine.v F_FIN)
import argparse
import json
import os
import struct
import sys

import numpy as np

ROM = r"D:\piano_att\rtl\rom"
MASK24 = (1 << 24) - 1
FS = 48828.125          # I2S_INT_CLK=1, DIV=8
FTW_C4 = 89893          # note_ftw_48828[60] = 0x015F25DC >> 8


def _read_hex(name, width=None):
    path = os.path.join(ROM, name) if not os.path.isabs(name) else name
    vals = []
    with open(path, "r") as f:
        for line in f:
            s = line.strip()
            if s:
                vals.append(int(s, 16))
    return np.array(vals, dtype=np.int64)


def load_tables(amp_file=None, dec_file=None, corr_file=None):
    ratio = _read_hex("harm_ratio_C4.hex")
    amp_raw = _read_hex(amp_file or "harm_amp_vel_C4.hex")
    # 2026-10-21: 支持按八度的多段幅度表 (OCT 段 × VEL_LAYERS × PARTIALS)
    if amp_raw.size == 128 * 4 * 16:
        amp = amp_raw.reshape(128, 4, 16)    # 每音一张表 × 4 力度层
    elif amp_raw.size == 128 * 8 * 16:
        amp = amp_raw.reshape(128, 8, 16)    # 每音一张表
    elif amp_raw.size == 32 * 8 * 16:
        amp = amp_raw.reshape(32, 8, 16)     # 每 4 个半音一段
    elif amp_raw.size == 8 * 8 * 16:
        amp = amp_raw.reshape(8, 8, 16)      # 八度 2..7 各一段 + 重复段
    elif amp_raw.size == 4 * 8 * 16:
        amp = amp_raw.reshape(4, 8, 16)
    else:
        amp = amp_raw.reshape(8, 16)
    pha = _read_hex("harm_phase_C4.hex")
    dec = _read_hex(dec_file or "harm_decay_ctrl_C4.hex")
    sine = _read_hex("sine_full_1024_q23.hex")
    corr = None
    if corr_file:
        corr = _read_hex(corr_file).reshape(128, 16)
    assert len(ratio) == 16 and amp.shape[-1] == 16 and len(dec) == 16
    assert len(sine) == 1024
    # 24-bit signed
    sine = np.where(sine >= (1 << 23), sine - (1 << 24), sine).astype(np.int64)
    pha24 = (pha >> 8) & MASK24
    return dict(ratio=ratio, amp=amp, pha=pha24, dec=dec, sine=sine, corr=corr)


def note_of_ftw(ftw):
    """按频率字反查最近的 MIDI 音号（与 note_ftw_48828 表最近邻）"""
    tab = _read_hex("note_ftw_48828.hex") >> 8
    return int(np.argmin(np.abs(tab - int(ftw))))


# 八度选段阈值 (与 partial_engine.v 的 OCT_TABLES 一致): C3/C4/C5/C6/C7 的 ftw
OCT_FTW = (44946, 89893, 179787, 359575, 719150)


def amp_octave(ftw):
    idx = 0
    for thr in OCT_FTW:
        if ftw < thr:
            return idx
        idx += 1
    return idx


def _sign24(x):
    x = x & MASK24
    return np.where(x >= (1 << 23), x - (1 << 24), x).astype(np.int64)


def render(t, layers, n_samples, adsr=(10923, 9, 0, 119), decay_on=True,
           tick_phase=0, g0=0, adsr_state=1, ftw=FTW_C4, release_at=None,
           rel_rate=0, rel_floor=32, vel=None, atk_noise=0, atk_dec=0, note_vel=127):
    """返回 (L, n_samples) int64 引擎样本(未做 -12dB)。
    layers: 层号列表; 同一批共享 ADSR/decay/ftw, 但各自 amp 初值。
    tick_phase: 模型第 0 个样本对应引擎 samp_cnt 的值 (0..31)。
    release_at: 若给, 在该样本触发抬键。
    rel_rate: 0=线性(旧行为, 用 r_inc); >0=指数释放(与 RTL 的 REL_RATE 一致)。
    """
    a_inc, d_inc, sus, r_inc = adsr
    amp_all = t["amp"]
    if amp_all.ndim == 3:
        if amp_all.shape[0] == 128:           # 每音一张表
            amp = amp_all[note_of_ftw(ftw)][layers]
        elif amp_all.shape[0] == 32:          # 每 4 半音一段
            amp = amp_all[note_of_ftw(ftw) >> 2][layers]
        else:                                 # 8 段八度表
            amp = amp_all[amp_octave(ftw)][layers]
    else:
        amp = amp_all[layers]                 # (L,16)
    if t.get("corr") is not None:             # 按音修正（128×16，8 bit）
        n = note_of_ftw(ftw)
        amp = (amp * t["corr"][n][None, :]) >> 8
    L = amp.shape[0]
    ph = np.tile(t["pha"], (L, 1))            # (L,16) 24bit
    if vel is None:
        gn = amp << 8                             # Q1.23 (VEL_LAYERS=8)
    else:
        gn = (amp * vel) << 1                     # VEL_LAYERS=1: amp*vel*2
    dec = t["dec"][None, :]                   # (1,16)
    ratio = t["ratio"][None, :]
    sine = t["sine"]
    ftwk = ((ftw * ratio) >> 16) & MASK24     # (1,16)

    ag = np.full(L, g0, dtype=np.int64)
    ags = np.zeros(L, dtype=np.int64)
    st = np.full(L, adsr_state, dtype=np.int64)   # 1=attack 2=decay 3=sustain 0=off
    rel = np.zeros(L, dtype=bool)
    out = np.empty((L, n_samples), dtype=np.int64)
    import os
    _rom_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'piano_att', 'rtl', 'rom', 'atk_noise_rom.hex')
    _rom = []
    with open(_rom_path) as _fh:
        for _ln in _fh:
            _v = int(_ln.strip(), 16)
            _rom.append(_v - 65536 if _v >= 32768 else _v)
    atk_env = 0
    atk_tgt = 0
    atk_done = True
    lfsr = 0xACE1

    for i in range(n_samples):
        if i == 0:
            atk_tgt = (atk_noise * note_vel) >> 7
            atk_done = False
            atk_scale = 32767 if atk_tgt > 32767 else atk_tgt
            atk_pos = 0
            atk_act = True
        # 音头噪声: LFSR 每样本推进一次 (与 RTL 在 sample_req 沿推进一致)
        bit = ((lfsr >> 15) ^ (lfsr >> 13) ^ (lfsr >> 12) ^ (lfsr >> 10)) & 1
        lfsr_old = lfsr
        lfsr = ((lfsr << 1) | bit) & 0xFFFF
        if release_at is not None and i == release_at:
            rel = np.ones(L, dtype=bool)
            st = np.where(st != 0, 3, st)
        if ((i + tick_phase) % 32) == 0:
            # ADSR 扫描 (partial_engine.v 段 3)
            att = (st == 1)
            decs = (st == 2)
            relm = rel & (st == 3)
            hit_att = (ag + a_inc >= 0x7FFF)
            hit_dec = (ag <= sus + d_inc)
            if rel_rate > 0:
                hit_rel = (ag <= rel_floor)
                rel_dec = (ag * rel_rate) >> 15
            else:
                hit_rel = (ag <= r_inc)
                rel_dec = np.full(L, r_inc, dtype=np.int64)
            ag = np.where(att, np.where(hit_att, 0x7FFF, ag + a_inc),
                          np.where(decs, np.where(hit_dec, sus, ag - d_inc),
                                   np.where(relm, np.where(hit_rel, 0, ag - rel_dec), ag)))
            st = np.where(att, np.where(hit_att, 2, 1),
                          np.where(decs, np.where(hit_dec, 3, 2), st))
            rel = rel & ~(relm & hit_rel)
            if decay_on:
                gn = gn - ((gn * dec) >> 32)
            if atk_act and atk_dec:                 # 2026-10-26: RTL 里每 32 样本衰减 ATK_DEC
                atk_scale = atk_scale - atk_dec if atk_scale > atk_dec else 0
            if atk_dec and atk_done:
                atk_env = atk_env - atk_dec if atk_env > atk_dec else 0
            elif (not atk_done) and atk_env < atk_tgt:
                atk_env = atk_env + (atk_tgt >> 6)
                if atk_env >= atk_tgt:
                    atk_done = True
        elif (not atk_done) and atk_env < atk_tgt:
            atk_env = atk_env + (atk_tgt >> 6)
            if atk_env >= atk_tgt:
                atk_done = True

        ph2 = (ph + ftwk) & MASK24
        idx = (ph2 >> 14).astype(np.int64)
        frac = (ph2 >> 2) & 0xFFF
        r_hi = sine[idx]
        r_lo = sine[(idx + 1) & 1023]
        ival = (r_hi * 4096 + (r_lo - r_hi) * frac + 2048) >> 12
        s16 = _sign24(ival) >> 8
        contrib = (s16 * gn) >> 23
        acc = contrib.sum(axis=1)
        v = (acc * ags) >> 15
        o = v << 8
        if atk_act:
            o = o + ((_rom[atk_pos] * atk_scale) >> 12)
            atk_pos += 2
            if atk_pos >= 254:
                atk_act = False
        o = np.clip(o, -8388608, 8388607)
        out[:, i] = o
        ags = ags + ((ag - ags) >> 3)
        ph = ph2

    return out


# ---------------------------------------------------------------- AIFF 读取
def read_aiff(path):
    """返回 (float64 (n,ch), fs, bitdepth)。支持 16/24/32-bit 大端 PCM。"""
    with open(path, "rb") as f:
        data = f.read()
    assert data[0:4] == b"FORM" and data[8:12] == b"AIFF", "not AIFF"
    pos = 12
    ch = bits = nframes = None
    fs = None
    ssnd = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        sz = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + sz]
        if cid == b"COMM":
            ch, nframes, bits = struct.unpack(">HIH", body[0:8])
            fs = _ext80(body[8:18])
        elif cid == b"SSND":
            off = struct.unpack(">I", body[0:4])[0]
            ssnd = body[8 + off:]
        pos += 8 + sz + (sz & 1)
    assert ssnd is not None and ch and bits
    if bits == 16:
        x = np.frombuffer(ssnd[:nframes * ch * 2], dtype=">i2").astype(np.float64) / 32768.0
    elif bits == 24:
        b = np.frombuffer(ssnd[:nframes * ch * 3], dtype=np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) << 16) | (b[:, 1].astype(np.int32) << 8) | b[:, 2]
        v = np.where(v >= (1 << 23), v - (1 << 24), v)
        x = v.astype(np.float64) / (1 << 23)
    elif bits == 32:
        x = np.frombuffer(ssnd[:nframes * ch * 4], dtype=">i4").astype(np.float64) / (1 << 31)
    else:
        raise ValueError("bits=%d" % bits)
    return x.reshape(-1, ch), fs, bits


def _ext80(b):
    if b == b"\x00" * 10:
        return 0.0
    expon = ((b[0] & 0x7F) << 8) | b[1]
    mant = 0
    for c in b[2:10]:
        mant = (mant << 8) | c
    sign = -1 if (b[0] & 0x80) else 1
    if expon == 0 and mant == 0:
        return 0.0
    return sign * mant * 2.0 ** (expon - 16383 - 63)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        t = load_tables()
        for l in range(8):
            a = t["amp"][l]
            print("layer%d k1=%d k5/k1=%.2f%% sum=%d" % (
                l, a[0], 100.0 * a[4] / max(a[0], 1), a.sum()))
        y = render(t, [7], 2000)
        print("render ok", y.shape, y.min(), y.max())
