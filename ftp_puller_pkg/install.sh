#!/bin/bash
# ============================================================
# FTP Puller 离线部署脚本 (抽取端 / 拉取服务器, openEuler 24.03 SP3 x86_64)
# 在"拉取服务器"上以 root 执行:  bash install.sh
# 本机双角色:
#   ① 抽取端: 周期从源服务器 FTP 把文件拉到 LOCAL_DIR (搬家式删源)
#   ② 网闸对接端: 开 vsftpd + 建 ftpadmin 账户(家目录=LOCAL_DIR), 供网闸来抽
# 优先离线: 软件优先用包内 rpms/ 与 base_tools/ 的本地 rpm; 个别缺失时回退在线 dnf 安装
# ============================================================
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/ftp_puller

echo "[1/6] 检查 python3 ..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 找不到 python3!"
    echo "请从 openEuler 24.03 离线 ISO / 本地仓库安装:  yum install -y python3"
    exit 1
fi
python3 -c "import ftplib, hashlib, zlib, fcntl, getpass, tempfile" \
    || { echo "错误: Python 标准库缺失"; exit 1; }
echo "python3 OK: $(python3 --version 2>&1)"

echo "[2/6] 部署到 $DEST ..."
mkdir -p "$DEST"
mkdir -p "$DEST/logs"
chmod 700 "$DEST/logs"
# 优先部署编译后的二进制; 没有二进制则退回到源码脚本
# 注意: Windows 打的 zip 不会保留 Linux 执行位, 解压后可能是 644/666,
#       故用"文件存在(-f)"判断, 而非"可执行(-x)", 部署时再 chmod 755。
if [ -f "$SRC_DIR/ftp_puller" ]; then
  chmod 755 "$SRC_DIR/ftp_puller" 2>/dev/null || true
  cp "$SRC_DIR/ftp_puller" "$DEST/ftp_puller"
  chmod 755 "$DEST/ftp_puller"
  EXEC="$DEST/ftp_puller"
  echo "    已部署二进制: $DEST/ftp_puller"
elif [ -f "$SRC_DIR/ftp_puller_verify.py" ]; then
  cp "$SRC_DIR/ftp_puller_verify.py" "$DEST/ftp_puller_verify.py"
  chmod 755 "$DEST/ftp_puller_verify.py"
  EXEC="/usr/bin/python3 $DEST/ftp_puller_verify.py"
  echo "    已部署源码脚本: $DEST/ftp_puller_verify.py"
else
  echo "错误: 既找不到编译二进制 ftp_puller, 也找不到源码 ftp_puller_verify.py!" >&2
  exit 1
fi

# 若部署包内附带授权文件 license.dat, 则一并放到 /opt/ftp_puller/ (安装即生效)
if [ -f "$SRC_DIR/license.dat" ]; then
  cp "$SRC_DIR/license.dat" "$DEST/license.dat"
  chmod 644 "$DEST/license.dat"
  echo "    已部署授权文件: $DEST/license.dat"
else
  echo "    [提示] 部署包未附带 license.dat, 程序启动将提示缺少授权(需另行提供并放到 $DEST/license.dat)"
fi

# 部署卸载脚本(供日后清理)
if [ -f "$SRC_DIR/uninstall.sh" ]; then
  cp "$SRC_DIR/uninstall.sh" "$DEST/uninstall.sh"
  chmod 755 "$DEST/uninstall.sh"
  echo "    已部署卸载脚本: $DEST/uninstall.sh"
fi

echo "[3/6] 配置文件 ..."
if [ ! -f "$DEST/ftp_puller.conf" ]; then
    cp "$SRC_DIR/ftp_puller.conf.example" "$DEST/ftp_puller.conf"
    chmod 600 "$DEST/ftp_puller.conf"
    echo "已生成 $DEST/ftp_puller.conf  (权限 600, 请按实际情况修改)"
else
    echo "配置文件已存在, 不覆盖"
fi

# 源端删除策略: 默认取自 ftp_puller.conf.example(DELETE_SOURCE=1, 搬家式)。
# 安装阶段不互动; 你填好 conf 后, 由 test.sh 交互确认是否启用。
echo "[4/6] systemd 服务 ..."
# 直接生成服务文件, 自动适配二进制或源码两种执行方式
cat > /etc/systemd/system/ftp_puller.service <<EOF
[Unit]
Description=FTP Puller 定时抽取服务 (从远端 FTP 拉取文件并校验)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$EXEC
Environment=FTP_PULLER_CONF=$DEST/ftp_puller.conf
Restart=always
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/ftp_puller.service
systemctl daemon-reload
echo "已安装服务 ftp_puller (ExecStart=$EXEC, 启动由 test.sh 交互确认后拉起)"

