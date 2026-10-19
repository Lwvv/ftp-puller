# FTP Puller 离线部署包（openEuler / 通用 Linux）

纯 Python 标准库实现，**零 pip 依赖、可完全离线运行**。功能：从目标 FTP 服务器
**单向抽取文件到本机，并删除远端源文件（搬家式）**，下载后做 **大小校验**，若服务器
支持 `XMD5`/`XCRC` 或用随车 `.md5` 则再做 **MD5 校验**，**校验通过才删源**。

适配目标机：Linux localhost 6.6.0 (openEuler 24.03 SP3 x86_64)，需 `python3`。

## 包内文件
- `ftp_puller_verify.py`  主脚本（纯标准库）
- `ftp_puller.conf.example` 配置模板
- `ftp_puller.service`  systemd 服务单元
- `install.sh`  一键部署脚本
- `README.md`  本文件

## 离线依赖说明
- **只需要 `python3`**（openEuler 24.03 默认自带 3.11，无需联网）。
- 若目标机没装 python3：从 openEuler 24.03 离线 ISO / 本地 yum 仓库装
  `yum install -y python3`，装好后再跑 install.sh。
- 本工具**不依赖 lftp / rclone**，也不需要任何第三方 Python 包。

## 部署步骤（在目标服务器，root 下）
```bash
# 1. 把 ftp_puller_offline.tar.gz 传到服务器后解压
tar -xzf ftp_puller_offline.tar.gz
cd ftp_puller_offline

# 2. 一键部署
bash install.sh

# 3. 填真实参数（IP / 账号 / 密码 / 目录）
vi /opt/ftp_puller/ftp_puller.conf

# 4. 干跑验证：只列会动哪些文件, 不下载不删, 确认盯的目录正确
FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py

# 5. 正式开跑（开机自启 + 崩溃自愈）
systemctl enable --now ftp_puller

# 6. 看日志
tail -f ~/ftp_puller_verify.log
```

## 常用操作
- 停止：`systemctl stop ftp_puller`
- 重启：`systemctl restart ftp_puller`
- 看状态：`systemctl status ftp_puller`
- 临时手动跑一次：`FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf python3 /opt/ftp_puller/ftp_puller_verify.py`

## 配置项（ftp_puller.conf）
| 项 | 说明 |
|----|------|
| `FTP_HOST` | 目标 FTP 服务器 IP/域名 |
| `FTP_USER` / `FTP_PASS` | FTP 账号密码（有读写权限） |
| `REMOTE_DIR` | 远端要抽的根目录 |
| `LOCAL_DIR` | 本机存放根目录 |
| `MIN_AGE` | 跳过 N 秒内修改的文件，避开正在写入的（默认 120） |

也可用环境变量覆盖，或用 `FTP_PULLER_CONF=/path/conf` 指定别的配置文件路径。

## 校验与稳定性
- 下载先存成 `.part` 临时文件，完整后再改名落盘 → 绝不会出现半截成品。
- 大小校验必做；有 `.md5` 随车文件或服务器支持 `XMD5`/`XCRC` 时追加哈希校验。
- 校验失败 → 保留远端、写日志等下轮重试，**绝不丢数据**。
- flock 运行锁防并发；断线自动重连重试 3 次；启动清理残留 `.part`；UTF-8 中文名。

## 测一下服务器是否支持 XMD5（可选，决定能否做内容级校验）
```bash
ftp -n 目标服务器IP <<'EOF'
user 你的FTP账号 你的FTP密码
quote XMD5 /remote/source/某个已有文件
quit
EOF
```
返回 `250 <32位十六进制>` → 支持 MD5，脚本会自动用；返回 `500/550 未知命令` → 不支持，
自动退回大小校验（仍然安全）。

## 卸载
```bash
systemctl disable --now ftp_puller
rm -f /etc/systemd/system/ftp_puller.service /opt/ftp_puller/ftp_puller_verify.py /opt/ftp_puller/ftp_puller.conf
systemctl daemon-reload
```
