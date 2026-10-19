# FTP Puller — FTP 准实时抽取 / 同步工具

一套**离线、纯标准库**的 FTP 抽取方案：在一台 Linux 中转机上周期性地从「源端 FTP」把文件拉到本地、做校验后落盘，供**网闸**再来抽走。源端文件默认**搬家式删除**（抽走并校验通过后删除源端，源端不长期堆积）。

> 适用环境：openEuler 24.03 SP3 x86_64（其他 RHEL 系 / 带 systemd 的 Linux 同理），目标机**纯离线**安装。
> 文档版本：2026-10 整理，开源发布版。

---

## 一、它解决什么问题

| 约束 | 说明 |
|---|---|
| 只能 FTP | 源服务器不提供 SSH、不能改源端程序，只能被动接受 FTP 拉取 |
| 准实时 | FTP 没有推送能力，只能由中转机**周期性轮询**源端目录 |
| 搬家式 | 抽到本地、校验通过后**删除源端文件**，源端不堆积 |
| 防误删 | 带校验（大小必做，能哈希更好），防止半截 / 损坏文件被误判成功而删源 |
| 凭证外置 | IP / 账号 / 密码写在 conf 或安装脚本的「可修改区」，不写死在主逻辑里 |
| 离线安装 | 目标机最小化安装，缺依赖，**所有 rpm 随包离线提供** |
| 双角色 | 中转机既抽源端，又开 FTP 供网闸来抽 |

---

## 二、整体架构与数据流向

```
┌──────────────────┐    FTP 抽取(轮询)     ┌────────────────────────────┐    FTP 抽取     ┌──────────┐
│  源服务器 (被抽取) │ ───────────────────▶ │   拉取服务器 (双角色中转机)   │ ────────────▶ │   网闸    │
│  只装 vsftpd +     │   ftp_puller 主动来拉  │  A. ftp_puller 抽取端         │  从本机抽走     │          │
│  一个源账户        │   搬家式删源          │     落盘 → 网闸目录            │                │          │
└──────────────────┘                       │  B. vsftpd + 网闸账户         │                │          │
                                            └────────────────────────────┘                └──────────┘

数据方向：源服务器 →(中转机抽)→ 中转机 →(网闸抽)→ 网闸。源服务器与网闸彼此不直接相连。
（图中 192.168.5.x 为示例内网 IP，部署时按实际网络填写。）
```

---

## 三、仓库内容（两个离线包即可重装）

重装系统后只需把对应包 copy 到目标机 `unzip` 即可。

### `ftp_server_pkg/`（给源服务器 / 被抽取端）
| 内容 | 作用 |
|---|---|
| `install.sh` | 一键部署：装 vsftpd + logrotate、建源账户、写配置、放行防火墙 / SELinux、启动 |
| `vsftpd.conf` | 干净配置（关匿名 / chroot / 被动自动探测 / 白名单） |
| `rpms/` | vsftpd、logrotate 离线 rpm |
| `base_tools/` | 基础工具 rpm（tar / net-tools / lsof / procps-ng / wget / ftp 客户端）+ 安装脚本 |

### `ftp_puller_pkg/`（给中转机 / 双角色机）
| 内容 | 作用 |
|---|---|
| `ftp_puller_verify.py` | **主脚本**：抽取搬运工（纯标准库、进度条、校验、硬盘监控、日志轮转） |
| `ftp_puller.conf.example` | 配置示例（全中文注释） |
| `ftp_puller.service` | systemd 服务（崩溃 30 秒后自动拉起） |
| `install.sh` | 一键部署：第 1~5 步装抽取端，**第 6 步内置网闸对接**（开 vsftpd + 建网闸账户） |
| `vsftpd.conf` | 网闸对接用的 vsftpd 配置 |
| `test.sh` | 交互式预检 + 确认源端删除策略 + 确认启动 |
| `uninstall.sh` | 卸载 |
| `rpms/` `base_tools/` | 离线 rpm 与基础工具 |

> 单独的 `ftp_gate_pkg/`（网闸对接包）已**并入** `ftp_puller_pkg/` 的第 6 步，不再单独交付。
> `ftp_full_offline/`、`*_offline/` 为整合 / 离线全集目录，内容与上述包一致，便于一次性拷贝。

