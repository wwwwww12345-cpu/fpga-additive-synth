# -*- coding: utf-8 -*-
"""
gen_vel_layers.py —— 力度分层幅度表生成器 (离线)

从同一音 (A1) 的 pp / mf / ff 三层实测参数出发, 在**幅度域按 dB 插值**出 8 层的
幅度表, 输出**一个** hex 文件:

    rtl/rom/harm_amp_vel_<note>.hex     8 层 × 16 项 × 16bit (Q1.15) = 128 项 = 256 B

RTL 侧寻址: addr = layer*PARTIALS + k,  layer = clamp(param_vel >> 4, 0, 7)
  (layer 3bit, k 4bit -> 拼接索引自然范围 128, 见 handoff 坑 14: 步长 = 2^(k 位宽) = 16)

------------------------------------------------------------------------------
归一化基准 (关键取舍, 写进 docs/tables_spec.md)
------------------------------------------------------------------------------
三层用**同一个全局缩放系数** S, S 由"ff 层实测波形重建出来的峰值 = -1 dBFS"定出:

    ff 层  ->  峰值 = -1 dBFS = **现行 mf 表的峰值** (= 已验收基线的刻度)
    mf / pp -> 依次更轻, 层间电平差 = 三层**未归一化**重建波形的 rms 之比 (实测)

  为什么以 ff = 现行基准 (而不是让 mf = 现行基准):
    32 音齐奏的最坏情况与已验收基线完全一致, 不引入新的削顶风险;
    力度变化体现为"轻奏更轻", 而不是"重奏更响"。

  为什么必须用"全局单一缩放"而不是"逐层各自归一到 -1dBFS":
    pp 的 crest(峰值/rms) 比 ff 小 (pp 没有强音头、高次分音也弱), 各自归一到同一
    峰值后 pp 的 rms 反而更大 —— 会得到"轻奏比强奏响"的反向结果。全局单一缩放
    才能保住录音实测的方向 (实测 pp 比 ff 低约 32 dB)。

  于是 mf 层 ≈ 旧表 × 10^(db_mf/20) —— 这是**设计选择**, 不是误差, 报告里会打印。
  代价(诚实记录): 单个 mf 音会比现在轻约 8 dB (因为 ff 占了满刻度); 换来的是
  真实的力度->响度动态, 且 32 音最坏情况不变。

------------------------------------------------------------------------------
映射 (layer = vel>>4)
------------------------------------------------------------------------------
  layer:   0    1    2    3    4    5    6    7
  vel:   0-15 16-31 32-47 48-63 64-79 80-95 96-111 112-127
  pp 锚点 = layer 0, mf 锚点 = layer 4, ff 锚点 = layer 7
  锚点之间在 dB 域线性插值 (电平), 在 log 幅度域线性插值 (频谱形状)。

用法:
  .venv\\Scripts\\python.exe tools\\gen_vel_layers.py --dry-run          # 只看数字, 不写文件
  .venv\\Scripts\\python.exe tools\\gen_vel_layers.py                     # 写 rtl/rom/harm_amp_vel_A1.hex
  .venv\\Scripts\\python.exe tools\\gen_vel_layers.py --note A1 --out rtl/rom/xxx.hex
  .venv\\Scripts\\python.exe tools\\gen_vel_layers.py --report-only      # 只出报告
"""
import os
import sys
import json
import argparse
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ap = argparse.ArgumentParser()
ap.add_argument('--note', default='A1', help='音名 (采样文件 Piano.<layer>.<note>.aiff)')
ap.add_argument('--layers', type=int, default=8, help='输出层数 (RTL 侧 layer=vel>>4 固定 8)')
ap.add_argument('--maxk', type=int, default=16, help='每音谐波上限 K (必须与 RTL PARTIALS 一致)')
ap.add_argument('--fs', type=float, default=48000.0)
ap.add_argument('--headroom-db', type=float, default=1.0)
ap.add_argument('--inharmonic', choices=['on', 'off'], default='on')
ap.add_argument('--v-pp', type=int, default=0,   help='pp 锚点对应的层号')
ap.add_argument('--v-mf', type=int, default=4,   help='mf 锚点对应的层号')
ap.add_argument('--v-ff', type=int, default=7,   help='ff 锚点对应的层号')
ap.add_argument('--vel-span-db', type=float, default=None,
                help='把实测的 pp..ff 动态范围**压缩**到指定 dB (None=不压缩, 原样使用实测值)。'
                     '为什么要这个: 采样库里 ff 比 mf 响 14.5dB、比 pp 响 80dB; 若原样搬进表, '
                     'mf 会比旧单层固件轻 14.5dB、pp 只有 -84dBFS(实际听不见)。'
                     '合成器惯例是"力度主要改音色, 响度只给 30~40dB 范围"。'
                     '建议 36 (= 36dB 跨度): mf 落在约 -6.5dB, 与旧固件响度接近。')
ap.add_argument('--out', default=None)
ap.add_argument('--clamp-margin-db', type=float, default=6.0, dest='clamp_margin_db',
                help='上限钳位余量: 拟合出的分音幅度若高于"该频点实测带能量(dB, 相对本层 k=1)"+此余量, '
                     '就钳到上限。数据来自 tools/band_levels_<note>.json (由 diag_vel_brightness.py 生成)。'
                     '0 = 关闭钳位。')
ap.add_argument('--no-clamp', action='store_true', help='等价于 --clamp-margin-db 0')
ap.add_argument('--clamp-snr-min', type=float, default=45.0, dest='clamp_snr_min',
                help='钳位只在该分音"实测带能量"对噪声底 SNR >= 此值(默认 45dB)时才生效。'
                     '噪声主导的读数不能当天花板(实测 pp k=4..7 的读数只有 20~29dB SNR)。'
                     '0 = 关闭该门槛(旧行为)。')
ap.add_argument('--anchor-src', choices=['band', 'fit'], default='band',
                help='层电平锚点来源: band=直测窗rms(diag_vel_brightness.py, 推荐) / fit=拟合rms(pp 层已崩, 仅作对比)')
ap.add_argument('--db-anchor', default=None,
                help='显式指定三层电平锚点(相对 ff, dB), 例: "pp=-24,mf=-5,ff=0"。'
                     '给了它就跳过上面的自动锚点(用于"响度跟旧速度律、音色跟采样层"这类设计)。')
ap.add_argument('--ref-tag', default=None,
                help='对账用的参考单层表: 可给文件名 (harm_amp_A1.hex) 或 gen_tables.py 的 --tag。'
                     '用来证明"本工具的归一化/量化代码 = 已验收的 gen_tables 逻辑"')
ap.add_argument('--dry-run', action='store_true')
ap.add_argument('--report-only', action='store_true')
A = ap.parse_args()

