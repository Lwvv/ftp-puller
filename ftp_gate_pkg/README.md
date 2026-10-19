# FTP 服务端离线包 (网闸对接端)

部署在**既当抽取端、又要被网闸抽取的机器**上（例：192.168.5.131）。它开 vsftpd，
并建一个 FTP 账户 `ftpadmin`：抽取端脚本（`LOCAL_DIR=/home/ftpadmin`）把从源端抽来的文件
落在这里，网闸再用 `ftpadmin` 把文件拉走（搬家式删除）。

> 与 `ftp_server_pkg`（被抽取端，建 `ftp` 账户）的区别：本包建的是 `ftpadmin`，
> 家目录指向抽取端的落盘目录 `/home/ftpadmin`，专门给网闸抽。

## 包含的组件
- `vsftpd.conf` —— 已修好的配置（关匿名 / chroot / 被动模式自动探测 / 白名单）
- `install.sh` —— 一键安装（建 `ftpadmin` 账户 + 装 vsftpd + 防火墙 + SELinux + 启动）
- `rpms/` —— vsftpd + logrotate 离线包
- `base_tools/` —— 离线基础工具 rpm（tar/netstat/lsof/ps/wget/ftp 客户端）

## 安装（重装系统后，装在抽取端那台机器上）
以 root 在解压目录执行：
```bash
bash install.sh
```
> 默认账户/密码见脚本顶部"可修改区"，重装前可按需改 `install.sh` 再执行。

## 与抽取端联动（重要）
若本机已装 `ftp_puller_pkg`（抽取端），本包安装时会自动给 `ftp_puller.service`
注入 `Environment=CHOWN_LOCAL=1` 并重启服务，使抽取端**落盘的文件属主变为 `ftpadmin`**，
网闸抽走后才能删除（搬家式不残留）。安装顺序建议：
```bash
# 1) 先装抽取端
unzip ftp_puller_pkg.zip && cd ftp_puller_pkg && bash install.sh && cd ..
# 2) 再装本网闸对接端(会自动联动上面)
unzip ftp_gate_pkg.zip && cd ftp_gate_pkg && bash install.sh && cd ..
```

## 验证
```bash
# 本机用 ftp 客户端实测登录 + 列目录(需 base_tools 已装)
ftp 127.0.0.1
# 输入账户 ftpadmin / 密码 -> 应能看到 /home/ftpadmin 内容
```

## 网闸侧对接要点
网闸配置（在网闸设备侧填）：
- 地址 = 本机 IP（`ftp://192.168.5.131`，端口 21）
- 账号 = `ftpadmin`，密码 = `CHANGE_ME_GATEWAY_PASSWORD`
- 目录 = `/home/ftpadmin`（登录后根即此目录）
- 建议"抽走后删除源文件"，配合上面的 CHOWN 即可正常删
