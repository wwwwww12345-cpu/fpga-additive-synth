# -*- coding: utf-8 -*-
"""
离线查表生成器 —— 整个引擎的所有 ROM 都在这里产出，Verilog 只负责 $readmemh。

六张表：
  1) sine_q15.hex          1/4 波正弦, 257 项 × 16bit (Q1.15)      <- 象限镜像 + 线性插值
  2) note_ftw.hex          128 MIDI 音 × 32bit (Q0.32 频率字)     <- FTW = 2^P * f/fs
  3) harm_amp_<tag>.hex    K 次谐波幅度 × 16bit (Q1.15, 已归一化)  <- 音色
  4) harm_decay_<tag>.hex  K 次谐波衰减 × 32bit (Q0.32, d=1-e^{-1/(tau*fs)})
  5) harm_phase_<tag>.hex  K 次谐波初始相位 × 32bit (Q0.32, 单位=整周)
  6) harm_ratio.hex        K 次谐波非谐性比 × 32bit (Q8.16, k*sqrt(1+Bk^2))

用法:
  .venv\\Scripts\\python.exe tools\\gen_tables.py                        # A1 音色, k=16, fs=48k
  .venv\\Scripts\\python.exe tools\\gen_tables.py --json tools\\partials_C1.json --tag C1
  .venv\\Scripts\\python.exe tools\\gen_tables.py --maxk 24 --inharmonic off
"""
import os
import sys
import json
import argparse
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ------------------------------------------------------------------ 参数
ap = argparse.ArgumentParser()
ap.add_argument('--json', default=os.path.join(HERE, 'partials_A1.json'))
ap.add_argument('--tag', default='A1', help='音色名, 进文件名和 report 标题')
ap.add_argument('--fs', type=float, default=48000.0, help='合成采样率 Hz')
ap.add_argument('--maxk', type=int, default=16, help='每音谐波上限 K')
ap.add_argument('--depth', type=int, default=1024, help='正弦表全周期点数(必须是 4 的倍数)')
ap.add_argument('--bits', type=int, default=16, help='正弦表字长')
ap.add_argument('--frac-bits', type=int, default=12, help='线性插值小数位数')
ap.add_argument('--headroom-db', type=float, default=1.0, help='单音峰值留多少余量')
ap.add_argument('--inharmonic', choices=['on', 'off'], default='on')
ap.add_argument('--a4', type=float, default=440.0)
ap.add_argument('--ctrl-l2', type=int, default=5, help='包络控制率: 每 2^ctrl_l2 个样本更新一次')
ap.add_argument('--outdir', default=os.path.join(ROOT, 'rtl', 'rom'))
A = ap.parse_args()

PHASE_W = 32                              # 相位累加器位宽
FS = A.fs
DEPTH = A.depth                           # 1024 -> 象限内 256 段
QUARTER = DEPTH // 4                      # 256
QN = QUARTER + 1                          # 象限表项数 257 (含 90 度端点)
SINE_FS = (1 << (A.bits - 1)) - 1         # 32767 = Q1.15 的 1.0
IDX_W = int(np.log2(DEPTH))               # 10
FRAC_W = A.frac_bits
os.makedirs(A.outdir, exist_ok=True)

rep = []
def P(s=''):
    print(s)
    rep.append(s)


# ------------------------------------------------------------------ 读测量数据
with open(A.json, 'r', encoding='utf-8') as f:
    M = json.load(f)
k_meas = M['k']
amp_meas = np.array(M['amp'], float)            # 原始幅度(可正可负)
ph_meas = np.array(M['phase_rad'], float)
tau_meas = np.array([np.nan if v is None else v for v in M['tau']], float)
f0 = float(M['f0'])
B = float(M['B'])
f_meas = np.array(M['f_meas'], float)

P(f'{"="*78}')
P(f'  音色 {A.tag}  <- {M["file"]}   音头 {M["onset"]:.3f}s')
P(f'  f0 = {f0:.4f} Hz   B = {B:.3e}   测量分音数 = {len(k_meas)}')
P(f'  目标: fs = {FS:.0f} Hz, 每音谐波 K = {A.maxk}, 相位累加器 {PHASE_W} bit')
P(f'{"="*78}')


# ------------------------------------------------------------------ 1) 正弦表
# 1/4 波: Q[i] = sin(pi/2 * i/QUARTER), i=0..QUARTER
i_q = np.arange(QN)
q = np.sin(0.5 * np.pi * i_q / QUARTER)
q_int = np.clip(np.round(q * SINE_FS), -SINE_FS - 1, SINE_FS).astype(np.int64)
p_sine = os.path.join(A.outdir, f'sine_q{A.bits}.hex')
with open(p_sine, 'w', encoding='ascii') as f:
    for v in q_int:
        f.write(f'{int(v) & ((1 << A.bits) - 1):0{A.bits // 4}X}\n')