K = A.maxk
NL = A.layers
SINE_FS = 32767.0            # Q1.15 的 1.0
TARGET = 10 ** (-A.headroom_db / 20.0)      # -1 dBFS = 0.8913

if A.no_clamp:
    A.clamp_margin_db = 0.0
# 直测带能量 (上限钳位用; 由 tools/diag_vel_brightness.py 生成, 缺了则不做钳位)
BAND = None
_bp = os.path.join(HERE, f'band_levels_{A.note}.json')
if os.path.exists(_bp):
    with open(_bp, 'r', encoding='utf-8') as _f:
        BAND = json.load(_f)
PHASE_W = 32

rep = []
def P(s=''):
    print(s)
    rep.append(s)


# ------------------------------------------------------------------ 读三层参数
def load_layer(tag):
    """优先读 tools/partials_<tag>.json; mf 层可回落到旧的 partials_<note>.json
       (那份就是 mf 录音测出来的, 是已验收基线的源头)。"""
    p = os.path.join(HERE, f'partials_{tag}.json')
    if os.path.exists(p):
        with open(p, 'r', encoding='utf-8') as f:
            return json.load(f), os.path.basename(p)
    if tag == f'mf{A.note}':
        p2 = os.path.join(HERE, f'partials_{A.note}.json')
        if os.path.exists(p2):
            with open(p2, 'r', encoding='utf-8') as f:
                return json.load(f), os.path.basename(p2) + ' (回落, 即 mf 录音)'
    return None, None


LAYER_TAGS = {'pp': f'pp{A.note}', 'mf': f'mf{A.note}', 'ff': f'ff{A.note}'}
M = {}
M_SRC = {}
for lname, tag in LAYER_TAGS.items():
    M[lname], M_SRC[lname] = load_layer(tag)

P('=' * 78)
P(f'  力度分层幅度表生成器  ——  音 {A.note}, K = {K}, 层数 = {NL}')
P('=' * 78)
P('')
P('实测参数来源:')
missing = []
for lname, tag in LAYER_TAGS.items():
    m = M[lname]
    if m is None:
        missing.append(f'tools/partials_{tag}.json')
        P(f'  {lname:>3}  !! 缺 tools/partials_{tag}.json  (需先跑 analyze_partials.py {tag})')
    else:
        P(f'  {lname:>3}  tools/{M_SRC[lname]}')
        P(f'        <- {m["file"]}   f0 = {m["f0"]:.4f} Hz   B = {m["B"]:.3e}   '
          f'onset = {m["onset"]:.4f}s   测得分音 {len(m["k"])} 个')
        P(f'        sha256 = {m.get("sha256", "(旧档未记录)")}')

# 缺文件不报错, 只是没法算; --dry-run 只要有 mf 就能看数字
if all(M[l] is None for l in M):
    P('')
    P('!! 三层参数一个都没有, 退出')
    sys.exit(1)

if missing:
    P('')
    P(f'!! 缺 {len(missing)} 份测量: {missing}')


# ------------------------------------------------------------------ 缺 k 的补法(与 gen_tables.py 完全一致)
def build_amp_k(m):
    """复现 gen_tables.py 的"补缺口 k"逻辑, 返回长度 K+1 的幅度数组(索引 1..K)。"""
    k_meas = list(m['k'])
    amp_meas = np.array(m['amp'], float)
    amp_k = np.zeros(K + 1)
    for k in range(1, K + 1):
        if k in k_meas:
            amp_k[k] = amp_meas[k_meas.index(k)]
    for k in range(1, K + 1):
        if k in k_meas:
            continue
        lo = [x for x in k_meas if x < k]
        hi = [x for x in k_meas if x > k]
        if lo and hi:
            a, b = lo[-1], hi[0]
            ja, jb = k_meas.index(a), k_meas.index(b)
            w = (k - a) / (b - a)
            amp_k[k] = float(np.exp((1 - w) * np.log(max(amp_meas[ja], 1e-9))
                                    + w * np.log(max(amp_meas[jb], 1e-9))))
        elif hi:
            amp_k[k] = amp_meas[k_meas.index(hi[0])]
        elif lo:
            amp_k[k] = amp_meas[k_meas.index(lo[-1])]
        else:
            amp_k[k] = 0.0
    return amp_k


def fk_of(m, k):
    ratio = k * np.sqrt(1.0 + float(m['B']) * k * k) if A.inharmonic == 'on' else float(k)
    return float(m['f0']) * ratio


def wave_peak_rms(chans, n=None, fs=None):
    """各分音以实测相位累加, 搜 4 秒窗口的峰值/有效值(与 gen_tables.py 同法)。"""
    fs = fs or A.fs
    if n is None:
        n = int(4 * fs)
    t = np.arange(n) / fs
    s = np.zeros(n)
    for amp, f, ph in chans:
        if amp != 0.0:
            s += amp * np.cos(2 * np.pi * f * t + ph)
    return float(np.max(np.abs(s))), float(np.sqrt(np.mean(s ** 2)))


