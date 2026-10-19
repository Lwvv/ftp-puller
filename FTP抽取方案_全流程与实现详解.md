# FTP 准实时抽取方案 —— 全流程与实现详解

> 适用环境：openEuler 24.03 SP3 x86_64，纯离线（不联网安装）
> 适用场景：A 服务器有源端 FTP 读写账号 → 周期性把文件抽到中转机 → 网闸再从该中转机抽走
> 文档版本：2026-10-10 定稿（含硬盘监控、日志按天轮转保留 180 天、网闸对接并入抽取端包）

---

## 一、需求背景与约束

| 约束 | 说明 |
|---|---|
| 只能 FTP | 源服务器不提供 SSH、不能改动源端程序，只能被动接受 FTP 拉取 |
| 准实时 | FTP 协议本身没有"推送/通知"能力，只能由中转机**周期性轮询**源端目录 |
| 搬家式 | 抽到本地、校验通过后**删除源端文件**（源端不长期堆积） |
| 防误删 | 必须带校验（大小必做，能哈希更好），防止半截/损坏文件被误判成功而删源 |
| 凭证外置 | IP / 账号 / 密码写在 conf 或环境变量，不写死在脚本里 |
| 离线安装 | 目标机是最小化安装，缺 tar/netstat/python 依赖等，必须离线 rpm 安装 |
| 双角色 | 中转机（131）既抽源端（132），又开 FTP 供网闸来抽 |

---

## 二、整体架构与数据流向

```
┌─────────────────────┐         FTP抽取(轮询)          ┌──────────────────────────────┐         FTP抽取         ┌──────────┐
│  源服务器 192.168.5.132 │ ───────────────────────────▶ │  拉取服务器 192.168.5.131 (双角色) │ ──────────────────▶ │   网闸    │
│  (被抽取端)              │    ftp_puller 脚本主动来拉     │  A. ftp_puller 抽取端              │   从 131 拉走        │          │
│  vsftpd + 账户 ftp       │   搬家式删源                 │     落盘 → /home/ftpadmin         │                     │          │
│  /home/ftp               │                              │  B. vsftpd + 账户 ftpadmin        │                     │          │
│  (业务文件放这里)         │                              │     /home/ftpadmin (供网闸抽)      │                     │          │
└─────────────────────┘                              └──────────────────────────────┘                     └──────────┘

要点：
  - 132 只装"被抽取端"包，只建 ftp/CHANGE_ME_SOURCE_PASSWORD 一个源账户，把待抽文件丢进 /home/ftp。
  - 131 装"抽取端"包（一步到位，内置网闸对接）：脚本把文件抽来丢进 /home/ftpadmin；
    同时 131 自己开 vsftpd + 建 ftpadmin/CHANGE_ME_GATEWAY_PASSWORD，让网闸来抽 /home/ftpadmin。
  - 数据方向：132 →(131 抽)→ 131 →(网闸抽)→ 网闸。132 与网闸彼此不直接相连。
```

---

## 三、两个离线包（最终交付物）

重装系统后只需这两个 zip，copy 到对应机器 `unzip` 即可。

### 3.1 `ftp_server_pkg.zip`（给 132 / 被抽取端 / 源服务器）
| 内容 | 作用 |
|---|---|
| `install.sh` | 一键部署：装 vsftpd+logrotate、建 `ftp` 源账户、写配置、放行防火墙/SELinux、启动 |
| `vsftpd.conf` | vsftpd 干净配置（关匿名 / chroot / 被动自动探测 / 白名单） |
| `rpms/` | `vsftpd-3.0.5`、`logrotate` 两个离线 rpm |
| `base_tools/` | 基础工具 rpm（tar / net-tools / lsof / procps-ng / wget / ftp 客户端）+ 安装脚本 |