q_pack = (q_int[1:QN].astype(np.int64) << A.bits) | (q_int[0:QN-1].astype(np.int64) & ((1<<A.bits)-1))
p_pk = np_pk = os.path.join(A.outdir, f'sine_pack_q{A.bits}.hex')
with open(np_pk, 'w', encoding='ascii') as f:
    for v in q_pack:
        f.write(f'{int(v) & 0xFFFFFFFF:08X}\n')
sine_err = np.max(np.abs(q_int / SINE_FS - q))
P(f'\n[1] 正弦表 {os.path.basename(p_sine)}: 1/4 波 {QN} 项 × {A.bits}bit')
P(f'    全周期等效 {DEPTH} 点, 量化最大误差 {sine_err:.2e} (={20*np.log10(max(sine_err,1e-12)):.1f} dBc)')
P(f'    寻址: 象限=phase[31:30]  象限内={IDX_W-2}bit=phase[29:22]  插值小数={FRAC_W}bit=phase[21:{22-FRAC_W}]')
P(f'    象限镜像: q0:=Q[m+f]  q1:=Q[QN-1-(m+f)]  q2:=-Q[m+f]  q3:=-Q[QN-1-(m+f)]')
P(f'    仅地址截断 (无插值) 理论杂散 ≈ -6.02×{IDX_W} = {-6.02*IDX_W:.1f} dBc')


# ------------------------------------------------------------------ 2) note -> FTW
notes = np.arange(128)
f_note = A.a4 * 2.0 ** ((notes - 69) / 12.0)
ftw = np.round(f_note * (1 << PHASE_W) / FS).astype(np.int64)
ftw = np.clip(ftw, 0, (1 << PHASE_W) - 1)
p_ftw = os.path.join(A.outdir, 'note_ftw.hex')
with open(p_ftw, 'w', encoding='ascii') as f:
    for v in ftw:
        f.write(f'{int(v) & 0xFFFFFFFF:08X}\n')
err_ftw = np.max(np.abs(ftw * FS / (1 << PHASE_W) - f_note))
P(f'\n[2] 音高表 {os.path.basename(p_ftw)}: 128 项 × {PHASE_W}bit  (A4 = {A.a4:.0f} Hz)')
P(f'    FTW(n) = round(2^{PHASE_W} × f(n) / fs),  f(n) = {A.a4:.0f} × 2^((n-69)/12)')
P(f'    量化后最大音高误差 {1200*np.log2(1+err_ftw/np.min(f_note)):.4f} 音分 (最低音 {f_note[0]:.3f} Hz)')
P(f'    音域 {f_note[0]:.2f} ~ {f_note[-1]:.1f} Hz')

# ------------------------------------------------------------------ 谐波数组重建 (补缺口 k)
K = A.maxk
amp_k = np.zeros(K + 1)          # 索引 1..K
ph_k = np.zeros(K + 1)
tau_k = np.full(K + 1, np.nan)
ratio_k = np.ones(K + 1)
f_k = np.zeros(K + 1)
missing = []
for k in range(1, K + 1):
    ratio_k[k] = k * np.sqrt(1.0 + B * k * k) if A.inharmonic == 'on' else float(k)
    f_k[k] = f0 * ratio_k[k]
    if k in k_meas:
        j = k_meas.index(k)
        amp_k[k], ph_k[k], tau_k[k] = amp_meas[j], ph_meas[j], tau_meas[j]
    else:
        missing.append(k)
# 缺的 k: 用左右邻居的几何插值补 (幅度), tau 用邻居均值
for k in missing:
    lo = [x for x in k_meas if x < k]
    hi = [x for x in k_meas if x > k]
    if lo and hi:
        a, b = lo[-1], hi[0]
        ja, jb = k_meas.index(a), k_meas.index(b)
        w = (k - a) / (b - a)
        amp_k[k] = float(np.exp((1 - w) * np.log(max(amp_meas[ja], 1e-9)) + w * np.log(max(amp_meas[jb], 1e-9))))
        ph_k[k] = ph_meas[ja]
        tau_k[k] = np.nanmean([tau_meas[ja], tau_meas[jb]])
    elif hi:                                   # 最低几个 k 没测到(基频太弱/被低频噪声淹没)
        jb = k_meas.index(hi[0])
        amp_k[k], ph_k[k], tau_k[k] = amp_meas[jb], ph_meas[jb], tau_meas[jb]
    elif lo:
        ja = k_meas.index(lo[-1])
        amp_k[k], ph_k[k], tau_k[k] = amp_meas[ja], ph_meas[ja], tau_meas[ja]
    else:
        amp_k[k], ph_k[k], tau_k[k] = 0.0, 0.0, np.nan