# ------------------------------------------------------------------ 每层的"形状"与"电平"
info = {}
for lname in ('pp', 'mf', 'ff'):
    m = M[lname]
    if m is None:
        continue
    amp_k = build_amp_k(m)

    # ---- 上限钳位: 拟合幅度不得超过该频点"实测带能量"+余量 ----
    # 依据: tools/diag_vel_brightness.py 直测(每层 16 个分音在其 ±2% 带内的峰值)。
    # pp 层整层只比录音噪声底高 ~13dB, 高次分音比基频低 40~70dB -> 拟合会把**噪声**当分音,
    # 实测 pp 拟合表在 k=12 给出 -0.1dB(几乎等于基频)的荒谬值, 导致"轻奏比强奏亮"的假象。
    # 物理约束: 某分音的真实幅度不可能超过该频点的带内实测能量 -> 超出即钳到上限。
    if BAND is not None and lname in BAND['layers'] and A.clamp_margin_db > 0:
        bl = BAND['layers'][lname]['band_level_db_rel_k1']
        # 该层自己的噪声底(相对 k=1): 带能量若已落到噪声底, 天花板就不能取"带能量+余量"
        #   —— 否则会把拟合值压到实测噪声以下(实测 mf k=13: 带能量 -94.7 -> 天花板 -88.7,
        #   而拟合 -62.9 只是"该分音未被检出", 压这么低没有任何依据) ✗。
        nfloor = BAND['layers'][lname].get('noise_floor_db_rel_k1')
        # 可信门槛: 带能量必须比该层噪声底高出足够多, 该"天花板"才有意义。
        #   !! 实测事故: pp 层 k=4..7 的带能量读数只比噪声底高 20~29dB, 远低于拟合值
        #   (拟合 -28.8 vs 直测 -40.6) —— 噪声主导的读数会把**真实分音**当成超标而压掉,
        #   等于用噪声当尺子 ✗。只有 SNR 足够高的分音才允许钳位。✓
        snrs = BAND['layers'][lname].get('snr_db')
        a1 = abs(amp_k[1]) if abs(amp_k[1]) > 1e-12 else 1.0
        clamp_k = []
        skip_k = []
        for k in range(1, min(K, len(bl)) + 1):
            if abs(amp_k[k]) < 1e-12:
                continue
            fit_rel = 20 * np.log10(abs(amp_k[k]) / a1)
            ceil_rel = bl[k - 1] + A.clamp_margin_db
            if nfloor is not None and k <= len(nfloor):
                # 可信区间: [噪声底-余量, 带能量+余量] —— 只在这个区间内才钳
                ceil_rel = max(ceil_rel, nfloor[k - 1] - A.clamp_margin_db)
            if fit_rel <= ceil_rel:
                continue
            if snrs is not None and k <= len(snrs) and snrs[k - 1] < A.clamp_snr_min:
                skip_k.append(k)
                continue
            clamp_k.append((k, fit_rel, bl[k - 1]))
            amp_k[k] = np.sign(amp_k[k]) * a1 * 10 ** (ceil_rel / 20)
        if skip_k:
            P(f'    [{lname}] 钳位跳过 {len(skip_k)} 个分音 (带能量读数 SNR < {A.clamp_snr_min:g}dB, '
              f'不足以当天花板): {skip_k}')
        if clamp_k:
            P(f'    [{lname}] 上限钳位 {len(clamp_k)} 个分音 '
              f'(拟合值 -> 实测带能量+{A.clamp_margin_db:g}dB): '
              + ', '.join(f'k={k}({f:+.1f}->{b:+.1f}dB)' for k, f, b in clamp_k))
    ph_k = np.zeros(K + 1)
    k_meas = list(m['k'])
    for k in range(1, K + 1):
        if k in k_meas:
            ph_k[k] = m['phase_rad'][k_meas.index(k)]
        else:                                  # 与 gen_tables.py 同: 缺 k 的相位取左邻居
            lo = [x for x in k_meas if x < k]
            hi = [x for x in k_meas if x > k]
            if lo:
                ph_k[k] = m['phase_rad'][k_meas.index(lo[-1])]
            elif hi:
                ph_k[k] = m['phase_rad'][k_meas.index(hi[0])]
    f_k = np.array([0.0] + [fk_of(m, k) for k in range(1, K + 1)])

    # 幅度取正, 符号并进相位 —— 与 gen_tables.py 完全一致
    #   (表里只存非负幅度, 负幅度等价于相位 +pi)
    sign = np.where(amp_k < 0, -1.0, 1.0)
    amp_abs = np.abs(amp_k)
    ph_enc = np.mod(ph_k + np.where(sign < 0, np.pi, 0.0), 2 * np.pi)

    # 归一化必须只针对**实际合成的 K 个分音**: 旧 gen_tables.py 用全部 40 个测得分音搜峰值,
    # 但我们只合成 k<=16 —— 用 40 个分音定出的峰值来归一化, 合成波形的真实峰值会高于 -1dBFS。
    # 频率用本层实测的 f_k (三层 B 几乎相同, 差异 <0.1 音分, 但用本层的最干净)
    pk_raw, rms_raw = wave_peak_rms([(amp_abs[k], f_k[k], ph_enc[k]) for k in range(1, K + 1)])
    # 该层自身归一化到 -1 dBFS (波形形状来自本层实测)
    scale_self = TARGET / pk_raw
    amp_n = amp_abs * scale_self
    # 归一化后的峰值/有效值 (表写出来实际会是这个形状)
    chans_n = [(amp_n[k], f_k[k], ph_enc[k]) for k in range(1, K + 1)]
    pk_n, rms_n = wave_peak_rms(chans_n)
    # 录音原始峰值 (最诚实的"录音电平"证据, 用于交叉核对)
    # 旧档 JSON 没记, 就从 aiff 现算 (librosa 读进来只为一个标量)
    raw_peak = float(m.get('pcm_peak', np.nan))
    if not np.isfinite(raw_peak):
        ap_ = os.path.join(ROOT, m['file'])
        if os.path.exists(ap_):
            try:
                import librosa
                yy, _ = librosa.load(ap_, sr=None, mono=True)
                raw_peak = float(np.max(np.abs(yy)))
                del yy
            except Exception as e:
                P(f'    (算不出 {m["file"]} 的录音峰值: {e})')
    info[lname] = dict(amp_k=amp_k, ph_k=ph_k, f_k=f_k, pk_raw=pk_raw, rms_raw=rms_raw,
                       scale_self=scale_self, amp_n=amp_n, pk_n=pk_n, rms_n=rms_n,
                       raw_peak=raw_peak, m=m)

P('')
P('[1] 逐层实测统计 (归一化前, 只含实际合成的 K 个分音)')
P(f'    {"层":>3} {"幅度和":>10} {"重建峰值":>10} {"重建rms":>10} {"crest":>7} '
  f'{"录音原始峰值":>12} {"录音rms/峰值":>13}')
for lname in ('pp', 'mf', 'ff'):
    if lname not in info:
        continue
    d = info[lname]
    P(f'    {lname:>3} {np.sum(np.abs(d["amp_k"][1:])):10.5f} {d["pk_raw"]:10.6f} {d["rms_raw"]:10.6f} '
      f'{d["pk_raw"]/d["rms_raw"]:7.3f} {d["raw_peak"]:12.5f} {d["rms_raw"]/d["pk_raw"]:13.4f}')

