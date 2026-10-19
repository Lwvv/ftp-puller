# 基础工具离线安装包 (openEuler 24.03 SP3 x86_64)

给**最小安装**的 openEuler 补常用命令，无需联网。

## 包含的包

| rpm | 提供的命令 |
|-----|-----------|
| tar-1.35 | `tar`（解压各种离线包用，必备） |
| net-tools-2.10 | `netstat` / `ifconfig`（查端口、网卡） |
| lsof-4.99.3 | `lsof`（查进程打开了哪些文件/端口） |
| procps-ng-4.0.4 | `ps` / `top` / `free` / `watch`（进程/内存监控） |
| wget-1.21.4 | `wget`（日后有网时拉文件用） |
| ftp-0.17 | `ftp`（命令行 FTP 客户端，手动测试 / 排障 FTP 服务端用，可用 `quote XMD5` 测内容校验） |

> 依赖说明：这些包只有 `systemd` 和基础库依赖（ftp 包更是零额外包级依赖），系统已自带，**不需要再额外打别的包**。已逐一用工具核对，离线 `rpm` 安装不会缺依赖。

## 安装

```bash
tar -xzf base_tools_offline.tar.gz     # 如果连 tar 都没有, 见下方"应急"
cd base_tools_offline
sudo bash install.sh
```

脚本用 `rpm -Uvh --replacepkgs` 直接装本地包，**不调用 dnf/yum**，因此不会去联网刷新软件源（离线机 dnf 会卡死）。装完会逐个验证命令是否就位。

## 应急：连 tar 都没有怎么办

如果系统连 `tar` 都没装，先手动解包（用 `cpio` /`gzip`，openEuler 最小安装通常带 `gzip` 和 `cpio`）：

```bash
cd /tmp
gzip -dc base_tools_offline.tar.gz | cpio -idmv
cd base_tools_offline
sudo rpm -Uvh --replacepkgs ./rpms/*.rpm
```

装完 tar 后，后续的包（ftp 服务端、抽取端）就能正常 `tar -xzf` 了。

## 如何测试 FTP 服务端

装好本包后，即可用 `ftp` 命令手动验证 FTP 服务端（ftpadmin 账户能否登录、能否传文件、被动模式与 XMD5 是否支持）：

```bash
# 1) 交互式登录 (连本机填 127.0.0.1, 连别的机器填其 IP)
ftp 服务器IP
# 出现 Name: 输 ftpadmin, Password: 输 CHANGE_ME_GATEWAY_PASSWORD
# 登录成功后可用 ls / put / get / bye 等基本命令

# 2) 非交互式: 登录 + 列目录 + 测 XMD5 (测内容级校验是否可用)
ftp -n 服务器IP <<'EOF'
user ftpadmin CHANGE_ME_GATEWAY_PASSWORD
ls
quote XMD5 /home/ftpadmin/某个已有文件
bye
EOF
```

说明：
- 返回 `250 xxxxxxxx...(32位十六进制)` → 服务端支持 **MD5**，抽取脚本会自动启用内容校验；
- 返回 `500 / 550 Unknown command` → 不支持，脚本自动退回大小校验，照样安全；
- 若连接长时间无响应，多半是防火墙/被动端口没放行，用 `netstat -antup | grep :21` 和 `netstat -antup | grep 30` 检查 21 与 30000–31000 端口是否通。

## 卸载（如需）

```bash
rpm -e wget lsof net-tools procps-ng tar ftp   # 注意: tar 是很多脚本依赖的基础命令, 谨慎卸载
```
