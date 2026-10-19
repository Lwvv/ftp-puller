#!/bin/bash
# ============================================================
# FTP 服务端离线安装脚本 (被抽取端, openEuler 24.03 SP3 x86_64)
# 功能: 装 vsftpd + 新建 FTP 源账户(ftp) + 被动模式 + 防火墙 + SELinux + 开机自启
#   账户 (SRC_FTP_USER): 给"抽取端"来抽的源账户。把要抽走的文件放它家目录。
# 用法: 在解压后的目录里, 以 root 运行:  bash install.sh
# 纯离线: 只用包内 rpms/, 绝不调用 dnf/yum(离线机 dnf 会卡在拉元数据)
# ============================================================
set -u

# ---------- 可修改区(按需改密码/目录) ----------
# 源账户: 供"抽取端"来抽(把要抽走的文件放它家目录)。默认 ftp / CHANGE_ME_SOURCE_PASSWORD / /home/ftp
SRC_FTP_USER="ftp"
SRC_FTP_PASS="CHANGE_ME_SOURCE_PASSWORD"
SRC_FTP_HOME="/home/ftp"

PASV_MIN=30000
PASV_MAX=31000
# ------------------------------------------------

cd "$(dirname "$0")" || exit 1
[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root 运行 (sudo bash install.sh)"; exit 1; }

SRV_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

create_ftp_user() {
    local U="$1" P="$2" H="$3"
    echo "  -> 处理账户 $U (家目录 $H)"
    # 清理可能残留的状态, 防止"组已存在但用户不存在"导致 useradd 失败
    if id "$U" >/dev/null 2>&1; then
        userdel -r "$U" 2>/dev/null || userdel "$U" 2>/dev/null || true
    fi
    if getent group "$U" >/dev/null 2>&1; then
        groupdel "$U" 2>/dev/null || true
    fi
    # 干净创建(让 useradd 自行建立同名主组)
    if ! useradd -m -d "$H" -s /sbin/nologin "$U"; then
        groupadd "$U" 2>/dev/null || true
        useradd -m -d "$H" -g "$U" -s /sbin/nologin "$U" \
            || { echo "[错误] 用户 $U 创建失败"; exit 1; }
    fi
    # 设密码(优先 chpasswd; 若报 token 错误退回 usermod -p 加密写入)
    if ! echo "$U:$P" | chpasswd; then
        echo "    [提示] chpasswd 失败, 改用 usermod -p 加密写入"
        HASH=$(FTP_PASS="$P" python3 -c "import crypt,os;print(crypt.crypt(os.environ['FTP_PASS'],crypt.mksalt(crypt.METHOD_SHA512)))")
        usermod -p "$HASH" "$U"
    fi
    # 让 pam_shells 放行 /sbin/nologin (openEuler 的 vsftpd PAM 默认要求 shell 在 /etc/shells)
    USHELL=$(getent passwd "$U" | cut -d: -f7)
    grep -qxF "$USHELL" /etc/shells 2>/dev/null || echo "$USHELL" >> /etc/shells
    # 确保家目录存在且权限正确(账户可写, 其他用户不可进入)
    mkdir -p "$H"
    chown -R "$U":"$U" "$H"
    chmod 750 "$H"
    # 加入登录白名单 / 移出拒绝列表
    grep -qxF "$U" /etc/vsftpd/user_list 2>/dev/null || echo "$U" >> /etc/vsftpd/user_list
    sed -i "/^$U\$/d" /etc/vsftpd/ftpusers 2>/dev/null || true
    # 硬校验: 账户必须真实存在
    if ! id "$U" >/dev/null 2>&1; then
        echo "[错误] 账户 $U 创建失败, 请检查上方日志后重试"
        exit 1
    fi
    echo "    账户 $U 已就绪"
}

echo ">>> [1/5] 安装 vsftpd / logrotate (纯本地 rpm, 不联网)"
rpm -Uvh --replacepkgs ./rpms/logrotate-*.rpm >/dev/null 2>&1 \
    && echo "    logrotate 已安装" \
    || echo "    [提示] logrotate 未能安装, 跳过(不影响 vsftpd 运行)"
if ! rpm -Uvh --replacepkgs ./rpms/vsftpd-*.rpm; then
    echo "    [警告] 常规安装失败, 改用 --nodeps 重试..."
    rpm -Uvh --nodeps --replacepkgs ./rpms/vsftpd-*.rpm || { echo "[错误] vsftpd 安装失败"; exit 1; }
fi
command -v vsftpd >/dev/null 2>&1 || { echo "[错误] 未找到 vsftpd 可执行文件"; exit 1; }
echo "    vsftpd 版本: $(vsftpd -version 2>&1 | head -1)"

echo ">>> [2/5] 新建 FTP 源账户 $SRC_FTP_USER"
create_ftp_user "$SRC_FTP_USER"  "$SRC_FTP_PASS"  "$SRC_FTP_HOME"

echo ">>> [3/5] 写入 vsftpd 配置"
cp -f vsftpd.conf /etc/vsftpd/vsftpd.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
cp -f vsftpd.conf /etc/vsftpd/vsftpd.conf
echo "    被动地址交由 vsftpd 自动探测(本地/远端都能连)"

echo ">>> [4/5] 防火墙放行 (21 + 被动端口 $PASV_MIN-$PASV_MAX)"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=ftp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PASV_MIN-$PASV_MAX/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo "    firewalld 已放行"
else
    echo "    firewalld 未运行, 跳过(若用 iptables 请自行放行端口 21 与 $PASV_MIN-$PASV_MAX)"
fi

echo ">>> [5/5] SELinux 适配 + 补基础工具 + 启动 vsftpd"
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    # RHEL9/openEuler 用 ftpd_full_access 放通 FTP 访问家目录(ftp_home_dir 在该系已废弃)
    setsebool -P ftpd_full_access on 2>/dev/null || true
    echo "    SELinux 已放通 ftpd_full_access"
else
    echo "    SELinux 未强制, 跳过"
fi
if [ -f "$PWD/base_tools/install.sh" ]; then
    bash "$PWD/base_tools/install.sh" || echo "[提示] 基础工具安装未完成, 可稍后手动跑 base_tools/install.sh"
fi
systemctl enable --now vsftpd >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet vsftpd; then
    echo "    vsftpd 已启动 (active)"
else
    echo "    [警告] vsftpd 未运行, 自动打印诊断信息:"
    journalctl -u vsftpd -n 30 --no-pager 2>/dev/null || true
fi

echo
echo "==================== 安装完成 ===================="
echo " 源服务器地址 : ftp://$SRV_IP  (端口 21, 被动端口 $PASV_MIN-$PASV_MAX)"
echo ""
echo " [源账户] 供抽取端来抽(把待抽文件放这里):"
echo "     账户 = $SRC_FTP_USER    密码 = $SRC_FTP_PASS"
echo "     家目录 = $SRC_FTP_HOME   (抽取端 REMOTE_DIR 填 / 即可, 因 chroot)"
echo ""
echo " 日志 : /var/log/vsftpd.log"
echo " 排错 : systemctl status vsftpd ; journalctl -u vsftpd"
echo "=================================================="