### 3.2 `ftp_puller_pkg.zip`（给 131 / 抽取端 / 双角色机）
| 内容 | 作用 |
|---|---|
| `ftp_puller_verify.py` | **主脚本**：抽取搬运工（纯标准库、进度条、校验、硬盘监控、日志轮转） |
| `ftp_puller.conf.example` | 配置示例（5 大块，文件内注释完整） |
| `ftp_puller.service` | systemd 服务（崩溃/异常 30 秒后自动拉起） |
| `install.sh` | 一键部署：**第 1~5 步装抽取端**，**第 6 步内置网闸对接**（开 vsftpd + 建 ftpadmin） |
| `vsftpd.conf` | 网闸对接用的 vsftpd 配置（与源端同源） |
| `rpms/` | `vsftpd`、`logrotate` 离线 rpm（供第 6 步网闸对接用） |
| `base_tools/` | 基础工具 rpm + 安装脚本 |

> 说明：之前单独存在的 `ftp_gate_pkg.zip`（网闸对接包）已**并入** `ftp_puller_pkg.zip` 的第 6 步，不再单独交付。

---

## 四、部署流程（重装系统后，root 执行）

### 4.1 源服务器 132（只装被抽取端）
```bash
unzip ftp_server_pkg.zip
cd ftp_server_pkg
bash install.sh
# 装完把业务文件丢进 /home/ftp 即可（抽取端会来抽）
```
`install.sh` 做了什么（详见第六节）：
1. 用包内 rpm **离线**装 vsftpd + logrotate（`rpm -Uvh --replacepkgs`，绝不调 dnf/yum）
2. 新建账户 `ftp` / `CHANGE_ME_SOURCE_PASSWORD`，家目录 `/home/ftp`，shell `/sbin/nologin`
3. 写入 `vsftpd.conf`
4. firewalld 放行 21 + 被动端口 30000-31000
5. SELinux 放通 `ftpd_full_access`，启动 vsftpd 并开机自启

### 4.2 拉取服务器 131（抽取端 + 网闸对接，一步到位）
```bash
unzip ftp_puller_pkg.zip
cd ftp_puller_pkg
bash install.sh            # 第1~5步装抽取端；第6步自动建 ftpadmin + 起 vsftpd（网闸对接）
```
装完**填配置**（关键一步，REMOTE_DIR 填 `/` 不是 `/home/ftp`）：
```bash
vi /opt/ftp_puller/ftp_puller.conf
#   FTP_HOST=192.168.5.132
#   FTP_USER=ftp
#   FTP_PASS=CHANGE_ME_SOURCE_PASSWORD
#   REMOTE_DIR=/                 # chroot 后根即 /home/ftp
#   LOCAL_DIR=/home/ftpadmin
#   MIN_AGE=30
#   DISK_PATH=/home
#   DISK_THRESHOLD=80
#   LOG_KEEP_DAYS=180
#   CHOWN_LOCAL=1                # 已内置，让网闸抽走后能删本机文件
```
**先干跑验证目录正确**（只列不下载不删）：
```bash
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py
```
确认 `[WATCH]` 列出的是 132 上的真实文件，再正式开跑：
```bash
systemctl enable --now ftp_puller
tail -f ~/ftp_puller_verify.log     # 看实时进度条与抽取明细
```
网闸侧直接连 `ftp://192.168.5.131:21`，账户 `ftpadmin` / `CHANGE_ME_GATEWAY_PASSWORD`，目录 `/home/ftpadmin` 即可抽走文件。

---

## 五、运行时：每一轮抽取的工作流

脚本由 systemd 托管（`Restart=always` + `RestartSec=30`）：跑完一轮就退出，30 秒后被拉起下一轮，形成持续轮询。每轮内部流程：

```
开始
  │
  ├─ acquire_lock()        取 flock 运行锁，防止上一轮没退、本轮重叠
  ├─ cleanup_part_files()  删除上次崩溃残留的 .part 半截文件
  ├─ purge_oldest()        硬盘监控：/home 分区 ≥80% 时按最旧优先删 /home/ftpadmin 里的文件
  │
  ├─ 连接重试循环（最多 3 次）
  │    ├─ connect()         FTP(HOST, timeout=120) → 设 utf-8 → login → 被动模式
  │    ├─ collect_data_files()  递归收集源端"数据文件"清单（排除 .md5）
  │    ├─ [WATCH]          打印"当前有 N 个待抽取：文件名1、文件名2…"
  │    ├─ process(ftp, "")  核心：见下方"process 内部"
  │    └─ [SUMMARY]        本轮 抽走/跳过/失败 + 源端剩余 + 累计已抽走
  │
  └─ 退出（systemd 30 秒后拉起下一轮）
```

