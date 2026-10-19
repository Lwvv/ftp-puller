# FTP 服务端离线包 (被抽取端)

部署在**源服务器**上（例：192.168.5.132）。它开 vsftpd，并建一个 FTP 源账户 `ftp`：
把要被抽走的业务文件放进它的家目录 `/home/ftp`，抽取端脚本（REMOTE_DIR=/）会把这些
文件拉走并删源。

## 包含的组件
- `vsftpd.conf` —— 已修好的配置（关匿名 / chroot / 被动模式自动探测 / 白名单）
- `install.sh` —— 一键安装（建 `ftp` 账户 + 装 vsftpd + 防火墙 + SELinux + 启动）
- `rpms/` —— vsftpd + logrotate 离线包
- `base_tools/` —— 离线基础工具 rpm（tar/netstat/lsof/ps/wget/ftp 客户端）

## 安装（重装系统后）
以 root 在解压目录执行：
```bash
bash install.sh
```
> 默认账户/密码见脚本顶部"可修改区"，重装前可按需改 `install.sh` 再执行。

## 验证
```bash
# 本机用 ftp 客户端实测登录 + 列目录(需 base_tools 已装)
ftp 127.0.0.1
# 输入账户 ftp / 密码 -> 应能看到家目录内容
```

## 抽取端对接要点
抽取端 `ftp_puller.conf` 里：
- `FTP_HOST` = 本机 IP
- `FTP_USER` = `ftp`，`FTP_PASS` = 对应密码
- **`REMOTE_DIR=/`**（因为 chroot 锁在家目录，登录后 `/` 即 `/home/ftp`；不要填 `/home/ftp`）

## 关于网闸对接
本包只建源账户 `ftp`（供抽取端来抽）。若某台机器还需被网闸来抽，需要另行建立
`ftpadmin` 之类账户——告诉我，我再单独给一步建账户命令或脚本，避免和本包冲突。
