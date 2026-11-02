# 固件（不在本仓库中）

本仓库**不含** `.fs` 比特流二进制（每个约 7 MB，7 个共约 48.8 MB），原因：

1. 比特流是构建产物，可由 `lowlat/syn_ble_fsr_keys.tcl` 重新综合；
2. 公开仓库保持轻量，避免大二进制进入 git 历史（历史一旦写入很难清掉）；
3. 赛方要求代码包走 RAR 上传，固件二进制随 RAR 一起提交即可。

## 在哪里拿固件

- **比赛提交的 RAR 包**：`firmware/` 目录里的 7 个 `.fs`；
- **GitHub Release**：把 7 个 `.fs` 作为 Release 附件上传（命令见仓库外的提交说明）；
- 或作者网盘（在 Release 说明里给链接）。

## 有哪些固件

见 [`固件对照表.md`](固件对照表.md)。摘要：

| 固件 | 用途 |
|---|---|
| `07_full_keyboard_v33_reverb.fs` | 推荐演示 |
| `03_piano_keyboard_top_keymatrix.fs` | 最稳兜底（钢琴 only） |
| 其余 01/02/04/06/12 | 场景备选与诊断 |

## 自己构建

```powershell
# 1) 把 rtl/ 与 lowlat/ 复制到纯 ASCII 目录（Gowin 不认中文路径）
robocopy .\rtl    D:\gowin_bfs\rtl    /E
robocopy .\lowlat D:\gowin_bfs\lowlat /E
cd D:\gowin_bfs

# 2) 综合（约 3~10 分钟）
& 'D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe' lowlat\syn_ble_fsr_keys.tcl *> build.log

# 3) 判据：ERROR 计数为 0，且 impl\pnr\project.timing_paths 第 2 行 SETUP slack >= 0
(Select-String -Path build.log -Pattern 'ERROR \(').Count
Get-Content impl\pnr\project.timing_paths -TotalCount 2

# 4) 产物
impl\pnr\project.fs
```
