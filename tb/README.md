# testbench 说明（精简验收集）

本目录只放**能在本包内容上独立跑通**的 9 个 testbench（不是全量），目标是让评委能亲手复现
`docs/验收摘要_20261103.md` §1 的结论。原始输出见 `仿真记录_20261103.txt`。

## 1. 怎么跑

ModelSim 与 Gowin 都不认中文路径，先把 `rtl/`、`tb/` 镜像到纯 ASCII 目录（例 `D:\pkg_sim`），
在镜像根目录执行：

```powershell
$ms = 'D:\Quartus17\modelsim_ase\win32aloem'
& "$ms\vlib.exe" work
& "$ms\vmap.exe" work work
& "$ms\vlog.exe" -sv rtl\*.v tb\*.v tb\deps\*.v
& "$ms\vsim.exe" -c -work work -do "run -all; quit -f" work.tb_ble_e2e
```

要点：

- **必须带 `-sv`**：`gtr_ks_engine.v` 等用了 SystemVerilog 的 `logic`，不加会报 vlog-2730；
- 必须在**包含 `rtl/rom/` 的目录**下跑（`$readmemh` 用相对路径 `rtl/rom/...`）；
- 每次换 tb 只需改最后的 `work.<tb名>`，不用重新编译。

## 2. 清单与结论

| 文件 | 覆盖点 | 本包实测 |
|---|---|---|
| `tb_ble_e2e.v` | BLE 命令流 → `ble_cmd` → `keyhub` → `note_ctrl` 全链路 | **ALL CHECK PASSED（52 项）** |
| `tb_ble_cmd_proto.v` | 命令帧格式、非法长度、ACK/NACK 触发条件 | **ALL CHECK PASSED（36 项）** |
| `tb_ble_fsr_vel.v` | `0x87` 单音 + FSR 码值 → 力度；FSR 为 0 时回退帧内 vel | **ALL PASS（10 项）** |
| `tb_fsr_key.v` | FSR 越阈/回滞/抬键 + I2C NACK 不崩 | **ALL PASS（10 项）** |
| `tb_led_guide.v` | 灯带逐音指引（曲谱 ROM → LED 位置） | **ALL CHECK PASSED（13 项）** |
| `tb_partial_engine_bitref.v` | 钢琴引擎与参考模型逐位对比 | **4096 样本，mismatch 0** |
| `tb_gtr_body_lead_bitref.v` | 吉他琴体 biquad 与参考模型逐位对比 | **2050 样本，mismatch 0** |
| `tb_note_ctrl.v` | 8 声部并发、超复音抢占（steal/drop）、包络 | 8 声部 busy=8；40 音 busy=32、steal=1、**drop=0**；overrun=0 |
| `tb_partial_engine.v` | 加法引擎单声部出声与吞吐 | active_voices=1、overrun=0、pass_clks=517/1041 |

## 3. 依赖文件（`deps/` 与同目录 ref）

| 文件 | 为什么需要 |
|---|---|
| `deps/top_ble_fsr.v` | `tb_ble_fsr_vel` 的 DUT 是上一代顶层 `top_ble_fsr`（FSR 力度首版）。它**不参与 lowlat 构建**，只为让该 tb 独立可跑。 |
| `partial_engine_ref.v` | `tb_partial_engine_bitref` 的参考模型（逐位对比用） |
| `gtr_body_lead_v29_ref.v` | `tb_gtr_body_lead_bitref` 的参考模型 |

> `tb_ble_fsr_vel` 会有 6 条 `Too few port connections / Missing connection for port 'rvb_mix'/'glide_amt'`
> 警告：测试台写于 `top_ble_fsr` 加这两个端口之前，悬空输入不影响该 tb 的 10 项判定，**结果仍 ALL PASS**。

## 4. 没有随包的 testbench（以及原因）

| tb | 原因 |
|---|---|
| `tb_top.v` | 旧整机冒烟测试，默认参数（48.000 kHz 小数分频 + 旧 LUT）与本精简构建的出货配置不一致，跑出来是"合理地失败" |
| `tb_sine_lut.v` | 依赖早期 `sine_lut.v`（257 点表），本构建用 `sine_lut_full.v`（1024 点） |
| `tb_gtr_ks_engine_bitref.v` | 对比的是 v29 参考引擎；出货的 `gtr_ks_engine.v` 已是 v32（延迟线地址改成每声部指针），逐位相等不再成立 |

这些历史结论仍在 `docs/acceptance.md` 与 `docs/验收摘要_20261103.md` §2 保留，只是不放进精简包，
避免评委看到一个"因为裁剪而失败"的假阴性。