echo "[5/6] 补基础工具(tar/netstat/lsof/ftp 等) ..."
if [ -f "$SRC_DIR/base_tools/install.sh" ]; then
    bash "$SRC_DIR/base_tools/install.sh" || echo "[提示] 基础工具安装未完成, 可稍后手动跑 base_tools/install.sh"
else
    echo "[跳过] 未找到 base_tools/install.sh"
fi

# ===================== 第 6 步: 网闸对接(本机同时被网闸抽取) =====================
# 本机双角色: 既抽源端, 又开 FTP 供网闸抽。下面新建 ftpadmin 账户(家目录=LOCAL_DIR)
# 并启动 vsftpd, 让网闸来抽走落盘文件。落盘文件属主会被改回 ftpadmin, 网闸抽走后可删除。
set +e   # 本段容错: 即便某步失败也不中断整体部署
echo ""
echo "[6/6] 网闸对接: 新建 ftpadmin 账户 + 启动 vsftpd (供网闸抽取落盘目录)"

GATE_FTP_USER="ftpadmin"
# 网闸账户密码: 固定口令(由交付方指定, 非随机), 写盘到 $DEST/.gate_pass 供运维查阅/重装沿用。
GATE_FTP_PASS="CHANGE_ME_GATEWAY_PASSWORD"
GATE_PASS_FILE="$DEST/.gate_pass"
echo "$GATE_FTP_PASS" > "$GATE_PASS_FILE"
chmod 600 "$GATE_PASS_FILE" 2>/dev/null || true
# 网闸账户家目录与抽取端 LOCAL_DIR 保持一致
GATE_FTP_HOME="$(grep '^LOCAL_DIR=' "$DEST/ftp_puller.conf" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
[ -z "$GATE_FTP_HOME" ] && GATE_FTP_HOME="/home/ftpadmin"
PASV_MIN=30000
PASV_MAX=31000
# 读取网卡 IP(排除回环/链路本地/Docker 私有网段, 取第一个真实网卡地址; 取不到再退回 hostname -I 首地址)
SRV_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^127\.|^169\.254\.|^172\.(1[6-9]|2[0-9]|3[01])\.' | head -1)
[ -z "$SRV_IP" ] && SRV_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# 装 vsftpd / logrotate (纯本地 rpm, 不联网)
rpm -Uvh --replacepkgs ./rpms/logrotate-*.rpm >/dev/null 2>&1 \
    && echo "    logrotate 已安装" \
    || echo "    [提示] logrotate 未能安装, 跳过(不影响 vsftpd 运行)"
if ! rpm -Uvh --replacepkgs ./rpms/vsftpd-*.rpm; then
    echo "    [警告] 常规安装失败, 改用 --nodeps 重试..."
    rpm -Uvh --nodeps --replacepkgs ./rpms/vsftpd-*.rpm || echo "    [警告] vsftpd 安装失败, 请手动处理"
fi
command -v vsftpd >/dev/null 2>&1 && echo "    vsftpd 版本: $(vsftpd -version 2>&1 | head -1)"

# lrzsz: 提供 rz/sz Zmodem 终端传文件工具(维护用)
rpm -Uvh --replacepkgs ./rpms/lrzsz-*.rpm >/dev/null 2>&1 \
  && echo "    lrzsz 已安装(离线)" \
  || { dnf install -y lrzsz >/dev/null 2>&1 && echo "    lrzsz 已安装(在线)" || echo "    [提示] lrzsz 安装失败, 可手动: dnf install -y lrzsz"; }

# 建网闸账户
create_gate_user() {
    local U="$1" P="$2" H="$3"
    echo "  -> 处理账户 $U (家目录 $H)"
    id "$U" >/dev/null 2>&1 && userdel -r "$U" 2>/dev/null || true
    getent group "$U" >/dev/null 2>&1 && groupdel "$U" 2>/dev/null || true
    if ! useradd -m -d "$H" -s /sbin/nologin "$U" 2>/dev/null; then
        groupadd "$U" 2>/dev/null || true
        useradd -m -d "$H" -g "$U" -s /sbin/nologin "$U" 2>/dev/null \
            || { echo "    [警告] 用户 $U 创建失败, 请手动处理"; return 1; }
    fi
    if ! echo "$U:$P" | chpasswd 2>/dev/null; then
        HASH=$(python3 -c "import crypt,os;print(crypt.crypt('$P',crypt.mksalt(crypt.METHOD_SHA512)))")
        usermod -p "$HASH" "$U" 2>/dev/null || true
    fi
    USHELL=$(getent passwd "$U" | cut -d: -f7)
    grep -qxF "$USHELL" /etc/shells 2>/dev/null || echo "$USHELL" >> /etc/shells
    mkdir -p "$H"; chown -R "$U":"$U" "$H"; chmod 750 "$H"
    mkdir -p /etc/vsftpd; touch /etc/vsftpd/user_list
    grep -qxF "$U" /etc/vsftpd/user_list 2>/dev/null || echo "$U" >> /etc/vsftpd/user_list
    sed -i "/^$U\$/d" /etc/vsftpd/ftpusers 2>/dev/null || true
    id "$U" >/dev/null 2>&1 && echo "    账户 $U 已就绪" || echo "    [警告] 账户 $U 校验不存在"
}
create_gate_user "$GATE_FTP_USER" "$GATE_FTP_PASS" "$GATE_FTP_HOME"

