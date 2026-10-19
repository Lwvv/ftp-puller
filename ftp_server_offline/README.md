# FTP 服务端离线安装包 (openEuler 24.03 SP3 x86_64)

本包用于**没有外网的服务器**上离线安装 vsftpd，并新建一个可读写的 FTP 账户：

- 账户：`ftpadmin`
- 密码：`CHANGE_ME_GATEWAY_PASSWORD`
- 家目录：`/home/ftpadmin`（落在 `/home` 大分区上，约 398G 可用；这就是抽取脚本里要填的 `REMOTE_DIR`）

## 包内文件

| 文件 | 说明 |
|------|------|
| `rpms/vsftpd-3.0.5-2.oe2403sp3.x86_64.rpm` | FTP 服务端主程序 |
| `rpms/logrotate-3.21.0-1.oe2403sp3.x86_64.rpm` | 日志轮转（vsftpd 的硬依赖，已一并打包） |
| `vsftpd.conf` | 加固配置模板（关匿名、锁家目录、被动模式） |
| `install.sh` | 一键安装脚本（root 运行） |
| `README.md` | 本说明 |

> 依赖说明：vsftpd 的共享库（glibc / libcap / openssl-libs / pam）均为系统自带，无需额外包。已用工具确认离线安装不会缺依赖。

## 安装步骤

```bash
# 1. 把 ftp_server_offline.tar.gz 传到服务器后解压
tar -xzf ftp_server_offline.tar.gz
cd ftp_server_offline

# 2. 用 root 运行一键安装
sudo bash install.sh
```

脚本会自动完成：装 rpm → 建/重置 ftpadmin 账户 → 写配置（自动填本机 IP）→ 放行防火墙 → 开机自启并启动。

> **完全离线**：安装走的是 `rpm -Uvh` 直接装包内自带的本地 rpm，**不调用 dnf/yum**，因此不会去联网刷新软件源（离线机上 dnf 会卡在拉元数据处）。全程零网络访问。

## 验证

```bash
# 本地连一下(把 IP 换成输出里的)
ftp -n <本机IP> <<'EOF'
user ftpadmin CHANGE_ME_GATEWAY_PASSWORD
pwd
bye
EOF

# 或看服务状态
systemctl status vsftpd
```

## 客户端对接（抽取脚本侧）

在**拉取服务器**上的 `ftp_puller.conf` 里填：

```
FTP_HOST=<本机IP>
FTP_USER=ftpadmin
FTP_PASS=CHANGE_ME_GATEWAY_PASSWORD
REMOTE_DIR=/home/ftpadmin
LOCAL_DIR=/local/dest
```

## 安全提示

- FTP 是**明文**协议（账号密码和文件内容都不加密）。仅在内网/可信网络使用；若要走公网，请改用 FTPS/SFTP。
- 该账户被 `chroot` 锁在家目录，且不在 `ftpusers` 拒绝列表；如要再加限制，可改 `vsftpd.conf` 后 `systemctl restart vsftpd`。
- 建议定期改密码：`echo "ftpadmin:新密码" | chpasswd`。

## 卸载（如需）

```bash
systemctl disable --now vsftpd
rpm -e vsftpd logrotate
userdel -r ftpadmin   # 连同家目录 /home/ftpadmin 删除
```