### `process()` 内部（对每个文件的完整生命周期）
```
对远端目录每个文件:
  1. [SCAN]  列出文件名/大小/修改时间；标注"随车.md5"或"太新(可能仍在上传)"
  2. [SKIP]  若文件修改时间距现在 < MIN_AGE(默认30s) → 跳过（等它传完稳定）
  3. [PULL]  下载到 本地.文件名.part
             └─ 单行 \r 进度条，每 0.5s 或每 1% 刷新一次（慢速也持续跳动）
  4. 大小校验  期望大小 != 实得大小 → [FAIL] 保留源端，等下轮重试
  5. 哈希校验  优先远端随车 .md5；其次尝试服务器 XMD5/XCRC；都没有则退回仅大小校验
             └─ 不符 → [FAIL] 保留源端
  6. [MOVED] 校验通过 → os.replace(.part, 正式文件) → 删远端源文件（搬家式）
             └─ CHOWN_LOCAL=1 时把属主改成 ftpadmin（网闸可删）
             └─ 顺带删除配对的 .md5
  7. 递归     对子目录递归 process()
```

> 关键设计：**删源（第 6 步）发生在"下载+校验全部通过"之后**。任何一步失败（下载中断、大小/哈希不符）都不会删源，最多是下轮重试，绝不丢数据。

---

## 六、实现原理详解（脚本 + 服务端）

### 6.1 主脚本 `ftp_puller_verify.py`（纯标准库，无需 pip）

**① 配置加载（三层优先级）**
- 环境变量 `FTP_PULLER_CONF` 指定 conf 路径（默认 `~/.ftp_puller.conf`）。
- 先把 conf 文件读成字典 `CONF`，再靠 `conf_get(key, default)` 解析：环境变量 > conf 文件 > 代码默认值。
- 这样**改配置只动 conf 文件，不动脚本**。

**② 可配置项（全部进 conf，见 3.1）**
`MIN_AGE`(稳定门槛秒) / `DISK_PATH`(监控分区) / `DISK_THRESHOLD`(清理阈值%) / `LOG_KEEP_DAYS`(日志保留天) / `CHOWN_LOCAL`(落盘改属主)。

**③ 日志与轮转 `log()` + `_rotate_daily()`**
- `log()` 统一加时间戳写 `~/ftp_puller_verify.log`，并 `print` 到终端。
- `_rotate_daily()`：每次写日志前，若当前日志的 **mtime 不是"今天"**，则把它归档为 `ftp_puller_verify.log.YYYY-MM-DD`；再扫描历史归档，删除**超过 `LOG_KEEP_DAYS`(默认180)天**的文件（设 0 永久保留）。→ 单文件只装"当天"，不膨胀；排查时 `tail -f` 看当天，历史在 `.log.YYYY-MM-DD`。

**④ 进度条 `draw_bar()` + 下载回调**
- 下载用 `ftp.retrbinary(..., cb)`，回调里 `f.write(b)` 落盘并累计字节。
- 进度条 `█░░░ 12% 12.0MB/598.7MB`，用 `\r` 单行原地刷新（log 文件里不写 `\n`，与下一帧叠加；完成时补 `\n` 收尾，异常时补 `\n` 防污染）。
- 刷新频率：每前进 **1%** 或每 **0.5 秒**（取先到）——慢速大文件也持续跳动，不会"看着像卡住"。无总大小时每 0.5s 循环滚动并标 `??% 传输中`。

**⑤ 校验 `md5_of/hashes_of/remote_hash`**
- 大小校验必做（`os.path.getsize` 比对）。
- 哈希：先下载远端 `<文件名>.md5` 随车文件比对；若没有则尝试 FTP 扩展命令 `XMD5` / `XCRC`（服务器不支持就跳过，退回仅大小校验）。

**⑥ 断线重连与锁**
- `connect()` 设 `timeout=120`、utf-8、被动模式。
- `main()` 用 `MAX_RETRIES=3` 包裹连接+处理，掉线 `sleep(5)` 后重连重试。
- `acquire_lock()` 用 `fcntl.flock` 排他锁，避免 cron/systemd 重叠执行。

