# FTP Puller 离线包 (抽取端)

部署在**拉取服务器（拉取端 / 双角色机）**上（例：192.168.1.100）。它周期性地从"源服务器"用 FTP 把文件
拉过来（搬家式：拉完校验通过即删除源端文件），落在本机目录；同时本包已内置**网闸对接**：
`install.sh` 会自动再开一个 vsftpd + 建 `ftpadmin` 账户（家目录＝落盘目录），让网闸来抽走。
一台机器 `bash install.sh` 即可同时具备"抽源端"和"供网闸抽"两个角色。

## 包含的组件
- `ftp_puller`             —— **主程序（已编译的 Linux 二进制，无源码、防拷贝）**
- `ftp_puller.conf.example` —— 配置示例
- `install.sh`             —— 一键部署（自动识别二进制并生成 systemd 服务）
- `uninstall.sh`           —— 一键卸载（反向 install.sh 的所有改动）
- `vsftpd.conf`            —— 供网闸抽取用的 FTP 配置
- `rpms/`                 —— vsftpd / logrotate 离线 rpm
- `base_tools/`            —— 离线基础工具 rpm（tar/netstat/lsof/ps/wget/ftp 客户端）

> 说明：部署包内**不再含明文 `.py` 源码**与编译脚本，发布的就是这个二进制本身；
> 授权校验与密钥已编译进二进制。换锁 / 重新生成授权请联系供应商。

> **两包说明**：本包是**部署包**（发到目标机运行，只带"校验器"，不自带授权生成功能）。
> 生成授权文件 `license.dat` 等操作由供应商统一完成，不随部署包发布。

## 安装（重装系统后）
以 root 在解压目录执行：
```bash
bash install.sh
```

## 配置（关键）
编辑 `/opt/ftp_puller/ftp_puller.conf`（分 6 块，文件内已注释）：

**① 源服务器**
| 项 | 说明 | 示例 |
|---|---|---|
| `FTP_HOST` | 源服务器 IP | `192.168.1.100` |
| `FTP_USER` | 源端 FTP 账户 | `ftp` |
| `FTP_PASS` | 源端 FTP 密码 | `请填写源服务器FTP密码` |
| `REMOTE_DIR` | 源端要抽的目录 | `/`（见下方 chroot 坑） |

**② 本机落盘 / 抽取**
| 项 | 说明 | 默认 |
|---|---|---|
| `LOCAL_DIR` | 本机落盘目录（= 网闸取的 FTP 家目录） | `/home/ftpadmin` |
| `MIN_AGE` | 跳过 N 秒内修改的文件（避开上传中），0=不限制 | `30` |

**③ 硬盘监控（自动清理）**
| 项 | 说明 | 默认 |
|---|---|---|
| `DISK_PATH` | 监控该路径所在分区的使用率 | `/home` |
| `DISK_THRESHOLD` | 使用率%达阈值后，自动按"最久优先"删 LOCAL_DIR 文件；`0`=关闭 | `80` |

**④ 日志**
| 项 | 说明 | 默认 |
|---|---|---|
| `LOG_KEEP_DAYS` | 日志按天轮转，保留最近 N 天（超过自动删）；`0`=永久 | `180` |
| （大小显示） | 所有日志里的文件大小统一用最小单位"字节"展示 | — |

**⑤ 文件/目录筛选（黑白名单）**
> 默认：**全部传输**（四项都留空）。需要挑着传时再填。优先级：白名单非空时只看白名单（黑名单失效）；白名单为空才看黑名单。扩展名逗号分隔，加不加点都行、自动小写，支持 `tar.gz` 复合后缀。

