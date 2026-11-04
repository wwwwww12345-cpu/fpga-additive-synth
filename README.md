# FPGA 实时多音色合成电子乐器（赛题选题二）

> 一句话：在 Sipeed Tang Primer 25K（Gowin **GW5A-25A**）上用纯 HDL 做一台**逐样本加法合成**的电子乐器——
> **32 复音 × 16 分音 = 512 个独立振荡器**、采样率 **48.828125 kHz**、钢琴/吉他双音色、
> 矩阵键盘与手机蓝牙两路演奏、力度感应（FSR 4 层）、24 颗 WS2812 灯带逐音指引（v0.6：App 曲谱下发后黄/绿/红指引弹奏）。
> 全部声音由 FPGA 实时计算，**不播放任何预录 PCM**。

本仓库是**作品开源代码**（构建脚本 + RTL + 参数表 + 测试台 + 小程序 + 文档）。
**不含** `.fs` 固件与任何二进制产物——固件获取方式见 §5 与 [`firmware/README.md`](firmware/README.md)。

---

## 1. 作品简介

| 项 | 内容 |
|---|---|
| 板卡 | Sipeed Tang Primer 25K（Gowin **GW5A-LV25MG121NC1/I0**） |
| 时钟 | 板载 **50 MHz** 单时钟，**无 PLL** |
| 合成方式 | 加法合成：每个声部 16 个分音，每个分音有独立相位累加器 / 频率字 / 包络 |
| 规模 | **32 声部 × 16 分音 = 512 个独立振荡器**；512 × 48.828125 kHz ≈ **25.0 M 振荡器·样本/秒** |
| 采样率 | **48.828125 kHz**（50 MHz ÷ 1024，整数分频、逐周期无抖动） |
| DAC | PCM5102A，I2S，24 bit |
| 音色 | 钢琴（实测采样建模：非线性/相位/衰减表）、吉他（Karplus-Strong + 琴体 biquad + DC 阻断），`0x86` 切换 |
| 演奏输入 | ① 16 键 4×4 矩阵键盘，按下到出声约 **1 ms** ② 手机 BLE 键盘（`0x87/0x88`） |
| 力度 | FSR 码值 → 4 层映射（`v=code>>8`、层=`v>>5`） |
| 效果 | 混响（`0x89` 湿度滑块；RTL 与仿真通过，**板上湿声暂不可闻**，见 §7） |
| 可视化 | 24 颗 WS2812 灯带按音高点亮；v0.6 起 App 曲谱 + `0x94` 灯带指引（黄=该按 / 绿=按对 / 红=按错） |
| 交互 | 微信小程序控制台 / 弹琴页：连接、PING、音域、和弦、音色、混响、滑音、曲谱下发与播放 |
| 综合（07 固件） | SETUP **+0.237 ns** / HOLD +0.151 ns / CLS **92%** / DSP 25/28 |

**纯硬件实时性**：音频通路全部由 RTL 逐样本计算（`partial_engine` / `gtr_ks_engine` → 混音 → I2S），
没有 CPU、没有软件合成、没有预录音频播放。

---

## 2. 目录树