**⑦ 硬盘监控 `purge_oldest()`**
- `shutil.disk_usage(DISK_PATH)` 取**该路径所在分区**使用率（填 `/home` 即取 `/home` 挂载点）。
- ≥ `DISK_THRESHOLD`(默认80%) 时，`os.walk(LOCAL_DIR)` 收集文件，按 **mtime 升序（最旧优先）** 逐个删除，每删一个重新算使用率，降到阈值即停。
- 安全边界：**只删 LOCAL_DIR 内部真实文件，`.part` 临时文件不删**（避免损坏正在下载的文件），不碰其他系统目录。

**⑧ 累计统计 `load_stats/save_stats`**
- 累计抽走文件数持久化到 `~/ftp_puller_verify.stats`（JSON），服务重启也不丢计数。

### 6.2 FTP 服务端实现（`install.sh` + `vsftpd.conf`，两个包共用同一套逻辑）

**被抽取端（132，只建 ftp 源账户）** 与 **网闸对接端（131，建 ftpadmin）** 的安装逻辑完全一致，只是账户参数不同。要点：
- **离线安装**：`rpm -Uvh --replacepkgs ./rpms/*.rpm`（绝不用 dnf/yum，离线机 dnf 会卡在刷元数据）。vsftpd 失败再退 `--nodeps`。
- **建账户**：先 `userdel -r` + `groupdel` 清残留（防"组存在但用户不存在"导致 useradd 静默失败）；`useradd -m -d 家目录 -s /sbin/nologin`；密码优先 `chpasswd`，失败退回 `usermod -p $(crypt SHA512)`。
- **PAM 放行**：`/sbin/nologin` 加入 `/etc/shells`，否则 vsftpd 的 PAM 拒绝登录。
- **权限**：家目录 `chmod 750`、`chown` 归该账户。
- **白名单**：账户写入 `/etc/vsftpd/user_list`；从 `/etc/vsftpd/ftpusers` 拒绝名单移除。
- **vsftpd.conf 安全基线**：关匿名、开本地账户、`chroot_local_user=YES` + `allow_writeable_chroot=YES`（锁家目录）、被动模式 30000-31000、**不写死 `pasv_address`**（让 vsftpd 自动用进来的网卡 IP，本地/远端都能连）、`userlist_deny=NO`（名单内才能登）。
- **防火墙/SELinux**：firewalld 放行 `ftp` 服务 + 被动端口；SELinux Enforcing 时 `setsebool -P ftpd_full_access on`（注意 RHEL9/openEuler 用 `ftpd_full_access`，老的 `ftp_home_dir` 已废弃）。

### 6.3 systemd 服务 `ftp_puller.service`
- `User=root`、`ExecStart=/usr/bin/python3 /opt/ftp_puller/ftp_puller_verify.py`、`Environment=FTP_PULLER_CONF=...`
- `Restart=always` + `RestartSec=30`：脚本跑完一轮退出后，30 秒自动拉起下一轮（这就是"准实时轮询"的实现方式）。`activating/auto-restart` 状态是设计行为，不是故障。

---

## 七、踩过的坑与解决（都已固化进脚本/安装包）

| # | 问题现象 | 根因 | 解决（已写死在包里） |
|---|---|---|---|
| 1 | 离线机 `dnf install` 卡死 | 刷新远程元数据，无网卡住 | 改用 `rpm -Uvh --replacepkgs`，绝不调 dnf/yum |
| 2 | 账户创建失败、vsftpd 起不来 | 同名组已存在，`useradd` 不带 `-g` 静默退出 | 建账户前先 `userdel -r` + `groupdel` 清残留 |
| 3 | vsftpd 启动报 `500 OOPS: bad bool value` | 配置行内写 `#` 注释，vsftpd 不支持 | 所有说明改为独立行注释（行首 `#`） |
| 4 | SELinux 放通失败 | 用了废弃的 `allow_ftpd_full_access` | 改为 `ftpd_full_access` |
| 5 | 本地 `ftp 127.0.0.1` PASV 被拒 | `pasv_address` 写死成 LAN IP，回环不对称 | 去掉写死，改自动探测 |
| 6 | 每轮空跑、从没 `[MOVED]` | `REMOTE_DIR=/home/ftp` 在 chroot 后变成 `/home/ftp/home/ftp` | 改 `REMOTE_DIR=/`（已写进 conf 注释提示） |
| 7 | `[PULL]` 后无 `[MOVED]`、服务反复 crash | ① 下载回调漏 `f.write(b)` 文件没落盘 ② `except (ftplib.all_errors, ...)` 在 Py3.11 抛 TypeError | 恢复 `f.write`；`except` 改 `(ftplib.Error, OSError)` |
| 8 | 627MB 进度条长时间不更新 | 每 2% 才刷新，慢速下约 9s 才动 | 改为每 1% 或每 0.5s 刷新（取先到） |
| 9 | 日志单文件无限膨胀 | 早期只按大小留 5 份 | 改为**按天轮转 + 保留 180 天**自动清理 |
| 10 | 网闸抽走后删不掉 131 上的文件 | 抽取脚本以 root 跑，落盘文件属主 root | `CHOWN_LOCAL=1` 把属主改回 ftpadmin（抽取端包第6步自动注入） |

