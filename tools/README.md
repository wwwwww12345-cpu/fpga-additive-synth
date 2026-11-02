# tools 说明（生表 + 仿真脚本）

本目录提供**参数表生成脚本**（Python）与一个**历史全量仿真脚本**（PowerShell）。
`rtl/rom/` 里的 `.hex` 都是离线生成后提交的成品表，构建时只 `$readmemh` 读取，不需要现场跑 Python。

## 1. 生表脚本

| 脚本 | 作用 | 主要输出（在 `rtl/rom/`） |
|---|---|---|
| `gen_tables.py` | 六类基础表：正弦、频率字、谐波幅度/衰减/相位/非谐性比 | `sine_q15.hex`、`note_ftw.hex`、`harm_amp_*`、`harm_decay_*`、`harm_phase_*`、`harm_ratio_*` |
| `gen_vel_layers.py` | 三层实测（pp/mf/ff）→ dB 域插值 → 8 层力度幅度表 | `harm_amp_vel_A1.hex`、`harm_amp_vel_C4.hex` |
| `regen_tables.py` | 审计口径重出 C4 的幅度表与衰减表（只写 `tools/staging/`） | `staging/harm_amp_vel_C4_new.hex`、`staging/harm_decay_ctrl_C4_new.hex` |
| `build_pn_v2.py` | **出货用每音表**：保留每音/每层响度，只取平滑后的谐波形状 | `harm_amp_vel_pn4_v2.hex`（`PN_TABLES=1` 时使用） |
| `build_pn_single_shape.py` | 每音表的单形状版本（对比用） | `harm_amp_vel_pn4_single.hex` |
| `fix_pn_high_rows.py` / `fix_pn_outliers.py` | 每音表的高音行修补 / 异常行平滑（`build_pn_v2` 的上游步骤） | 中间表 |
| `gen_decay_slow.py` | v17 衰减表：平滑单调 + 拉长余音 | `harm_decay_ctrl_slow.hex`（出货用） |
| `gen_note_corr.py` | 按音修正表（128 音 × 16 分音） | `note_corr.hex`（`PER_NOTE_CORR=1` 时启用，出货关闭） |
| `gtr_note_tables.py` | 吉他每音延迟长度 N 与循环增益 g | 中间 JSON / 表 |
| `gen_gtr_rtl_tables.py` | 吉他 KS 用的三角步进、起振包络 | `gtr_tri_step.hex`、`gtr_env.hex`、`gtr_loop_g.hex` 等 |
| `gen_octave_tables.py` | 八度分段表（构建里 `OCT_TABLES=0`，未启用） | `harm_amp_vel_oct.hex` |
| `gen_song.py` | 灯带曲目 ROM（`{gate, note, dur}` 16 bit/行） | `song_demo.hex` |
| `engine_model.py` | Python 参考模型 / 读表工具（被上面脚本 `import`） | — |
| `run_sim.ps1` | **历史全量仿真脚本**（表格式、频谱、引擎、力度分层等 15 项） | 见脚本头注释 |

输入数据（实测谐波参数、力度层、每音形状等）以 JSON 随包放在本目录：
`partials_*.json`、`vel_layers*.json`、`per_note_shapes.json`、`octave_shapes.json`、`note_calibration.json`、`band_levels_*.json`。

## 2. 使用注意

1. **脚本里的目录是作者机器上的绝对路径**（`D:\piano_att\rtl\rom`、`D:\采样音色\tools`）。
   换机器运行前先改这些常量；表格式与生成算法不受影响。
2. 依赖 Python 3 + `numpy`（部分测量脚本另需 `scipy`）。本包不含 `.venv`。
3. 部分早期表（如 1024 点正弦 `sine_full_1024_q23.hex`、按 48.828125 kHz 重算的
   `note_ftw_48828.hex`）由早期工具链生成，对应脚本未随精简包提供，**成品表已放在 `rtl/rom/`**。
4. `run_sim.ps1` 是历史全量脚本：它期望完整工作区（含根目录 `I2S.v`、`.venv`、全部历史 tb），
   **不能**直接在本精简包上整跑；随包 testbench 的运行方法见 `README.md` §8 与 `tb/README.md`。
   这里保留它是为了说明验收是怎么做的、以及表格式比对的期望值从哪来。