```
仓库根/
├─ README.md                    本文件
├─ LICENSE                      许可证（占位 MIT，署名赛后补）
│
├─ rtl/                         可综合 RTL（32 个 .v + 1 个 .sdc）
│  ├─ top.v                     整机顶层（引擎 + 交互 + I2S + 显示 + 灯带）
│  ├─ note_ctrl.v               键事件 FIFO / 32 声部分配 / 音高换算
│  ├─ partial_engine.v          加法合成引擎核心（512 时隙 TDM）
│  ├─ gtr_ks_engine.v           Karplus-Strong 吉他引擎（16 声部）
│  ├─ gtr_body_lead.v / dc_block.v / gtr_body.v   吉他琴体滤波与直流阻断
│  ├─ rvb_mono.v                单声道混响（Schroeder 简化版）
│  ├─ i2s_48k_int.v             整数分频 I2S 发送（本固件使用，48.828125 kHz）
│  ├─ i2s_48k.v                 小数分频 I2S（历史路径，48.000 kHz，保留对照）
│  ├─ ble_cmd.v / ack_tx.v      BLE 协议解析 / 下行 ACK·NACK
│  ├─ keyhub.v / fsr_key.v      BLE 与键盘事件合流 / FSR 力度
│  ├─ ads1115_if.v              ADS1115 I2C 读取（FSR）
│  ├─ uart_key.v / uart_rx_off.v / uart_tx_off.v / UART_Receiver.v  串口链路
│  ├─ song_player.v / song_ram.v / led_guide.v / viz_led.v          曲谱播放与灯带指引
│  ├─ guide_ctrl.v / led_guide.v / ws2812_mono.v                   灯带指引与驱动（v0.6 已移除 OLED 链）
│  ├─ ws2812_phy.v / ws2812_mono.v                                  WS2812 物理层
│  ├─ sine_lut_full.v           1024 点正弦表查表
│  ├─ test_pattern.v            现场验收测试图样（K4 选通，频谱可见多谱峰）
│  ├─ gtr_demo.v                吉他自动演示（诊断/展示备选）
│  ├─ engine.sdc                50 MHz 时钟约束
│  └─ rom/                      23 张 .hex 参数表（钢琴/吉他/正弦/曲谱；由 tools/ 生成）
│
├─ lowlat/                      本固件（07）的**出货顶层**与约束
│  ├─ top_ble_fsr_keys.v        BLE 单音 + FSR 力度 + 矩阵键盘 顶层
│  ├─ keymatrix.v               4×4 矩阵键盘扫描
│  ├─ top_ble_fsr_keys.cst      引脚约束（以本文件为准）
│  ├─ syn_ble_fsr_keys.tcl      Gowin 全流程综合脚本（**构建入口**）
│  └─ README.md                 低延迟方案说明与实测
│
├─ tb/                          9 个可独立复现的 testbench + 依赖 + 仿真记录
├─ tools/                       生表 Python（含输入 JSON）+ 仿真脚本
├─ miniprogram/hc04-ble/        微信小程序源码（协议 v0.5，无 node_modules）
├─ docs/                        协议 / 验收 / 赛题拆解 / 接线与固件说明 / 验收摘要
├─ firmware/                    固件对照表.md（**二进制不在仓库**，见 firmware/README.md）
```

---

## 3. 器件与工具链

| 项 | 版本 / 路径 | 说明 |
|---|---|---|
| FPGA | Gowin **GW5A-LV25MG121NC1/I0**（=device 行 `GW5A-LV25MG121NC1/I0 -name GW5A-25A`） | Tang Primer 25K 核心板 + 25K Dock |
| 综合/布线 | Gowin EDA **V1.9.11.03 Education x64**（`gw_sh.exe`） | 脚本 `set_option -verilog_std sysv2017` |
| 仿真 | ModelSim **ASE 10.5b** | `vlog -sv`；工程需镜像到纯 ASCII 目录 |
| 生表 | Python 3 + numpy / scipy | `tools/*.py`，输入 JSON 随包 |
| 小程序 | 微信开发者工具，基础库 3.4.0（`project.private.config.json` 里为 3.17.3） | appid `wxb21bcba86fcb9c32` |
| DAC | PCM5102A（I2S，24 bit） | SCK 接地=内部 PLL |
| 蓝牙 | HC-04（UART 透传 115200 8N1） | BLE 服务 FFE1 |

> ⚠️ **中文路径**：Gowin 与 ModelSim 都不认中文路径（会报 sqlite/token file 之类错误）。
> 工程目录名是中文，所以**构建/仿真前必须先镜像到纯 ASCII 目录**（见 §4.1）。

---

## 4. 从零构建

### 4.1 镜像到纯 ASCII 目录（必做）

`lowlat/syn_ble_fsr_keys.tcl` 与所有 `$readmemh` 都用**相对路径**（`rtl/...`、`lowlat/...`），
所以工作目录必须直接包含 `rtl/` 与 `lowlat/` 两个文件夹。把这两个文件夹原样复制到 ASCII 目录：