# ------------------------------------------------------------------ 三层电平差 (相对 ff, dB)
# 关键: 逐层"各自归一到 -1dBFS"会让 pp 反而比 ff 响 (pp 的 crest 更小) —— 方向就反了。
# 正确做法是用**未归一化的重建电平**: 三层用同一个全局缩放系数, 于是层间电平差
# 直接等于录音实测的能量差, 方向自然正确。
P('')
P('[2] 三层电平差 (相对 ff 层, dB)  —— 归一化基准就在这里定')
P('    取法 A (rms)      : 由未归一化重建波形的 rms 比 —— **采用这个**')
P('    取法 B (raw-peak) : 由录音原始峰值比 (最粗, 含音头瞬态) —— 仅作交叉核对')
have3 = all(l in info for l in ('pp', 'mf', 'ff'))
if have3:
    def db_of(x, x0):
        return 20 * np.log10(max(x, 1e-12) / max(x0, 1e-12))
    d_rms_raw = {l: db_of(info[l]['rms_raw'], info['ff']['rms_raw']) for l in ('pp', 'mf', 'ff')}
    d_pk_raw = {l: db_of(info[l]['pk_raw'], info['ff']['pk_raw']) for l in ('pp', 'mf', 'ff')}
    d_rec = {l: db_of(info[l]['raw_peak'], info['ff']['raw_peak']) for l in ('pp', 'mf', 'ff')}
    P(f'    {"层":>3} {"重建rms 比(A)":>15} {"重建峰值 比":>13} {"录音峰值 比(B)":>15}')
    for l in ('pp', 'mf', 'ff'):
        P(f'    {l:>3} {d_rms_raw[l]:15.2f} {d_pk_raw[l]:13.2f} {d_rec[l]:15.2f}')
    db_anchor = d_rms_raw
    db_cross = d_rec

    # ---- 锚点来源可选: 直测(推荐) vs 拟合 ----
    # 为什么要有这个开关: pp 层的**拟合**不仅形状被噪声污染, 绝对电平也崩了 52dB
    #   (拟合模型 rms 4.67e-6 vs 实测窗 rms 1.95e-3)。于是"拟合 rms 比"会得出
    #   pp 比 ff 轻 85dB 的荒谬结论(真值 25.9dB, 真实钢琴 pp..ff 也就 25~30dB)。
    # 直测(band_levels_<note>.json, 由 diag_vel_brightness.py 生成)三层用**同一方法**测, 可靠。
    if A.anchor_src == 'band' and BAND is not None and all(l in BAND['layers'] for l in ('pp', 'mf', 'ff')):
        b = BAND['layers']
        db_band = {l: b[l]['rms_db'] - b['ff']['rms_db'] for l in ('pp', 'mf', 'ff')}
        P('')
        P('    锚点来源对比 (相对 ff 层):')
        P(f'      {"层":>3} {"拟合 rms(A)":>13} {"直测窗 rms":>12} {"直测峰值":>10} {"直测-拟合":>10}')
        for l in ('pp', 'mf', 'ff'):
            P(f'      {l:>3} {d_rms_raw[l]:13.2f} {db_band[l]:12.2f} '
              f'{b[l]["tdp_db"] - b["ff"]["tdp_db"]:10.2f} {db_band[l] - d_rms_raw[l]:+10.2f}')
        P('      -> 采用**直测窗 rms**(三层同一方法); 拟合的 pp 锚点因该层拟合崩塌而废止')
        db_anchor = db_band
        db_cross = {l: b[l]['tdp_db'] - b['ff']['tdp_db'] for l in ('pp', 'mf', 'ff')}
    P('')
    P(f'    采用 (A) ->  pp {db_anchor["pp"]:+.2f} dB / mf {db_anchor["mf"]:+.2f} dB / ff {db_anchor["ff"]:+.2f} dB')
    P(f'    交叉核对 (B) ->  pp {db_cross["pp"]:+.2f} dB / mf {db_cross["mf"]:+.2f} dB')
    P(f'    三层总动态范围 (pp..ff) = {db_anchor["ff"] - db_anchor["pp"]:.2f} dB')
    P('    为什么不能用"逐层各自归一到 -1dBFS":')
    P('      pp 的 crest(峰值/rms) 比 ff 小, 各自归一到同一峰值后 pp 的 rms 反而更大,')
    P('      于是"轻奏比强奏响" —— 方向就错了。全局单一缩放系数才能保住实测的方向。')

    # ---- 显式锚点(优先级最高) ----
    if A.db_anchor:
        _d = {}
        for _it in A.db_anchor.split(','):
            _k, _v = _it.split('=')
            _d[_k.strip()] = float(_v)
        for _l in ('pp', 'mf', 'ff'):
            if _l not in _d:
                P(f'!! --db-anchor 缺 {_l}'); sys.exit(1)
        P('')
        P(f'    [显式锚点] {A.db_anchor}  ->  pp {_d["pp"]:+.2f} / mf {_d["mf"]:+.2f} / ff {_d["ff"]:+.2f} dB')
        P('      (覆盖上面的自动锚点; 典型用法: 响度遵循旧速度律, 音色仍跟三层采样)')
        db_anchor = _d
        db_cross = None

    # ---- 动态范围压缩(可选): 只压缩"响度"跨度, 不改"音色"形状 ----
    if A.vel_span_db is not None:
        span_now = db_anchor['ff'] - db_anchor['pp']
        if span_now > 1e-9:
            kk = A.vel_span_db / span_now
            P('')
            P(f'    [压缩] 实测跨度 {span_now:.2f} dB -> 目标 {A.vel_span_db:.2f} dB '
              f'(系数 {kk:.4f}; 音色形状不变, 只压响度)')
            P(f'           压前: pp {db_anchor["pp"]:+.2f} / mf {db_anchor["mf"]:+.2f} / ff {db_anchor["ff"]:+.2f} dB')
            db_anchor = {l: db_anchor[l] * kk for l in db_anchor}
            P(f'           压后: pp {db_anchor["pp"]:+.2f} / mf {db_anchor["mf"]:+.2f} / ff {db_anchor["ff"]:+.2f} dB'
              f'   (ff 仍为 0, 满刻度不变)')
            P(f'           意义: mf 与旧单层固件的响度差从 {(db_cross or {}).get("mf", 0):.1f}dB 缩到 '
              f'{db_anchor["mf"]:.1f}dB; pp 从 -84dBFS 抬到 '
              f'{-1.0 + db_anchor["pp"]:.0f}dBFS 量级(仍极轻但可闻)')
else:
    P('    !! 三层不齐, 无法算电平差; 退化为"只有 mf 可作为基准"')
    db_anchor = None
    db_cross = None

# ------------------------------------------------------------------ 8 层 db_scale
P('')
P('[3] 8 层 dB 映射 (锚点之间在 dB 域线性插值)')
anchors = {}
if have3:
    anchors[A.v_pp] = db_anchor['pp']
    anchors[A.v_mf] = db_anchor['mf']
    anchors[A.v_ff] = db_anchor['ff']
    xs = sorted(anchors)
    db_scale = np.array([float(np.interp(l, xs, [anchors[x] for x in xs])) for l in range(NL)])
elif 'mf' in info:
    P('    (只有 mf: 全层同表, db_scale 全 0 —— 退化为单层)')
    db_scale = np.zeros(NL)
else:
    P('    !! 无可用锚点, 退出'); sys.exit(1)

P(f'    {"layer":>5} {"vel 区间":>10} {"dB (相对 ff)":>13} {"线性倍数":>10}')
for l in range(NL):
    P(f'    {l:5d} {l*16:5d}-{l*16+15:<4d} {db_scale[l]:13.2f} {10**(db_scale[l]/20):10.4f}')
