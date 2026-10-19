# FTP 整套离线安装包 (openEuler 24.03 SP3 x86_64)

一个 zip 包搞定三件事：**基础工具补包 + FTP 服务端 + 抽取端**，全程离线、零联网。

## 包内组成

```
ftp_full_offline/
├── install-all.sh            # 总一键安装 (root 运行)
├── README.md                 # 本说明
├── base_tools_offline/       # ① 基础工具: tar/netstat/lsof/ps/wget/ftp (6个rpm)
├── ftp_server_offline/       # ② FTP 服务端: vsftpd + logrotate + 配置 + 一键建账户
└── ftp_puller_offline/       # ③ 抽取端: 纯 Python 拉取脚本(校验+删源) + systemd
```

- **① 基础工具**：最小安装缺的 tar / netstat / lsof / ps / wget / ftp 命令行客户端。
- **② FTP 服务端**：vsftpd，新建账户 `ftpadmin / CHANGE_ME_GATEWAY_PASSWORD`，文件家目录 `/home/ftpadmin`（落在 420G 大分区）。
- **③ 抽取端**：定时从 FTP 拉文件、做大小/MD5 校验、校验通过才删源（搬家式）。纯 Python 标准库，不依赖 pip。

## 解压（重要：最小安装可能没有 unzip）

如果服务器上 **有 `unzip`**：
```bash
unzip ftp_full_offline.zip
```

如果服务器上 **没有 `unzip`**（最小安装常见），用系统自带的 python3 解（无需任何额外包）：
```bash
python3 -m zipfile -e ftp_full_offline.zip /tmp/
# 解出来在 /tmp/ftp_full_offline/
```

> 说明：zip 不保证保留文件可执行位，因此本包所有脚本都用 `bash xxx/install.sh` 显式执行，不需要先 chmod +x。

## 安装（root 运行）

```bash
cd /tmp/ftp_full_offline       # 或你解压到的目录
sudo bash install-all.sh
```

脚本会按顺序装：① 基础工具 → ② FTP 服务端（含建账户、写配置、开防火墙、开机自启）→ ③ 抽取端（部署到 `/opt/ftp_puller` 并装 systemd）。

## 安装后配置与验证

```bash
# 1) 填抽取端配置 (FTP_HOST 填目标机IP, REMOTE_DIR 填 /home/ftpadmin)
vi /opt/ftp_puller/ftp_puller.conf
chmod 600 /opt/ftp_puller/ftp_puller.conf

# 2) 干跑验证: 只看不拉, 确认盯的目录没错
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py

# 3) 正式开跑 (开机自启 + 崩溃自愈)
systemctl enable --now ftp_puller

# 4) 手动测 FTP 服务端 (验证账户能否登录 / 被动模式 / XMD5)
ftp 127.0.0.1
#   Name: ftpadmin   Password: CHANGE_ME_GATEWAY_PASSWORD

# 5) 看运行日志
tail -f ~/ftp_puller_verify.log
```

## 依赖与离线说明

- 所有 rpm 均选自 openEuler 24.03-LTS-SP3 官方源，已逐一核对依赖：
  - vsftpd 仅需 glibc/libcap/openssl-libs/pam（系统自带）+ 硬依赖 logrotate（已同包打入）；
  - 基础工具 6 个包仅有 systemd / 基础库依赖，零额外包；
  - 抽取端纯 Python 标准库，仅需系统 python3（oe24.03 自带 3.11）。
- 安装全程使用 `rpm -Uvh --replacepkgs` / 文件复制，**不调用 dnf/yum**，因此**不会联网刷新软件源**（离线机用 dnf 会卡死）。

## 单独安装某一个组件

也可以只装其中一部分，进入对应子目录单独跑它的 `install.sh` 即可，互不影响：
```bash
bash base_tools_offline/install.sh
bash ftp_server_offline/install.sh
bash ftp_puller_offline/install.sh
```