```powershell
# 任选一个纯 ASCII 目录，例如 D:\gowin_bfs
New-Item -ItemType Directory -Force D:\gowin_bfs | Out-Null
robocopy .\rtl      D:\gowin_bfs\rtl      /E
robocopy .\lowlat   D:\gowin_bfs\lowlat   /E
cd D:\gowin_bfs
```

> 不要只复制 `.v`：`rtl/rom/*.hex` 与 `rtl/engine.sdc` 必须一起过去，否则 ROM 读不到、时序约束丢失。
> 镜像后目录结构应为 `D:\gowin_bfs\rtl\...` + `D:\gowin_bfs\lowlat\...` + `D:\gowin_bfs\impl\`（构建时自动生成）。

### 4.2 综合 / 布线 / 出固件

```powershell
$gw = 'D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe'
& $gw lowlat\syn_ble_fsr_keys.tcl *> build.log
```

该脚本做的事：设器件与顶层 `top_ble_fsr_keys` → 加入 32 个 RTL 文件 + `rtl/engine.sdc` + `lowlat/top_ble_fsr_keys.cst` → `run all`。
约 3~10 分钟（取决于机器）。

### 4.3 判据（怎么算构建成功）

```powershell
# ① 综合日志里不允许有 ERROR
(Select-String -Path build.log -Pattern 'ERROR \(').Count      # 必须为 0