if all(l in anchors for l in (0, A.v_mf, A.v_ff)) and have3:
    P('')
    P('    自检: 锚点回代')
    P(f'      layer {A.v_pp} 应为 pp 电平 {db_anchor["pp"]:+.2f} dB -> 实际 {db_scale[A.v_pp]:+.2f} dB  '
      f'{"OK" if abs(db_scale[A.v_pp]-db_anchor["pp"])<1e-9 else "!!"}')
    P(f'      layer {A.v_mf} 应为 mf 电平 {db_anchor["mf"]:+.2f} dB -> 实际 {db_scale[A.v_mf]:+.2f} dB  '
      f'{"OK" if abs(db_scale[A.v_mf]-db_anchor["mf"])<1e-9 else "!!"}')
    P(f'      layer {A.v_ff} 应为 ff 电平 {db_anchor["ff"]:+.2f} dB -> 实际 {db_scale[A.v_ff]:+.2f} dB  '
      f'{"OK" if abs(db_scale[A.v_ff]-db_anchor["ff"])<1e-9 else "!!"}')

# ------------------------------------------------------------------ 生成 8 层表
# 插值只在 dB 域做"电平"; 每一层的"形状"(相对分音分布) 取最近锚点:
#   layer 0..3 用 pp 形状 (更靠近 pp), layer 4..7 用 ff 形状? 
#   -> 不行: 那 mf 层就不是 mf 的实测形状了。
#   正确做法: 形状也在三层之间插值。幅度域按 dB 插值 = 对幅度做线性插值(因为 dB 差是常数因子),
#   而"形状插值"要在**归一化后的相对分布**上做。这里用: 
#     把每层归一化后的幅度向量按 dB 域插值(即先各自归一到 -1dBFS, 再对 log10 幅度插值)。
#   这样 mf 锚点处精确等于 mf 的实测形状, pp/ff 锚点处精确等于 pp/ff 的形状。
P('')
P('[4] 层间"形状"插值 (在 log 幅度域对 3 个锚点的归一化分布插值)')

shape = {}
for lname in ('pp', 'mf', 'ff'):
    if lname in info:
        shape[lname] = np.log10(np.maximum(info[lname]['amp_n'][1:K + 1], 1e-9))

# !! 2026-10-13 深夜 重大修正 (根因3 的真身, 原以为是"shape→插值→量化"丢幅度) !!
# amp_n 是**每层各自归一到 -1dBFS** 的结果: 三层各带一个不同的常数因子
#   scale_self = TARGET/pk_raw  (实测 pp/mf/ff 的 k=1 绝对幅度分别是 -43.9/-33.1/-19.1 dB)
# 于是 log10(amp_n) 的三条曲线**基准不同**, 不能直接跨层比大小 ✗。
# 下面的"pp<=mf<=ff 逐分音单调"约束却正是跨层比大小, 而在归一化域里比就等于拿
# "每层自己归一化后的响度"当基准 —— 结果 mf/ff 被它们自己的归一化常数压平, 每个分音
# 都被拉到同一个值, 于是 mf 锚点层整体被压低 4.5dB(且逐分音恒定 = 平移, 不是形状变形) ✗。
# 症状就是"表内 layer4 k2 = -8.7dB vs 合并拟合 -4.2dB"。
# 修法: 把形状统一换成**相对本层 k=1** 的 log 幅度(三层同基准, 物理上可比),
#       在该域里做单调约束, 做完再乘回各层自己的 k=1 绝对值(恢复原口径)。✓
shape_rel = {}
share = {}
for lname in ('pp', 'mf', 'ff'):
    if lname in info:
        an = np.array(info[lname]['amp_n'][1:K + 1], float)
        a1 = abs(an[0]) if abs(an[0]) > 1e-30 else 1e-30
        shape_rel[lname] = np.log10(np.maximum(np.abs(an) / a1, 1e-9))

# ---- 临时调试(2026-10-13): 定位"表内 layer4 k2=-8.7dB vs 合并拟合 -4.2dB" 的 4.5dB 缺口 ----
# 依次打印三个中间量, 看哪一步开始偏; 定位后删掉本段。
if os.environ.get('VEL_DEBUG'):
    for lname in ('pp', 'mf', 'ff'):
        if lname not in info:
            continue
        d = info[lname]
        ak = np.array(d['amp_k'][1:K + 1], float)
        an = np.array(d['amp_n'][1:K + 1], float)
        rk = 20 * np.log10(np.abs(ak) / max(abs(ak[0]), 1e-30) + 1e-30)
        rn = 20 * np.log10(np.abs(an) / max(abs(an[0]), 1e-30) + 1e-30)
        P(f'    [DEBUG {lname}] amp_k rel(dB) k1..6: ' + ' '.join(f'{v:6.1f}' for v in rk[:6]))
        P(f'    [DEBUG {lname}] amp_n rel(dB) k1..6: ' + ' '.join(f'{v:6.1f}' for v in rn[:6]))
        P(f'    [DEBUG {lname}] shape(log10)  k1..6: ' + ' '.join(f'{v:7.4f}' for v in shape[lname][:6]))
        P(f'    [DEBUG {lname}] shape_rel(log10) k1..6: ' + ' '.join(f'{v:7.4f}' for v in shape_rel[lname][:6]))
        j = M[lname]
        js = np.array(j['amp'], float)
        jr = 20 * np.log10(np.abs(js) / max(abs(js[0]), 1e-30) + 1e-30)
        P(f'    [DEBUG {lname}] JSON 原始 rel(dB) k1..6: ' + ' '.join(f'{v:6.1f}' for v in jr[:6]))
        P(f'    [DEBUG {lname}] JSON 的 k 列表 = {list(j["k"])[:8]}')