---

## 四、快速部署（root 执行）

### 4.1 源服务器（只装被抽取端）
```bash
unzip ftp_server_pkg.zip
cd ftp_server_pkg
bash install.sh            # 建源账户 + 起 vsftpd
# 装完把待抽业务文件丢进该账户家目录即可，抽取端会来抽
```

### 4.2 中转机（抽取端 + 网闸对接，一步到位）
```bash
unzip ftp_puller_pkg.zip
cd ftp_puller_pkg
bash install.sh            # 第1~5步装抽取端；第6步自动建网闸账户 + 起 vsftpd
```
装完**填配置**（`REMOTE_DIR` 在 chroot 环境填 `/`，不是源账户家目录）：
```bash
vi /opt/ftp_puller/ftp_puller.conf
#   FTP_HOST=<源服务器IP>
#   FTP_USER=<源账户>
#   FTP_PASS=<源账户密码>
#   REMOTE_DIR=/                 # chroot 后根即源账户家目录
#   LOCAL_DIR=/home/ftpadmin     # 须与网闸目录一致
#   MIN_AGE=30
#   DISK_PATH=/home
#   DISK_THRESHOLD=80
#   LOG_KEEP_DAYS=180
#   CHOWN_LOCAL=1
```
先干跑确认目录正确（只列、不下载、不删）：
```bash
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py
```
确认列出的文件无误后正式开跑：
```bash
systemctl enable --now ftp_puller
tail -f ~/ftp_puller_verify.log
```
网闸侧直接连接中转机的 `ftp://<中转机IP>:21`，账户 / 目录见下方「安全与配置」。

---

## 五、配置参考（`/opt/ftp_puller/ftp_puller.conf`）

| 块 | 项 | 默认 | 说明 |
|---|---|---|---|
| ① 源服务器 | `FTP_HOST` / `FTP_USER` / `FTP_PASS` | — | 源端地址 / 账户 / 密码（必填） |
| | `REMOTE_DIR` | `/` | 源端目录（chroot 环境填 `/`） |
| ② 落盘 | `LOCAL_DIR` | `/home/ftpadmin` | 本机落盘（= 网闸取的 FTP 家目录） |
| | `MIN_AGE` | 120（建议 30） | 跳过 N 秒内改过的文件，避免拉到半截 |
| ③ 硬盘监控 | `DISK_PATH` | `/home` | 监控该路径所在分区 |
| | `DISK_THRESHOLD` | 80 | 使用率%达阈值后自动按最旧清理；`0`=关闭 |
| ④ 日志 | `LOG_KEEP_DAYS` | 180 | 按天轮转，保留 N 天；`0`=永久 |
| ⑤ 网闸 | `CHOWN_LOCAL` | 0（装包后 1） | 落盘改属主为网闸账户（网闸可删） |
| | `DELETE_SOURCE` | 1 | 1=搬家式删源端；0=纯留存 |
| ⑥ 节奏 | `INTERVAL` | 60 | 每轮等待间隔（秒） |
| 授权 | `LICENSE_FILE` | 空 | 授权路径（默认程序同级 `license.dat`） |

> 三个独立时间项：`MIN_AGE`（跳过太新的文件）、`INTERVAL`（每轮间隔）、`RestartSec`（systemd 拉起间隔）。想 30 秒抽一轮改 `INTERVAL`，改 `MIN_AGE` 无效。

---

## 六、安全与配置注意事项（部署前必读）

1. **口令是占位符，务必改**：仓库内原先硬编码的两处 FTP 口令（网闸账户口令、源端账户口令）
   均已被替换为 `CHANGE_ME_GATEWAY_PASSWORD` / `CHANGE_ME_SOURCE_PASSWORD`。部署前，在对应 `install.sh`
   的「可修改区」把它改成你自己的口令；`install.sh` 末尾会打印实际账户 / 密码供配网闸。
