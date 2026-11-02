# =============================================================================
# run_sim.ps1 —— 一键验收: 镜像源码 -> ModelSim 编译/仿真 -> Python 比对/FFT
#   为什么必须镜像: ModelSim ASE 10.5b (2016) 处理不了中文路径, 会报
#     sqlite3_open ... unable to open database file / vlog-9 token file
#   工程在 D:\采样音色 (非 ASCII) 下, 所以同步到 D:\piano_sim 再编译。
#   Gowin 综合/布线同理, 建议全程 ASCII 路径。
#
#   四步:
#     1) 表格式验收 (tb_tables)         -> verify_tables.py 比对
#     2) 正弦表频谱 (有/无插值)          -> verify_sine_lut.py 算 SFDR
#     3) 引擎: 单音 + 32 复音            -> verify_engine.py 逐分量/逐音核对
#     4) 汇总
#
# 用法:  powershell -File tools\run_sim.ps1
# =============================================================================
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'
$ErrorActionPreference = 'Continue'

$ms   = 'D:\Quartus17\modelsim_ase\win32aloem'
$src  = Split-Path -Parent $PSScriptRoot          # D:\采样音色
$work = 'D:\piano_sim'
$py   = Join-Path $src '.venv\Scripts\python.exe'
$vlog = Join-Path $ms 'vlog.exe'
$vsim = Join-Path $ms 'vsim.exe'
$vlib = Join-Path $ms 'vlib.exe'
$vmap = Join-Path $ms 'vmap.exe'

Write-Host "== 1/4 镜像 $src -> $work"
foreach ($d in 'rtl', 'rtl\rom', 'tb') {
    New-Item -ItemType Directory -Force -Path (Join-Path $work $d) | Out-Null
}
Copy-Item (Join-Path $src 'rtl\*.v')        (Join-Path $work 'rtl') -Force
Copy-Item (Join-Path $src 'rtl\rom\*.hex')  (Join-Path $work 'rtl\rom') -Force
Copy-Item (Join-Path $src 'tb\*.v')         (Join-Path $work 'tb') -Force
# 用户原有的 I2S.v 在工程根目录(不在 rtl/), 采样率验收 tb_i2s_rate 要用到它
if (Test-Path (Join-Path $src 'I2S.v')) {
    Copy-Item (Join-Path $src 'I2S.v') (Join-Path $work 'rtl\I2S.v') -Force
}

Push-Location $work
if (Test-Path work) { Remove-Item -Recurse -Force work }
& $vlib work | Out-Null
& $vmap work work | Out-Null

Write-Host "== 2/4 编译 (有 Error 就别往下看了)"
foreach ($f in 'rtl\I2S.v', 'rtl\sine_lut.v', 'rtl\partial_engine.v', 'rtl\note_ctrl.v',
               'rtl\test_pattern.v', 'rtl\i2s_48k.v', 'tb\tb_sine_lut.v', 'tb\tb_tables.v',
               'tb\tb_partial_engine.v', 'tb\tb_note_ctrl.v', 'tb\tb_i2s_rate.v',
               'tb\tb_vel_engine.v', 'tb\tb_vel_probe.v') {
    & $vlog -quiet $f 2>&1 | Select-String -Pattern 'Error|Fatal' | ForEach-Object { $_.Line }
}

Write-Host "== 3/4 仿真"
Write-Host "-- 3a 表格式"
& $vsim -c -quiet work.tb_tables 2>&1 | Select-String -Pattern 'TABLE' | ForEach-Object { $_.Line }

Write-Host "-- 3b 正弦表频谱 (有插值 / 无插值)"
foreach ($ie in 1, 0) {
    & $vsim -c -quiet -do "run -all; quit -f" work.tb_sine_lut "+INTERP=$ie" "+FTW=85917696" "+N=65536" "+OUT=sine_interp$ie.txt" 2>&1 |
        Select-String -Pattern 'Errors|Fatal' | ForEach-Object { $_.Line }
}

Write-Host "-- 3c 引擎: 单音 (MIDI 69)"
& $vsim -c -quiet -do "run -all; quit -f" work.tb_partial_engine "+NVOICE=1" "+N0=69" "+NSAMP=4096" "+OUT=eng_1voice.txt" 2>&1 |
    Select-String -Pattern 'active_voices|pass_clks|overrun|8388607' | ForEach-Object { $_.Line }

Write-Host "-- 3d 引擎: 32 复音 (MIDI 45 + 2v)"
& $vsim -c -quiet -do "run -all; quit -f" work.tb_partial_engine "+NVOICE=32" "+N0=45" "+NSAMP=4096" "+OUT=eng_32voice.txt" 2>&1 |
    Select-String -Pattern 'active_voices|pass_clks|overrun|8388607' | ForEach-Object { $_.Line }

Write-Host "-- 3e I2S 实际采样率 (原版 vs 修正版)"
& $vsim -c -quiet -do "run -all; quit -f" work.tb_i2s_rate 2>&1 |
    Select-String -Pattern 'user|fixed|theory' | ForEach-Object { $_.Line }

Write-Host "-- 3f 交互层: 键事件 -> note_ctrl -> 引擎 (8 复音 / 弯音 / 颤音 / 超复音抢占)"
& $vsim -c -quiet -do "run -all; quit -f" work.tb_note_ctrl 2>&1 |
    Select-String -Pattern 'seg|busy_cnt|steal|pass_clks' | ForEach-Object { $_.Line }

Write-Host "-- 3g 力度分层: pp / mf / ff 三层各按一个音 (引擎读分层表)"
foreach ($pair in @(@('pp', 8), @('mf', 72), @('ff', 127))) {
    $vn = $pair[0]; $vel = $pair[1]
    Write-Host ("   [$vn] vel=$vel 层=" + [int]($vel / 16))
    & $vsim -c -quiet -do "run -all; quit -f" work.tb_vel_engine "+VEL=$vel" "+N0=69" "+NSAMP=4096" "+OUT=vel_$vn.txt" 2>&1 |
        Select-String -Pattern 'active_voices|pass_clks|overrun|输出峰值' | ForEach-Object { $_.Line }
}
Write-Host "-- 3h 分层取表路径 (BSRAM 时隙 gain 初值 vs 层表)"
& $vsim -c -quiet -do "run -all; quit -f" work.tb_vel_probe "+VEL=127" "+NVOICE=4" 2>&1 |
    Select-String -Pattern 'VEL_PROBE|VOICE |SLOT' | Select-Object -First 26 | ForEach-Object { $_.Line }
Pop-Location

Write-Host "== 4/4 Python 验收"
& $py (Join-Path $PSScriptRoot 'verify_tables.py')
& $py (Join-Path $PSScriptRoot 'verify_sine_lut.py')
& $py (Join-Path $PSScriptRoot 'verify_engine.py') --file "$work\eng_1voice.txt"  --nvoice 1  --n0 69 --div 1041
& $py (Join-Path $PSScriptRoot 'verify_engine.py') --file "$work\eng_32voice.txt" --nvoice 32 --n0 45 --div 1041
& $py (Join-Path $PSScriptRoot 'verify_note_ctrl.py') --dir $work
Write-Host "-- 4b 力度分层专项 (表内容 + 引擎逐层 + RTL 取表路径)"
& $py (Join-Path $PSScriptRoot 'verify_vel_layers.py')

Write-Host "`n产物: $work\sine_interp1.txt / sine_interp0.txt / eng_1voice.txt / eng_32voice.txt / vel_pp.txt / vel_mf.txt / vel_ff.txt / nc_seg1..3.txt"