# ---- 逐分音跨层单调约束 (K3 评审建议) ----
# 先验: 敲得越重, 每个分音都不会更弱 -> 归一化形状必须 pp[k] <= mf[k] <= ff[k]。
# 违反处用"链式累积最大"(isotonic/PAVA 在无权重链上的闭式解)压平。
# 这是免费且必然成立的物理约束, 能挡住"某个分音在弱奏层反而更强"这类测量噪声。
# !! 必须在 shape_rel(相对本层 k=1)域里做 —— 见上面 shape_rel 处的说明:
#    在"各自归一化到 -1dBFS"的 shape 域里比大小 = 拿每层自己的归一化常数当基准, 会把
#    mf/ff 整体压平(实测把 mf 锚点压低 4.5dB, 逐分音恒定) ✗。
iso_fix = 0
iso_skip = 0
if len(shape_rel) == 3:
    # !! 2026-10-13 深夜 追加修正: 单调约束**必须在两侧测量都可信时才施加** !!
    # 实测事故: pp 层 k>=14 的"带能量"已经是它自己的**录音噪声底**(-73dB), 而 mf 层
    # 在那里的真值是 -89dB —— 拿噪声当测量去要求 "pp<=mf", 就把 pp 的噪声底**搬进了 mf**
    # (mf 实测 -88.7 -> 表内 -73.2, 差 16.9dB) ✗。噪声不可比, 比了就污染。
    # 判据: 两个分音都要 SNR>=门槛(数据来自 band_levels_<note>.json 的 censored 字段);
    #       数据缺失时退回旧行为(不跳过), 保证向后兼容。
    cen = None
    if BAND is not None:
        try:
            cen = {l: BAND['layers'][l]['censored'] for l in ('pp', 'mf', 'ff') if l in BAND['layers']}
        except KeyError:
            cen = None
    LAY = ('pp', 'mf', 'ff')
    for k in range(K):
        if cen is None:
            # 没有 SNR 数据时的旧行为: 整条链做累积最大(会被噪声污染, 见上面的说明)
            chain = np.array([shape_rel[l][k] for l in LAY], float)
            fix = np.maximum.accumulate(chain)
            for i, lname in enumerate(LAY):
                if abs(fix[i] - chain[i]) > 1e-9:
                    iso_fix += 1
                    shape_rel[lname][k] = fix[i]
            continue
        for i in range(1, 3):
            a, b = LAY[i - 1], LAY[i]
            if a in cen and b in cen and (cen[a][k] or cen[b][k]):
                iso_skip += 1
                continue
            if shape_rel[b][k] < shape_rel[a][k] - 1e-9:
                iso_fix += 1
                shape_rel[b][k] = shape_rel[a][k]
    P('')
    P(f'    [逐分音跨层单调] pp<=mf<=ff 约束: 修正 {iso_fix} 处' +
      (f', 因单侧 SNR 不足而跳过 {iso_skip} 对' if iso_skip else '') +
      ('  (无违反, 表不变)' if iso_fix == 0 else '  (测量噪声导致, 已压平)'))

# 单调约束做完, 恢复成"每层归一到 -1dBFS"的原口径(形状 × 本层 k=1 绝对值)
for lname in ('pp', 'mf', 'ff'):
    if lname not in shape_rel:
        continue
    an = np.array(info[lname]['amp_n'][1:K + 1], float)
    a1 = abs(an[0]) if abs(an[0]) > 1e-30 else 1e-30
    shape[lname] = shape_rel[lname] + np.log10(a1)

shape_layers = np.zeros((NL, K))
if have3:
    # 以"层号"为自变量的锚点(形状锚点 = 与电平锚点同一批)
    sxs = np.array([A.v_pp, A.v_mf, A.v_ff], float)
    for k in range(K):
        ys = np.array([shape['pp'][k], shape['mf'][k], shape['ff'][k]])
        for l in range(NL):
            shape_layers[l, k] = float(np.interp(l, sxs, ys))
elif 'mf' in info:
    for l in range(NL):
        shape_layers[l] = shape['mf']
else:
    P('!! 缺形状来源'); sys.exit(1)

amp_layers = np.zeros((NL, K))
for l in range(NL):
    amp_layers[l] = (10 ** shape_layers[l]) * (10 ** (db_scale[l] / 20.0))

# ---- 临时调试(2026-10-13 深夜): 收口"shape→插值→量化"是否再丢幅度 ----
# 判据: 表内 layer 4 是 mf 锚点 -> shape_layers[4] 必须逐位等于 shape['mf'];
#       且 amp_layers[4]/amp_layers[4][0] 必须等于 info['mf']['amp_k'] 的实测相对值。
if os.environ.get('VEL_DEBUG'):
    P('')
    P('    [DEBUG 表内] 逐层相对电平(相对本层 k=1), 与锚点实测值对照:')
    for l in range(NL):
        rl = 20 * np.log10(np.abs(amp_layers[l]) / max(abs(amp_layers[l][0]), 1e-30) + 1e-30)
        tag = {A.v_pp: 'pp锚点', A.v_mf: 'mf锚点', A.v_ff: 'ff锚点'}.get(l, '')
        P(f'    [DEBUG 表内 layer {l}] amp_layers rel(dB) k1..6: '
          + ' '.join(f'{v:6.1f}' for v in rl[:6]) + f'   {tag}')
        if tag:
            src = tag[:2]
            if src in info:
                ak = np.array(info[src]['amp_k'][1:K + 1], float)
                rk = 20 * np.log10(np.abs(ak) / max(abs(ak[0]), 1e-30) + 1e-30)
                d = rl - rk
                P(f'    [DEBUG 表内 layer {l}] vs {src} 实测 amp_k    k1..6: '
                  + ' '.join(f'{v:6.1f}' for v in rk[:6])
                  + '   差: ' + ' '.join(f'{v:+5.1f}' for v in d[:6])
                  + f'   (max|差| k1..16 = {np.max(np.abs(d)):.2f} dB)')
                jbad = int(np.argmax(np.abs(d))) + 1
                P(f'    [DEBUG 表内 layer {l}] 全 16 项 表内: '
                  + ' '.join(f'{v:6.1f}' for v in rl))
                P(f'    [DEBUG 表内 layer {l}] 全 16 项 实测: '
                  + ' '.join(f'{v:6.1f}' for v in rk))
                P(f'    [DEBUG 表内 layer {l}] 差最大的 k={jbad}: 表内 {rl[jbad-1]:+.2f} vs 实测 '
                  f'{rk[jbad-1]:+.2f} dB  ->  该 k 实测检出? '
                  f'{"是" if jbad in list(info[src]["m"]["k"]) else "否(靠补缺口插值)"}')

amp_q = np.clip(np.round(amp_layers * SINE_FS), 0, int(SINE_FS)).astype(np.int64)

P(f'    {"layer":>5} {"k=1":>8} {"k=5(最强)":>10} {"k=16":>8} {"高频占比(sum k>=5 / sum all)":>28}')
for l in range(NL):
    s = amp_layers[l]
    hi = s[4:].sum() / max(s.sum(), 1e-12)
    P(f'    {l:5d} {amp_q[l,0]:8d} {amp_q[l,4]:10d} {amp_q[l,15]:8d} {hi:28.4f}')

