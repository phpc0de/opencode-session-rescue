# opencode-session-rescue

> 🚨 **刚遭遇 OpenCode 崩溃/重启后历史会话全部变成 404？**
> **请先立即停止往当前硬盘下载大文件、运行 `VACUUM` 或磁盘清理/TRIM！**

一个用于抢救 **OpenCode Desktop / CLI v2.x（实测 v2.3.2）** 在 Linux `ext4` 环境下因异常崩溃 + 重启导致历史会话突然“清零 / 404”的自动化恢复脚本。

---

## 为什么会发生这个问题？（真实故障复盘）

在 Linux（`ext4`）上使用 OpenCode Desktop（`2.3.2`）时，如果软件崩溃或系统意外重启：
1. 原有的 SQLite 数据库（`opencode.db` / `-wal`）可能处于未正常落盘或孤立（orphan inode）状态，在下次开机系统清理孤立 inode 时被解除目录关联；
2. 开机后 `opencode-cli serve` 启动，发现 `~/.local/share/opencode/opencode.db` 缺失或异常，**会在 30ms 内静默执行全部 Schema Bootstrap（n 个 migrations），重新生成一个空白的 `opencode.db`**（并重新下载约 13.7MB 的 `models-dev:v2:catalog`）；
3. 桌面端 UI 缓存着旧标签页 ID，请求 `/api/session/ses_xxx` 全部返回 `404`，表面看起来像“库还在（14MB）但会话全没了”。

实际上，只要没有开启 `discard` / TRIM，**原来的旧 `opencode.db` 数据块和 Extents 往往还完整留在 `ext4` 底层。**

---

## 脚本做了什么？

`opencode-rescue.sh` 实现了从底层探测到无损替换的全自动闭环：

- **自动环境识别**：自动适配 `sudo` 下的真实用户、`XDG_DATA_HOME`、底层 `ext4` 块设备与文件系统块大小；
- **零写入二次破坏**：所有恢复与校验均在内存盘 `/dev/shm` 中完成，绝不向原磁盘写入大文件覆盖扇区；
- **精准头部嗅探**：通过 `debugfs` 读取被删 inode 的第 0 个物理块，**先验证 `SQLite format 3` 文件头再导出**，避免误导大体积缓存文件撑爆内存；
- **自动校验与修损**：依次检测 `session_v2` / `session` 表与 `PRAGMA integrity_check`；完好则用 `.backup` 导出，轻微受损则自动调用 `sqlite3 .recover` 重组；
- **安全替换**：默认仅做只读预演（Dry-run），传入 `--apply` 后才会安全停止 OpenCode、备份现有空库并清理残留 `-wal`/`-shm`，最后写回完整旧库。

---

## 快速使用

> **前置依赖**：`e2fsprogs` (`debugfs`, `tune2fs`)、`sqlite3`（大多数 Debian / Ubuntu / Kali 已自带）

### 1. 下载并只读扫描（安全预演，不会修改任何原文件）

```bash
chmod +x opencode-rescue.sh
sudo ./opencode-rescue.sh

如果检测到可恢复的历史库，你会看到类似输出：
Text

🔍 发现候选 SQLite 文件: inode=3067027, size=403MB, 正在导出检验...
   ✅ 校验通过: integrity=ok, 发现历史会话数=128 (v2=128, v1=0)
🎉 最佳可恢复副本: /dev/shm/opencode-rescue-xxxx/clean_3067027.db

2. 确认无误后，一键应用恢复
Bash

sudo ./opencode-rescue.sh --apply

脚本会自动关闭当前 OpenCode 进程、把当前空库备份至 rescue_backup_YYYYMMDD_HHMMSS/，并将恢复后的干净库写回 opencode.db。完成后重新打开 OpenCode 即可看到所有历史会话。
可选参数

    --data-dir <PATH>：手动指定 OpenCode 数据目录（默认 ~/.local/share/opencode）

    --min-size <BYTES>：扫描最小文件字节数（默认 65536）

适用边界与免责声明

    仅适用于 Linux ext4 文件系统，且未启用 mount -o discard 或未在重启后执行过 fstrim 擦除空闲块；

    如果系统已将对应 inode 的 Extent 树清零或扇区已被新写入数据覆盖，本脚本无法通过 lsdel 恢复（需进一步使用 ext4magic 或原始扇区页雕刻）；

    强烈建议在恢复后为 ~/.local/share/opencode/opencode.db 配置定期增量快照（如 sqlite3 .backup + restic / backrest），避免把所有历史记录压在单点数据库上。