2. **授权机制（license.dat）**：程序内置 HMAC-SHA256 + 使用期限的授权校验，密钥硬编码在
   `license_core.py` 中（与离线生成器 `license_pkg/index.html` 共用算法）。**本仓库发布的是示例占位授权
   （到期 2030-12-31）**，正式交付请用 `license_pkg` 生成真实 `license.dat` 覆盖。
   注意：开源后该授权密钥随之公开，此机制不再构成强保护——如需真正可控的授权，请另行设计。
3. **内网 IP 为示例**：文档 / 拓扑图中的 `192.168.5.x` 仅为拓扑示意，按实际网络替换。
4. **零泄露原则**（历史经验）：交付前全仓 grep 内部命名 / 真实凭据 / 黑话；改了源码必须重打包并校验包内内容。

---

## 七、常用运维命令

```bash
# 实时日志（进度条 / 抽取明细）
tail -f ~/ftp_puller_verify.log
# 历史日志（按天）
ls -1 ~/ftp_puller_verify.log.*

# 服务 停 / 起 / 状态
systemctl stop ftp_puller
systemctl start ftp_puller
systemctl status ftp_puller

# 改配置后重启
vi /opt/ftp_puller/ftp_puller.conf
systemctl restart ftp_puller

# 手动干跑（不下载不删，确认目录正确）
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py

# 源端 / 网闸端 FTP 服务状态
systemctl status vsftpd

# 卸载
bash /opt/ftp_puller/uninstall.sh
```

---

## 八、日志标签速查（排错用）

| 标签 | 含义 |
|---|---|
| `[WATCH]` | 每轮监听源端目录，列出待抽取的文件名与数量 |
| `[SCAN]` | 扫描目录，列出文件大小 / 修改时间，标注「随车.md5」或「太新」 |
| `[SKIP]` | 文件可能仍在写入，暂不抽 |
| `[PULL]` | 开始抽取某文件（带时间戳、总大小） |
| `[PROGRESS]` | 单行刷新进度条（百分比 + 已下载 / 总大小） |
| `[MOVED]` | 抽取成功并删除源端（搬家式完成） |
| `[FAIL]` / `[ERROR]` / `[FATAL]` | 大小 / 哈希不符、下载失败、重试耗尽 |
| `[KEEP]` | 校验未过，保留远端等下轮重试 |
| `[PURGE]` | 硬盘监控触发，删除最久文件 |
| `[CHOWN]` | 落盘文件改属主（网闸可删） |
| `[CLEAN]` | 删除上次残留的 `.part` |
| `[SUMMARY]` | 本轮 抽走 / 跳过 / 失败 + 源端剩余 + 累计已抽走 |
| `[DRYRUN]` | 干跑预览（不下载不删） |

---

## 九、目录结构速览

```
ftp-puller/
├── README.md                      # 本文件
├── FTP抽取方案_全流程与实现详解.md   # 方案详解（架构 / 流程 / 踩坑）
├── 开发流程总结.md                  # 开发复盘（含原则与待办）
├── 服务端安装文档.txt               # 简洁安装说明（随交付包发客户）
├── ftp_topology.svg                # 拓扑图
├── ftp_puller.sh / ftp_puller_verify.py  # 抽取主脚本（py 为编译源）
├── license_js_test.js / _js_lic.txt / _py_lic.txt  # 授权校验测试
├── ftp_server_pkg/   # 源服务器包（被抽取端）
├── ftp_puller_pkg/   # 中转机包（抽取端 + 网闸对接）
├── ftp_gate_pkg/     # 网闸对接包（已并入 ftp_puller_pkg 第6步）
├── license_pkg/      # 离线授权生成器（index.html + license_core.py）
├── base_tools_offline/ ftp_server_offline/ ftp_puller_offline/ ftp_full_offline/  # 离线全集
└── pack_deploy.py / check_5132.py / exec_fix.py  # 打包 / 校验辅助脚本
```

---

## 十、许可证

本仓库目前**未包含 LICENSE 文件**。在添加明确的开源协议前，依据版权法默认保留所有权利
（all rights reserved），他人无权随意复制、修改或再分发。如需以某种开源协议（如 MIT / GPL）
发布，请在仓库根目录补充对应 `LICENSE` 文件后再对外分发。

---

*—— 工具由内部开发整理，文档均来自工程实践与当前工作区文件核对。*
