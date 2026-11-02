# lowlat —— 低延迟触发固件（手机预输入 + FSR 触发）

> 2026-11-02。**独立顶层，不改 `rtl/` 里的任何文件**（`lowlat/top.v` 是 `rtl/top.v` 的副本，只多一个 `vib_code_in` 输入口）。

## 1. 方案（用户思路）

蓝牙慢没关系：**手机只负责"预输入"要弹哪个键，真正的发声由 FSR 一按触发**，
力度取"按下后延迟 X ms 的压力值"。

| 步骤 | 行为 |
|---|---|
| 预输入 (arm) | 小程序发 `0x87 note vel` → 只记 `arm_note/arm_vel`（`arm_valid=1`），**不发声** |
| 触发 | AIN0 ≥ `TH_ON`(6000) 且之前没在响 → 等 `TRIG_DLY` 拍 → 取**那一刻**码值算力度 `v` → 发 note-on(arm_note, v) |
| 松开 | 码值 < `TH_OFF`(3000) → note-off |
| 解除 | `0x88 note`：若等于 arm 音则 `arm_valid=0`；正在响的同时抬键 |
| 没用 arm 时按 FSR | 不发声 |

和弦仍走 `keyhub`（`0x82` 设大三/小三/属七），音域/音色/混响(0x89)/滑音(0x8B)/曲谱全部保留；
触后颤音用同一个 FSR 的压力（0..21 音分、5.5 Hz）。

## 2. 延迟预算（50 MHz 时钟）

| 环节 | 时间 |
|---|---|
| 按下 → ADC 读到（`ads1115_fast` 只读 AIN0，一轮 ≈1.5 ms） | **0 ~ 1.5 ms** |
| `TRIG_DLY` 等取力度点（默认 150 000 拍） | **3.0 ms** |
| keyhub → note_ctrl → 引擎起振 | ≈0.05 ms |
| **合计** | **≈3.0 ~ 4.6 ms** |

对比正式固件：4 通道轮询一轮 6.05 ms → 检测延迟 0~6 ms，同样加 3 ms 就是 3~9 ms。
仿真实测（`TRIG_DLY=200` 拍）：从越过 `TH_ON` 到 keyhub 输出 **204 拍**（含 4 拍握手）。

## 3. 参数

| 参数 | 默认 | 含义 |
|---|---|---|
| `TH_ON` | 6000 (≈0.75 V) | 越过即开始计时 |
| `TH_OFF` | 3000 (≈0.37 V) | 回落即抬键 |
| `TRIG_DLY` | 150 000 (3 ms) | 取力度点距越过门槛的拍数 |
| 力度口径 | `v = (code[15:8]==0)?96:clamp(code[15:8],1,127)` | 与正式固件完全一致 |

## 4. 文件

```
lowlat/top_trig_fsr.v     新顶层（骨架取自 rtl/top_ble_fsr.v，单音入口换成 arm+FSR 触发）
lowlat/top.v              = rtl/top.v 的副本，唯一差异: 颤音码值改成输入口 vib_code_in
lowlat/ads1115_fast.v     = rtl/ads1115_if.v 的副本，唯一差异: 只读 AIN0（不轮询通道）
lowlat/top_trig_fsr.cst   引脚照抄 rtl/top_ble_fsr.cst（clk E2/btn_rst H11/i2c F1 A1/uart G2 G1…）
lowlat/syn_trig_fsr.tcl   综合脚本（从工程根目录跑）
lowlat/README.md          本文
```

## 5. 构建

```powershell
# Gowin 吃不了中文路径 -> 先把 rtl/ + lowlat/ 复制到 ASCII 目录再跑
& gw_sh.exe lowlat\syn_trig_fsr.tcl *> build_lowlat.log
Copy-Item impl\pnr\project.fs lowlat\top_trig_fsr.fs
```

## 6. 上板注意（先别烧，等接线确认）

- 接线与正式固件完全相同：ADS1115 SCL=F1/SDA=A1/ADDR=GND，FSR 分压 3V3—FSR—AIN0 + 10k 下拉。
- 小程序行为变了：**按下时不再直接听到声音**，必须"先按手机键（预输入）再按 FSR"。
- 若发现"按了 FSR 没声"，先查 `arm_valid`（是不是没收到 0x87，或 0x88 已经解除了）。
- 无 arm 时 FSR 不会发声（这是设计行为，不是故障）。

## 7. 瘦身版（钢琴 only）与矩阵键盘版

### 7.1 `GTR_EN`（2026-11-02 新增参数）
`lowlat/top.v` 与 `lowlat/top_trig_fsr.v` 都加了 `GTR_EN`（**默认 0**）：为 0 时整条吉他链
（`gtr_ks_engine` / `gtr_body_lead` / `dc_block`）**不例化**，混音只走钢琴；`0x86` 仍能收、
`timbre` 寄存器照常更新（两档都出钢琴、不报错）。

实测对比（GW5A-25A，Gowin 1.9.11）：

| 配置 | Logic | CLS | DSP | BSRAM | SETUP |
|---|---|---|---|---|---|
| `GTR_EN=1`（全功能） | 14,852 | 89% | 24.5/28 | 44/56 | +0.022 |
| **`GTR_EN=0`（本演示固件）** | **12,462** | **77%** | **18/28** | **27/56** | **+1.770** |

产物 `lowlat/top_trig_fsr.fs`（6,926,946 B）就是 `GTR_EN=0` 这版。
仿真实测（`D:\bfsv_sim\tb\tb_trig_fsr.v`）：`TRIG: ALL PASS (14 checks)`，含"arm 后不发声 /
触发延迟 204 拍（TRIG_DLY=200+4 拍握手）/ 力度=码值>>8 / 抬起抬键 / 0x88 解除后无声 /
0x86 收到不崩且仍能触发"。

### 7.2 矩阵键盘版（`top_keymatrix`，**尚未综合**）
- `lowlat/keymatrix.v`：4 行逐行拉低（每行 20 µs，整轮 ≈80 µs）+ 4 列输入（低=按下）；
  **按下当帧就发 note-on**（不去抖），释放要连续 `DEB_MS`(3 ms) 才抬键；16 键音号表由
  `KEYMAP_V`（112bit）给；力度取按下那刻的 AIN0 码值（高字节 0 时回退 96）。
- `lowlat/top_keymatrix.v`：在 `top_trig_fsr` 骨架上把"arm+触发"换成矩阵键盘，事件仍进 keyhub
  （和弦/音域/音色/混响/滑音/颤音/曲谱全部保留），同样默认钢琴 only。
- 引脚（临时）：行 **F5/G7/H5/H8**，列 **J8/K8/K9/L9**（等键盘丝印确认后可能改）。
- 综合脚本 `lowlat/syn_keymatrix.tcl`（先不跑，等任务 A 的余量确认后再基于同一瘦身配置综合）。