# ------------------------------------------------------------------ 层间单调性自检
# 判据一(直接来自表的几何): 表随 layer 单调变亮
#   取 log 幅度序列的前半/后半之和: log 幅度是"频谱包络", 越亮的层斜率越平(高次相对更强)
P('')
P('[5] 层间单调性自检 (关键: 力度越大高频占比越高)')
logamp = np.log10(np.maximum(amp_layers, 1.0 / SINE_FS))
c = np.arange(1, K + 1, dtype=float)
# 用 log 幅度对 log k 的线性回归斜率: 更亮 -> 斜率更接近 0 (衰减更慢)
# !! 两个坑(都踩过):
#   (a) 区间必须**各层固定**。若按"每层自己的有效分音"取, 层间区间不同 -> 不可比
#       (layer0 只统计 k<=7 得 -2.92, layer5 统计到 k=16 得 -2.64, 假"非单调")。
#   (b) 不能把量化后的 0 值放进回归: log10(floor) 是假深谷, 会把低层斜率拖到 -6。
#       -> 在**量化前**的连续表 amp_layers 上算, 且固定 K_TILT = 1..8
#          (k>=9 在低层已接近/低于底噪, 本来就没信息)。
K_TILT = 8
slopes = []
for l in range(NL):
    sl = float(np.polyfit(np.log10(c[:K_TILT]), logamp[l][:K_TILT], 1)[0])
    slopes.append(sl)
slope_pts = [K_TILT] * NL
hi_ratio = [float(amp_layers[l][4:].sum() / max(amp_layers[l].sum(), 1e-12)) for l in range(NL)]
centroid = [float((amp_layers[l] * c).sum() / max(amp_layers[l].sum(), 1e-12)) for l in range(NL)]

P(f'    {"layer":>5} {"谱斜率 d(logA)/d(logk)":>24} {"有效分音数":>10} {"高频占比":>10} {"质心(k)":>9}')
for l in range(NL):
    P(f'    {l:5d} {slopes[l]:24.4f} {slope_pts[l]:10d} {hi_ratio[l]:10.4f} {centroid[l]:9.4f}')

import math as _math
_sv = [s for s in slopes if not _math.isnan(s)]
mono_slope = len(_sv) == NL and all(_sv[i] <= _sv[i + 1] + 1e-12 for i in range(NL - 1))
mono_hi = all(hi_ratio[i] <= hi_ratio[i + 1] + 1e-12 for i in range(NL - 1))
mono_cen = all(centroid[i] <= centroid[i + 1] + 1e-12 for i in range(NL - 1))
P('')
P(f'    谱斜率单调不减 (越亮越平, 仅统计有效分音): {mono_slope}')
P(f'    高频占比单调不减:          {mono_hi}')
P(f'    质心单调不减:              {mono_cen}')

# 二分判据: 用"高频占比 > 全表中位"做二值亮度, 逐层必须精确等于 layer>=4
# (K3 评审: 中位分割按构造必然 4:4, 对阈值噪声敏感、信息量低 —— 保留仅供与旧日志对比,
#  真正判据是上面三条趋势指标)
med = float(np.median([hi_ratio[l] for l in range(NL)]))
binary = [1 if hi_ratio[l] > med else 0 for l in range(NL)]
exp_binary = [1 if l >= 4 else 0 for l in range(NL)]
P(f'    [参考] 二值亮度 (高频占比 > {med:.4f}): {binary}   期望 {exp_binary}  '
  f'{"OK" if binary == exp_binary else "!! 不一致"}')

# ------------------------------------------------------------------ 归一化基准自检 (最重要)
P('')
P('[6] 归一化基准自检 (验收项: ff 层峰值 = 现行 mf 表的峰值 = -1 dBFS)')
S_global = TARGET / info['ff']['pk_raw'] if 'ff' in info else None
if S_global:
    P(f'    全局缩放系数 S = TARGET / (ff 层实测重建峰值) = {TARGET:.6f} / {info["ff"]["pk_raw"]:.6f} = {S_global:.4f}')
    P(f'    该 S 对三层**同一个值** -> ff 峰值 = -1 dBFS, mf/pp 依次更轻')
old_path = os.path.join(ROOT, 'rtl', 'rom', f'harm_amp_{A.note}.hex')
old = None
if os.path.exists(old_path):
    with open(old_path, 'r', encoding='ascii') as f:
        old = np.array([int(x.strip(), 16) for x in f if x.strip()], dtype=np.int64)
    P(f'    现有单层表 {os.path.basename(old_path)}: {len(old)} 项, 峰值 {old.max()} = {old.max()/SINE_FS:.6f}')
if have3:
    P(f'    ff 层 (layer {A.v_ff}) 表值: 最大 {amp_q[A.v_ff].max()} = {amp_q[A.v_ff].max()/SINE_FS:.6f} (Q1.15)')
    # ff 层归一化后波形峰值 (用它自己归一化到 -1dBFS, 再乘 db_scale=0)
    P(f'    ff 层重建峰值 = {TARGET:.6f} = {-A.headroom_db:+.1f} dBFS  <- 与现行基准一致')
if mf_a := M['mf']:
    # mf 锚点层与旧表的偏差
    if old is not None and have3:
        l_mf = A.v_mf
        new_mf = amp_q[l_mf]
        # 旧表 = mf 实测形状归一化到 -1dBFS; 新 mf 层 = 同样的形状 × db_scale[mf] 的线性倍数
        ratio = new_mf / np.maximum(old, 1)
        r_db = 20 * np.log10(np.maximum(ratio, 1e-9))
        P('')
        P(f'    layer {l_mf} (mf 锚点) vs 旧表 {os.path.basename(old_path)}:')
        P(f'      {"k":>3} {"旧表":>7} {"新 mf 层":>9} {"比值(dB)":>10}')
        for k in range(1, K + 1):
            P(f'      {k:3d} {old[k-1]:7d} {new_mf[k-1]:9d} {r_db[k-1]:10.2f}')
        P(f'      偏差范围: {r_db.min():+.2f} .. {r_db.max():+.2f} dB  (中位 {np.median(r_db):+.2f} dB)')
        P(f'      预期 = db_scale[{l_mf}] = {db_scale[l_mf]:+.2f} dB  '
          f'{"OK (偏差 <0.5dB)" if abs(np.median(r_db) - db_scale[l_mf]) < 0.5 else "!! 不一致"}')
        P('      这是**设计选择**: 旧表把 mf 录音放在 -1dBFS(= 满力度), 新方案让 ff 占满刻度,')
        P('      mf 按实测电平退让, 所以 mf 层整体比旧表轻 (动态范围是真的, 不是缩放)。')