| 项 | 说明 | 默认 |
|---|---|---|
| `INCLUDE_EXT` | 文件类型白名单：只传这些扩展名，例 `zip,tar.gz` | 空（不限制） |
| `EXCLUDE_EXT` | 文件类型黑名单：跳过这些扩展名，例 `tmp,log,part` | 空（不限制） |
| `INCLUDE_DIRS` | 目录白名单：只进这些子目录（按目录名），例 `data,backup` | 空（不限制） |
| `EXCLUDE_DIRS` | 目录黑名单：跳过这些子目录（按目录名），例 `temp,cache` | 空（不限制） |
| `RECURSE_DIRS` | 是否递归子目录（文件夹传输）：`1`递归 `0`只抽顶层 | `1` |

**⑥ 网闸对接（可选）**
| 项 | 说明 | 默认 |
|---|---|---|
| `CHOWN_LOCAL` | 落盘后改属主为 LOCAL_DIR 拥有者（网闸可删）；`0`否 `1`是 | `0` |

**chroot 路径坑（必看）**：源端 vsftpd 默认把账户锁在家目录，脚本登录后看到的远端
`/` 就是家目录。所以 `REMOTE_DIR` 填 `/` 即可，**不要填 `/home/ftp`**（会变成
`/home/ftp/home/ftp` 抽不到）。

## 先干跑验证（不下载不删）
```bash
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 /opt/ftp_puller/ftp_puller
```
确认日志里 `[WATCH]` 列出的是正确的待抽文件，再正式开跑。

## 正式开跑
```bash
systemctl enable --now ftp_puller
```

## 看日志
```bash
tail -f /opt/ftp_puller/logs/ftp_puller_verify.log          # 当天日志(进度条/抽取明细实时滚动)
ls /opt/ftp_puller/logs/                                   # 历史日志(按天: .2026-10-09 / .2026-10-08 ...)
```
日志含：`[WATCH]` 监听清单、`[SCAN]` 文件状态、`[PULL]`+进度条、`[MOVED]` 抽走删源、
`[SKIP]` 上传中跳过、`[SKIP-EXT]`/`[SKIP-DIR]` 被黑白名单筛掉跳过、`[PURGE]` 硬盘清理（删最久文件）、`[SUMMARY]` 本轮/累计统计。
所有文件大小均用"字节"单位，方便你逐项核对（例：`627780197 字节`）。
日志按天自动轮转（当天 `ftp_puller_verify.log`，历史 `ftp_puller_verify.log.YYYY-MM-DD`），
保留最近 `LOG_KEEP_DAYS` 天（默认 180），超期自动删除，不会无限堆积。

## 停机
```bash
systemctl stop ftp_puller
```

## 卸载（反向 install.sh 的所有改动）
```bash
bash uninstall.sh                 # 交互: 打印将执行的操作, 输入 YES 才执行
bash uninstall.sh --yes           # 非交互: 直接执行(保留网闸账户家目录)
bash uninstall.sh --yes --remove-gate   # 连网闸 ftpadmin 账户及其家目录一并删除
```
会做：停/禁用 `ftp_puller` 服务 → 删 `/opt/ftp_puller` → 删服务文件 → 还原/删除我们写入的
vsftpd 配置并停 vsftpd → 从 `user_list` 移除 ftpadmin。
默认**不删** `/home/ftpadmin`（避免误删网闸还没抽走的落盘文件），只有 `--remove-gate` 才删。
基础工具 rpm / vsftpd 软件包本身不卸载（通用工具，避免影响其他用途）。

## ⑦ 授权（防拷贝 / 期限控制）

本工具带「使用期限」授权：**没有合法且未过期的 `license.dat`，程序启动即拒绝运行**。
授权逻辑**只校验两件事**——① HMAC-SHA256 签名防篡改；② 使用期限是否过期。
**不绑定机器码、不联网、与具体业务无关**。授权校验与密钥已编译进 `ftp_puller` 二进制。

- **生成授权 / 换锁**等操作由供应商完成，不随本部署包发布。
- 把供应商提供的 `license.dat` 放到部署机的 `/opt/ftp_puller/license.dat`（或与二进制同目录）即可。
- 授权失效表现：日志首行 `[LICENSE-FAIL] 未找到授权文件 / 授权已过期 / 签名校验失败`，程序 `exit(1)`。