tau_nan = [k for k in range(1, K + 1) if not np.isfinite(tau_k[k])]
if np.isfinite(np.nanmedian(tau_k[1:])):
    tau_k = np.where(np.isfinite(tau_k), tau_k, np.nanmedian(tau_k[1:]))

# 归一化: 让"实测相位重建出来的波形峰值"落在 -headroom dBFS 上
def wave_peak(amp, ph, fr, n=None, fs=FS):
    """归一化用的峰值: 必须搜足够长(各分音频率不可通约, 最坏对齐要几分钟内才出现)。
       4 秒窗口已收敛到 ±0.2dB 以内, 比 1 秒窗口稳。"""
    if n is None:
        n = int(4 * fs)
    t = np.arange(n) / fs
    s = np.zeros(n)
    for kk in range(1, len(amp)):
        if amp[kk] != 0.0:
            s += amp[kk] * np.cos(2 * np.pi * fr[kk] * t + ph[kk])
    return float(np.max(np.abs(s))), float(np.sqrt(np.mean(s ** 2)))

pk_raw, rms_raw = wave_peak(amp_k, ph_k, f_k)
pk_zero, _ = wave_peak(amp_k, np.zeros_like(ph_k), f_k)
target = 10 ** (-A.headroom_db / 20.0)
scale = target / pk_raw

ref_amp = max(np.max(np.abs(amp_k[1:])), 1e-12)
P(f'\n[3] 幅度归一化 (关键: 原始幅度和是最强分音的 {np.sum(np.abs(amp_k[1:]))/ref_amp:.1f} 倍, 直接当表必然削顶)')
P(f'    实测相位重建峰值 = {pk_raw:.6f} (rms {rms_raw:.6f})  -> 缩放系数 {scale:.4f}')
P(f'    若全部零相位, 峰值会是 {pk_zero:.6f} = 实测相位的 {pk_zero/pk_raw:.2f} 倍 (白扔 {20*np.log10(pk_zero/pk_raw):.1f} dB)')
P(f'    归一化后单音峰值 = {target:.4f}  ({-A.headroom_db:+.1f} dBFS)')

amp_n = amp_k * scale
# 幅度取正, 符号并进相位 (表里只存非负幅度)
sign = np.where(amp_n < 0, -1.0, 1.0)
amp_abs = np.abs(amp_n)
ph_enc = np.mod(ph_k + np.where(sign < 0, np.pi, 0.0), 2 * np.pi)

amp_q = np.clip(np.round(amp_abs * SINE_FS), 0, SINE_FS).astype(np.int64)
ph_q = np.mod(np.round(ph_enc / (2 * np.pi) * (1 << PHASE_W)), 1 << PHASE_W).astype(np.int64)
# d = 1 - exp(-1/(tau*fs))  —— 每样本一阶 IIR: acc -= (acc*d)>>>32
with np.errstate(over='ignore'):
    d_k = 1.0 - np.exp(-1.0 / (tau_k * FS))
d_k[0] = 0.0
d_q = np.clip(np.round(d_k * (1 << 32)), 0, (1 << 32) - 1).astype(np.int64)
ratio_q = np.clip(np.round(ratio_k * (1 << 16)), 0, (1 << 32) - 1).astype(np.int64)

# 控制率衰减: 包络每 2^CTRL_L2 个样本更新一次 -> d' = 1 - exp(-2^CTRL_L2/(tau*fs))
# 这样每分量每 32 个样本只需 1 次乘法(省 32 倍), 1500Hz 的包络更新率听不出台阶
CTRL_L2 = A.ctrl_l2
with np.errstate(over='ignore'):
    d_ctrl = 1.0 - np.exp(-(2.0 ** CTRL_L2) / (tau_k * FS))
d_ctrl[0] = 0.0
d_ctrl_q = np.clip(np.round(d_ctrl * (1 << 32)), 0, (1 << 32) - 1).astype(np.int64)

def w_hex(path, arr, width_hex):
    with open(path, 'w', encoding='ascii') as f:
        for v in arr:
            f.write(f'{int(v) & ((1 << (4 * width_hex)) - 1):0{width_hex}X}\n')
    return path

p_amp = w_hex(os.path.join(A.outdir, f'harm_amp_{A.tag}.hex'), amp_q[1:], 4)
p_dec = w_hex(os.path.join(A.outdir, f'harm_decay_{A.tag}.hex'), d_q[1:], 8)
p_pha = w_hex(os.path.join(A.outdir, f'harm_phase_{A.tag}.hex'), ph_q[1:], 8)
p_rat = w_hex(os.path.join(A.outdir, f'harm_ratio_{A.tag}.hex'), ratio_q[1:], 8)   # B 是每个音色不同, 必须带 tag
p_dc  = w_hex(os.path.join(A.outdir, f'harm_decay_ctrl_{A.tag}.hex'), d_ctrl_q[1:], 8)