# 写 vsftpd 配置(与源端同一个干净配置: 关匿名/chroot/被动自动探测/白名单)
if [ -f "$SRC_DIR/vsftpd.conf" ]; then
    cp -f "$SRC_DIR/vsftpd.conf" /etc/vsftpd/vsftpd.conf.bak 2>/dev/null || true
    cp -f "$SRC_DIR/vsftpd.conf" /etc/vsftpd/vsftpd.conf
fi

# 防火墙放行
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=ftp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PASV_MIN-$PASV_MAX/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo "    firewalld 已放行"
else
    echo "    firewalld 未运行, 跳过(若用 iptables 请自行放行端口 21 与 $PASV_MIN-$PASV_MAX)"
fi

# SELinux 放通
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    setsebool -P ftpd_full_access on 2>/dev/null || true
    echo "    SELinux 已放通 ftpd_full_access"
fi

systemctl enable --now vsftpd >/dev/null 2>&1
sleep 1
systemctl is-active --quiet vsftpd && echo "    vsftpd 已启动 (active)" || echo "    [警告] vsftpd 未运行, 请检查"

# 联动: 让抽取端落盘文件归属 ftpadmin(网闸可删除, 搬家式不残留)
if [ -f /etc/systemd/system/ftp_puller.service ]; then
    if grep -q 'CHOWN_LOCAL' /etc/systemd/system/ftp_puller.service; then
        echo "    [联动] ftp_puller.service 已含 CHOWN_LOCAL"
    else
        sed -i '/^\[Service\]/a Environment=CHOWN_LOCAL=1' /etc/systemd/system/ftp_puller.service
        systemctl daemon-reload
    fi
fi
echo "    网闸对接信息(供配置网闸使用, 明文显示):"
echo "      地址 : ftp://$SRV_IP:21"
echo "      账户 : $GATE_FTP_USER"
echo "      密码 : $GATE_FTP_PASS"
echo "      目录 : $GATE_FTP_HOME"
set -e
# ===================== 网闸对接段结束 =====================

# ===================== 部署测试/启动脚本 =====================
# 安装只负责"部署", 不自动测试、也不自动启动服务。
# 你填好 /opt/ftp_puller/ftp_puller.conf 后, 再运行 test.sh 做只读预检 + 交互确认启动。
# 记录解压目录, 供 test.sh 在确认启动成功后清理交付包与解压目录(防源文件残留)。
if [ -f "$SRC_DIR/test.sh" ]; then
  cp "$SRC_DIR/test.sh" "$DEST/test.sh"
  chmod 755 "$DEST/test.sh"
  echo "    已部署测试脚本: $DEST/test.sh"
fi
echo "$SRC_DIR" > "$DEST/.install_src" 2>/dev/null || true

echo ""
echo "================ 部署完成 ================"
echo "【抽取端】 安装已完成, 服务已注册但未启动。"
echo "  下一步(按顺序):"
echo "    1) 填配置:  vi $DEST/ftp_puller.conf"
echo "       (REMOTE_DIR 注意: 源端若开了 chroot, 登录后根 / 即家目录, 填 / 即可)"
echo "    2) 跑测试 + 交互启动:  bash $DEST/test.sh"
echo "       - 只读预检: 配置完整性 + 本地目录可写 + 源端 FTP 可登录并进入 REMOTE_DIR"
echo "       - 交互确认源端删除策略(搬家式)"
echo "       - 交互确认后启动服务并开启开机自启; 启动成功自动清理交付包与解压目录"
echo "  日志(进度条/抽取明细/授权剩余天数):"
echo "       tail -f $DEST/logs/ftp_puller_verify.log"
echo "  停服:    systemctl stop ftp_puller"
echo "  起服:    systemctl start ftp_puller"
echo ""
echo "【网闸对接】 已建 ftpadmin 账户并启动 vsftpd, 网闸可直接来抽 LOCAL_DIR:"
echo "      地址 = ftp://$SRV_IP:21   账户 = $GATE_FTP_USER   密码 = $GATE_FTP_PASS   目录 = $GATE_FTP_HOME"
echo "========================================="

# ===================== 交付包清理 =====================
# 不在安装阶段清理: 安装仅部署, 服务未启动。清理(删除交付 zip + 解压目录)由 test.sh
# 在你确认启动成功后执行, 避免配置未就绪就把交付包删掉导致无法重跑 install.sh。