# ------------------------------------------------------------------ 量化自检
P('')
P('[7] 量化自检 (逐层: 表值还原出的波形峰值应 <= -1 dBFS, 且与理想值偏差很小)')
P(f'    {"layer":>5} {"量化后峰值(dBFS)":>18} {"量化误差(dB)":>14} {"rms(dBFS)":>11}')
zero_cnt = int(np.sum(amp_q == 0))
for l in range(NL):
    chans = []
    for k in range(1, K + 1):
        ph = 0.0
        fk = 0.0
        # 形状/电平已含在 amp_q 里; 相位取最近的锚点层
        src = 'pp' if l <= (A.v_pp + A.v_mf) // 2 else ('mf' if l <= (A.v_mf + A.v_ff) // 2 else 'ff')
        if src not in info:
            src = 'mf' if 'mf' in info else list(info)[0]
        mm = info[src]['m']
        fk = fk_of(mm, k)
        km = list(mm['k'])
        if k in km:
            ph = mm['phase_rad'][km.index(k)]
        else:
            lo = [x for x in km if x < k]
            hi = [x for x in km if x > k]
            ph = mm['phase_rad'][km.index(lo[-1])] if lo else (mm['phase_rad'][km.index(hi[0])] if hi else 0.0)
        chans.append((amp_q[l, k - 1] / SINE_FS, fk, ph))
    pkq, rmsq = wave_peak_rms(chans)
    pk_ideal = TARGET * 10 ** (db_scale[l] / 20.0)
    P(f'    {l:5d} {20*np.log10(max(pkq,1e-12)):18.3f} '
      f'{20*np.log10(max(pkq,1e-12)/max(pk_ideal,1e-12)):14.3f} '
      f'{20*np.log10(max(rmsq,1e-12)):11.3f}')
P(f'    表里 0 值项数 = {zero_cnt} (为 0 表示该分量在某层弱到 <0.5 LSB, 正常)')

# ------------------------------------------------------------------ 与 gen_tables.py 逐项对账
if A.ref_tag:
    if A.ref_tag.endswith('.hex'):
        refp = os.path.join(ROOT, 'rtl', 'rom', A.ref_tag)
    else:
        refp = os.path.join(ROOT, 'rtl', 'rom', f'harm_amp_{A.ref_tag}.hex')
    P('')
    P(f'[7b] 与参考单层表 {os.path.basename(refp)} 逐项对账')
    if not os.path.exists(refp):
        P(f'    !! 缺 {refp}')
        P(f'       (可用 --ref-tag harm_amp_A1.hex; 或先跑 gen_tables.py --json tools/partials_A1.json --tag <name>)')
    else:
        with open(refp, 'r', encoding='ascii') as f:
            ref = np.array([int(x.strip(), 16) for x in f if x.strip()], dtype=np.int64)
        P(f'    参考 {os.path.basename(refp)}: {len(ref)} 项, sum={int(ref.sum())}')
        # 本工具在"锚点形状插值 + 全层同一归一化"下, 若只有一个锚点(全 mf), 应该逐项相等
        if NL == 8 and 'mf' in info and not have3:
            eq = bool(np.array_equal(ref, amp_q[0]))
            P(f'    全层相同(只有 mf 锚点) 时 layer0 与参考逐项相等: {eq}  '
              f'{"OK" if eq else "!! 不一致"}')
            if not eq:
                d = np.abs(ref.astype(float) - amp_q[0].astype(float))
                P(f'      最大项差 = {int(d.max())} (LSB), 出现 {int((d > 0).sum())} 项')
                for k in range(K):
                    if d[k] > 0:
                        P(f'      k={k+1:2d}  ref={ref[k]:5d}  got={amp_q[0][k]:5d}  差 {int(d[k])}')
        else:
            # 有三层时: mf 层不该等于旧表(电平按实测退让), 但要打印偏差
            r_db = 20 * np.log10(np.maximum(amp_q[A.v_mf], 1) / np.maximum(ref, 1))
            P(f'    三层模式下 layer{A.v_mf}(mf) vs 参考: 偏差 {r_db.min():+.2f}..{r_db.max():+.2f} dB '
              f'(中位 {np.median(r_db):+.2f} dB); 预期约 {db_scale[A.v_mf]:+.2f} dB')

# ------------------------------------------------------------------ 写文件
out_path = A.out or os.path.join(ROOT, 'rtl', 'rom', f'harm_amp_vel_{A.note}.hex')
P('')
P('[8] 输出')
P(f'    文件: {os.path.relpath(out_path, ROOT)}')
P(f'    格式: {NL} 层 × {K} 项 × 16bit (Q1.15) = {NL*K} 项 = {NL*K*2} B')
P(f'    地址: addr = layer*{K} + k   (layer 3bit + k {int(np.log2(K))}bit 拼接, 范围 0..{NL*K-1})')

if A.dry_run:
    P('    --dry-run: 不写文件')
else:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    flat = amp_q.reshape(-1)
    with open(out_path, 'w', encoding='ascii') as f:
        for v in flat:
            f.write(f'{int(v) & 0xFFFF:04X}\n')
    P(f'    已写出 {os.path.getsize(out_path)} B')
    P(f'    前 3 项 = {[f"{v:04X}" for v in flat[:3]]}   末 3 项 = {[f"{v:04X}" for v in flat[-3:]]}')
    P(f'    累加和 = {int(flat.sum())} (unsigned, mod 2^64)')
    import hashlib
    _h = hashlib.sha256(open(out_path, 'rb').read()).hexdigest()
    P(f'    SHA256 = {_h}')
    P(f'    注: 文件 {os.path.getsize(out_path)} B = {NL*K} 项 × (4 hex + 1 换行); 纯数据是 {NL*K*2} B')

    # ---- 对账 JSON: 给 verify_vel_layers.py 的 A2 段直读 ----
    # 评审纪要(F4): 旧 A2 用正则解析本脚本的**控制台输出**来对账, 格式一变就失效;
    # 改为生成器直接落一份结构化 JSON, 验收脚本逐字节比对, 不再依赖输出格式。
    import hashlib as _hl
    j = {
        'note': A.note, 'layers': NL, 'maxk': K,
        'v_pp': A.v_pp, 'v_mf': A.v_mf, 'v_ff': A.v_ff,
        'db_scale': [float(x) for x in db_scale],
        'amp_q': [int(v) for v in flat],            # 与 hex 逐项同序 (layer*16+k)
        'per_layer_sum': [int(x) for x in amp_q.sum(axis=1)],
        'hex_file': os.path.relpath(out_path, ROOT).replace('\\', '/'),
        'sha256_hex': _hl.sha256(open(out_path, 'rb').read()).hexdigest(),
    }
    json_path = os.path.join(HERE, f'vel_layers_{A.note}.json')
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(j, f, indent=1)
    P(f'    对账 JSON: {os.path.relpath(json_path, ROOT)} (A2 段直读, 不再解析控制台输出)')

rep_path = os.path.join(HERE, f'gen_vel_layers_{A.note}.log')
if not A.report_only:
    with open(rep_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(rep) + '\n')
    P('')
    P(f'    报告: tools/{os.path.basename(rep_path)}')