# 非谐性/衰减的换算表 (给人看)
P(f'\n[4] 谐波表 (K={K})  —— 幅度 Q1.15 / 相位 Q0.32 / 衰减 Q0.32')
P(f'    {"k":>3} {"f_k(Hz)":>9} {"偏音分":>8} {"amp_Q15":>8} {"amp(线性)":>10} {"phi(rad)":>8} {"tau(s)":>7} {"d=1-e^-1/taufs":>15}')
for k in range(1, K + 1):
    dev = 1200 * np.log2(f_k[k] / (k * f0)) if A.inharmonic == 'on' else 0.0
    P(f'    {k:3d} {f_k[k]:9.2f} {dev:8.1f} {amp_q[k]:8d} {amp_q[k]/SINE_FS:10.5f} {ph_enc[k]:8.3f} '
      f'{tau_k[k] if np.isfinite(tau_k[k]) else float("nan"):7.2f} {d_k[k]:15.3e}')
if missing:
    P(f'    !! 测量缺的 k = {missing}, 已用左右邻居几何插值补上')
if tau_nan:
    P(f'    !! tau 拟合失败的 k = {tau_nan}, 用了中位数 {np.nanmedian(tau_k[1:]):.2f}s 顶替')

# ------------------------------------------------------------------ 自检: 量化后还原度
t = np.arange(int(4 * FS)) / FS
ideal = np.zeros_like(t)
restored = np.zeros_like(t)
for k in range(1, K + 1):
    fq = f0 * (ratio_q[k] / (1 << 16)) if A.inharmonic == 'on' else k * f0
    ph_restore = ph_q[k] / (1 << 32) * 2 * np.pi          # 表里第 k 次谐波 = 数组下标 k
    ph_adv = 2 * np.pi * fq * t
    ideal += amp_n[k] * np.cos(2 * np.pi * f_k[k] * t + ph_k[k])
    restored += (amp_q[k] / SINE_FS) * np.cos(ph_adv + ph_restore)
err = restored - ideal
peak_r = float(np.max(np.abs(restored)))
P(f'\n[5] 量化自检 (4 秒窗口, 与归一化同长)')
P(f'    量化后峰值 {peak_r:.6f} ({20*np.log10(peak_r):+.2f} dBFS), 目标 {-A.headroom_db:+.1f} dBFS'
  f'  -> 实际保留余量 {-20*np.log10(peak_r):.2f} dB')
P(f'    与未量化版本的最大偏差 {np.max(np.abs(err)):.2e} ({20*np.log10(np.max(np.abs(err))/peak_r):+.1f} dB)')
P(f'    rms {np.sqrt(np.mean(restored**2)):.6f} ({20*np.log10(np.sqrt(np.mean(restored**2))):+.1f} dBFS)')
P(f'    => 16bit 幅度 + 32bit 相位对"波形形状"的影响 ≈ {20*np.log10(np.max(np.abs(err))/peak_r):+.0f} dB, 听不见')

# ------------------------------------------------------------------ TDM 预算
FCLK = 50e6
clk_per_sample = FCLK / FS
P(f'\n[6] TDM 预算 (fclk = {FCLK/1e6:.0f} MHz, fs = {FS:.0f} Hz)')
P(f'    每样本可用 {clk_per_sample:.1f} 个时钟')
P(f'    每音每样本需要 {K} 次查表 (正弦) + {K} 次累加')
for poly in (4, 16, 32):
    need = poly * K
    P(f'    {poly:2d} 复音 × {K} 谐波 = {need:4d} 次查表/样本  -> 占用 {100*need/clk_per_sample:5.1f}% 时钟'
      f'  {"(单口 ROM 塞得下)" if need < clk_per_sample else "(超了! 要双口读或降谐波数)"}')
P(f'    注: 高音区 kmax = floor(0.45*fs/f0) 会自然变小(如 A4 只有 {int(0.45*FS/440)} 次), 实际平均远低于 K')

# ------------------------------------------------------------------ 写报告
p_rep = os.path.join(HERE, f'tables_report_{A.tag}.txt')
with open(p_rep, 'w', encoding='utf-8') as f:
    f.write('\n'.join(rep) + '\n')
P(f'\n文件:')
for p in (p_sine, np_pk, p_ftw, p_amp, p_dec, p_pha, p_rat, p_dc):
    P(f'  {os.path.relpath(p, ROOT)}  ({os.path.getsize(p)} B)')
P(f'  {os.path.relpath(p_rep, ROOT)}')