# ② 时序：读布局布线报告的 SETUP slack（第 2 行）
Get-Content impl\pnr\project.timing_paths -TotalCount 2
```

参考值（本包 `firmware/` 里的固件就是这样编出来的）：

| 固件 | SETUP slack | HOLD | CLS | DSP |
|---|---|---|---|---|
| 07 `v33_reverb`（推荐） | **+0.237 ns** | +0.151 ns | 92% | 25/28 |
| 06 `v32_timing_song` | +0.202 ns | +0.151 ns | 92% | 25/28 |
| 03 `piano_keymatrix` | +0.966 ns | +0.182 ns | 80% | 18/28 |
| 12 `v35_reverb_min`（诊断） | +0.250 ns | — | — | — |

> Gowin 的布局会随版本/种子小幅波动；只要 SETUP ≥ 0 且 ERROR 为 0 即可复现同功能固件。
> 换 `DISP_ON=0`、`TIMBRE`、`GTR_EN` 等顶层参数可削减资源（见 `lowlat/README.md` 与各顶层参数注释）。

### 4.4 产物

```
impl\pnr\project.fs     ← Flash 固化镜像（提交的 .fs 就是它）
impl\pnr\project.bin    ← SRAM/外部 Flash 用的二进制
impl\pnr\project.timing_paths  ← 时序报告
```

---

## 5. 固件与烧录

`firmware/` 放 9 个关键固件（每个约 7 MB，共约 **63 MB**），完整对照见
[`firmware/固件对照表.md`](firmware/固件对照表.md)。摘要：

| 固件 | 场景 | SETUP |
|---|---|---|
| `15_full_keyboard_ledfix_v07.fs` | **v0.7 推荐**：v0.6 + **灯带八度修复**（灯位不随音域漂移） | **+0.259** |
| `14_full_keyboard_guide_v06.fs` | v0.6：去 OLED + 灯带指引（0x94） | +0.978 |
| `07_full_keyboard_v33_reverb.fs` | 上一版全功能（含 OLED，v0.6 前的基线） | +0.237 |
| `06_full_keyboard_v32_timing_song.fs` | 07 的前一版（同功能，混响湿声公式未修正） | +0.202 |
| `03_piano_keyboard_top_keymatrix.fs` | **最稳**：钢琴 only + 键盘（余量大，演示兜底） | +0.966 |
| `02_full_keyboard_top_ble_fsr_keys.fs` | 上一轮全功能版（双源仲裁有 race） | +0.659 |
| `01_full_phone_top_ble_fsr.fs` | 没有实物键盘时用手机弹 | +1.327 |
| `04_keyboard_guitar_nodisp_top_keymatrix_gtr.fs` | 键盘 + 吉他、无显示（备选） | +0.563 |
| `12_full_keyboard_v35_reverb_min.fs` | 混响**诊断**用最小结构（不要用于演示） | +0.250 |

烧录（Gowin Programmer）：

1. USB 连板，Programmer 扫描到 `GW5A-25A`；
2. 选对应 `.fs`；**SRAM 模式**（断电即失）。要固化改用 Embed Flash（按所用 Programmer 版本的选项）；
3. 烧完**按一下 H11（USER_KEY）复位**——I2C 错误标志是粘滞的；
4. 上电/复位时**手离开 FSR**；先按一个键盘键应有声，或手机连上发 PING 应回 ACK。

引脚全表（BLE / I2S / FSR / 矩阵键盘 / 灯带）见
[`docs/接线与固件说明_20261102.md`](docs/接线与固件说明_20261102.md) §4。

> **本仓库不放 `.fs`**：这些是约 7 MB 的比特流二进制，放在 **Release / 网盘**分发
> （下载位置与自建方法见 [`firmware/README.md`](firmware/README.md)）。

---

## 6. 协议摘要

完整字节协议：[`docs/PROTOCOL.md`](docs/PROTOCOL.md)（v0.5）。传输层：

```
小程序 ──BLE(FFE1 write)──> HC-04 ──UART 115200 8N1──> FPGA
小程序 <──BLE(FFE1 notify)── HC-04 <──UART─────────── FPGA
```

**帧 = 1 命令字节（bit7=1）+ 0~3 数据字节（bit7=0）**，单帧 ≤ 4 字节。

| 命令 | 功能 | 数据 |
|---|---|---|
| `0x80` | PING | — （回 `A1 00`） |
| `0x81` / `0x83` | 音域偏移 / 重置 | 偏移半音 + 64 |
| `0x82` | 和弦 | 0 关 / 1 大三 / 2 小三 / 3 属七 |
| `0x84` / `0x85` / `0x93` | 曲谱播放 / 停止 / 复位 | — |
| `0x86` | 音色 | 0 钢琴 / 1 吉他 |
| `0x87` / `0x88` | 单音按下 / 松开 | note, vel / note |
| `0x89` | 混响湿度 | 0 干声 … 127 全湿（默认 32） |
| `0x8B` | 滑音 | 0 关，1 最快（≈50 ms）… 127 最慢（≈1 s） |
| `0x90` / `0x91` / `0x92` | 曲谱开始（N≤512）/ 条目（note,vel,dur）/ 结束 | dur 单位 10 ms |
| `0xA1` / `0xA2` | 下行 ACK / NACK | 被确认命令的低 7 位（+错误码） |

> 速率类数值（滑音时间、延迟）是设计目标值；精确值以 `docs/PROTOCOL.md` 与实测为准。

---

## 7. 已知限制（如实记录）

1. **混响湿声在板上暂不可闻（未解决）**。`rvb_mono` 的逻辑与仿真通过，`0x89` 也在改湿度；
   但 07 固件在真实板子上听不到湿声（探针 `09` 只放湿声时完全静音），怀疑与综合后行为/供电有关，
   排查到"需要 168 ms 回声判决实验"这一步。**报告与答辩按"已实现、板上联调中"表述，不宣称混响已可用。**
   12 号是 v35 最小结构诊断固件（约 42 ms 回声间隔），只用于定位，不用于演示。
2. **采样率是 48.828125 kHz，不是 48.000 kHz**：50 MHz ÷ 1024，相对 48 kHz 偏高 **+29.6 音分**
   （约三分之一半音）。选它是为了 BCLK 逐周期精确、无小数分频抖动；音高表已按该采样率重算
   （`rtl/rom/note_ftw_48828.hex`），所以**弹奏音高是对的**，只是"采样率名义值"不同。报告需如实写。
3. **没有状态回读**：`0xA0` 未实现，音域/和弦/音色/混响/滑音只存在 FPGA 里，复位后小程序界面不会自动同步。
4. **07 时序余量薄**：SETUP +0.237 ns、CLS 92%、DSP 25/28。长时间 soak 若出现偶发不响/卡顿，
   先重烧/复位；仍不稳就换 **03**（+0.966 ns，钢琴 only）。
5. **力度只有 4 层**（`v=code>>8`，层=`v>>5`）；轻按实测 v≈29~36 正好跨 L0/L1 边界（32），
   同一力度连按可能跳层。满压只到 103（3.3 V 量程）。
6. **曲谱上限 512 条**，`dur` 单位 10 ms、单条 ≤127（1.27 s），更长的音用连续同音条目拼接。
7. **两路输入不建议同时用**：07 已修双源仲裁，但"BLE 事件与键盘同一拍到达"的边界没有做过长时间 soak；
   演示时单路操作。
8. **v0.6 已移除 OLED 显示链**（`DISP_ON=0`），`viz_lissa/ssd1306/spi_master` 不再综合。
9. 04 固件为腾时序删掉了曲谱/和弦/显示，属功能性裁剪，不是 bug。
10. 混响/延迟/合唱三种效果里**只做了混响**，延迟与合唱未实现。

---

## 8. 仿真与验收

随包的 9 个 testbench **全部在本包内容上跑过**（ModelSim ASE 10.5b，`vlog -sv`），
原始输出见 [`tb/仿真记录_20261103.txt`](tb/仿真记录_20261103.txt)：

| testbench | 结果 |
|---|---|
| `tb_ble_e2e` | ALL CHECK PASSED（**52** 项） |
| `tb_ble_cmd_proto` | ALL CHECK PASSED（**36** 项） |
| `tb_ble_fsr_vel` | ALL PASS（**10** 项） |
| `tb_fsr_key` | ALL PASS（**10** 项） |
| `tb_led_guide` | ALL CHECK PASSED（**13** 项） |
| `tb_partial_engine_bitref` | 逐位一致（4096 样本，mismatch **0**） |
| `tb_gtr_body_lead_bitref` | 逐位一致（2050 样本，mismatch **0**） |
| `tb_note_ctrl` | 8 声部并发 / 超复音抢占 drop=0 / overrun=0 |
| `tb_partial_engine` | active_voices=1，pass_clks=517，overrun=0 |

运行方法（在 ASCII 镜像目录内）：

```powershell
$ms = 'D:\Quartus17\modelsim_ase\win32aloem'
& "$ms\vlib.exe" work; & "$ms\vmap.exe" work work
& "$ms\vlog.exe" -sv rtl\*.v tb\*.v tb\deps\*.v
& "$ms\vsim.exe" -c -work work -do "run -all; quit -f" work.tb_ble_e2e
```

> 更多历史验收（矩阵键盘 122 项、逐位回归 400/4097 样本等）见
> [`docs/验收摘要_20261103.md`](docs/验收摘要_20261103.md) 与 [`docs/acceptance.md`](docs/acceptance.md)。

---

## 9. 微信小程序（`miniprogram/hc04-ble`）

1. 微信开发者工具 → 导入项目 → 选 `miniprogram/hc04-ble`；
2. appid 用 `wxb21bcba86fcb9c32`（或改成自己的测试号）；
3. 首页 = 控制台（连接/PING/音域/和弦/音色/混响/滑音/曲谱/日志），另有弹琴页与曲谱页；
4. 所有命令常量集中在 `utils/protocol.js`，发送统一走 `utils/sender.js`（≤20 字节/包、≥10 ms 间隔）。

---

## 10. 许可

见 [`LICENSE`](LICENSE)。当前为**占位 MIT**，版权人署名留空（**不写学校/个人真实信息**），
赛后由作者补全；如赛方或企业选题有另行约定，以约定为准。

第三方组件：HC-04 为通用 BLE 串口模块（只做字节透传，仓库不含其固件）；PCM5102A/ADS1115 仅用芯片，无第三方代码。