---

## 八、配置参考（`/opt/ftp_puller/ftp_puller.conf`）

| 块 | 项 | 说明 | 默认 |
|---|---|---|---|
| ①源服务器 | `FTP_HOST` | 源服务器 IP | `192.168.5.132` |
| | `FTP_USER` / `FTP_PASS` | 源端账号密码 | `ftp` / `CHANGE_ME_SOURCE_PASSWORD` |
| | `REMOTE_DIR` | 源端目录（chroot 环境填 `/`） | `/` |
| ②落盘 | `LOCAL_DIR` | 本机落盘（=网闸取的FTP家目录） | `/home/ftpadmin` |
| | `MIN_AGE` | 跳过 N 秒内修改的文件（避上传中），0=不限制 | `30` |
| ③硬盘监控 | `DISK_PATH` | 监控该路径所在分区 | `/home` |
| | `DISK_THRESHOLD` | 使用率%达阈值后自动清理；`0`=关闭 | `80` |
| ④日志 | `LOG_KEEP_DAYS` | 按天轮转，保留 N 天；`0`=永久 | `180` |
| ⑤网闸 | `CHOWN_LOCAL` | 落盘改属主为 LOCAL_DIR 拥有者（网闸可删）；`0`否`1`是 | 装包后 `1` |

---

## 九、日志标签速查（排错用）

| 标签 | 含义 |
|---|---|
| `[WATCH]` | 每轮监听源端目录，列出待抽取的具体文件名与数量 |
| `[SCAN]` | 扫描目录，列出每个文件大小/修改时间，标注"随车.md5"或"太新" |
| `[SKIP]` | 文件可能仍在写入/未上传完，暂不抽 |
| `[PULL]` | 开始抽取某文件（带时间戳、总大小） |
| `[PROGRESS]` | 单行刷新进度条（百分比 + 已下载/总大小） |
| `[MOVED]` | 抽取成功并删除源端（搬家式完成） |
| `[FAIL]` / `[ERROR]` / `[FATAL]` | 大小/哈希不符、下载失败、重试耗尽 |
| `[KEEP]` | 校验未过，保留远端等下轮重试 |
| `[PURGE]` | 硬盘监控触发，删除最久文件（含释放量/当前使用率） |
| `[CHOWN]` | 落盘文件改属主（网闸可删） |
| `[CLEAN]` | 删除上次残留的 `.part` |
| `[SUMMARY]` | 本轮 抽走/跳过/失败 + 源端剩余 + 累计已抽走 |
| `[DRYRUN]` | 干跑预览（不下载不删） |

---

## 十、常用运维命令

```bash
# 看实时日志（进度条/抽取明细）
tail -f ~/ftp_puller_verify.log
# 看历史日志（按天）
ls -1 ~/ftp_puller_verify.log.*

# 停 / 起 / 看状态
systemctl stop ftp_puller
systemctl start ftp_puller
systemctl status ftp_puller

# 改配置后重启
vi /opt/ftp_puller/ftp_puller.conf
systemctl restart ftp_puller

# 手动干跑（不下载不删，确认目录正确）
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py

# 源端/网闸端 FTP 服务状态
systemctl status vsftpd
```
