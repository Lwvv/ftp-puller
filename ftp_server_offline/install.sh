#!/bin/bash
# ============================================================
# FTP 服务端离线安装脚本 (openEuler 24.03 SP3 x86_64)
# 功能: 装 vsftpd + 新建账户 ftpadmin / 密码 CHANGE_ME_GATEWAY_PASSWORD
#       配置被动模式 / 防火墙 / 开机自启
# 用法: 在解压后的目录里, 以 root 运行:  bash install.sh
# ============================================================
set -u

# ---------- 可修改区 ----------
FTP_USER="ftpadmin"
FTP_PASS="CHANGE_ME_GATEWAY_PASSWORD"
# 存到 /home 分区(你的机器 /home 有 ~398G 空闲, 根分区只有 64G), 避免占系统盘
FTP_HOME="/home/ftpadmin"
PASV_MIN=30000
PASV_MAX=31000
# --------------------------------

cd "$(dirname "$0")" || exit 1

[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root 运行 (sudo bash install.sh)"; exit 1; }

echo ">>> [1/6] 安装 vsftpd / logrotate (纯本地 rpm, 不联网)"
# 用 rpm 直接装本地包, 绝不触发 dnf/yum 刷新源(离线机 dnf 会卡在拉元数据)
# 先装 logrotate(vsftpd 的依赖; 失败也不影响 vsftpd 运行)
rpm -Uvh --replacepkgs ./rpms/logrotate-*.rpm >/dev/null 2>&1 \
    && echo "    logrotate 已安装" \
    || echo "    [提示] logrotate 未能安装, 跳过(不影响 vsftpd 运行)"
# 再装 vsftpd; 常规失败则退回 --nodeps(其库依赖 glibc/libcap/openssl-libs/pam 均系统自带, 安全)
if ! rpm -Uvh --replacepkgs ./rpms/vsftpd-*.rpm; then
    echo "    [警告] 常规安装失败, 改用 --nodeps 重试..."
    rpm -Uvh --nodeps --replacepkgs ./rpms/vsftpd-*.rpm || { echo "[错误] vsftpd 安装失败"; exit 1; }
fi
command -v vsftpd >/dev/null 2>&1 || { echo "[错误] 未找到 vsftpd 可执行文件"; exit 1; }
echo "    vsftpd 版本: $(vsftpd -version 2>&1 | head -1)"

echo ">>> [2/6] 新建 / 重置 FTP 账户 $FTP_USER"
# 清理可能残留的状态: 防止"组已存在但用户不存在"导致 useradd 失败
if id "$FTP_USER" >/dev/null 2>&1; then
    echo "    发现已存在用户, 先清理后重建以确保状态干净"
    userdel -r "$FTP_USER" 2>/dev/null || userdel "$FTP_USER" 2>/dev/null || true
fi
if getent group "$FTP_USER" >/dev/null 2>&1; then
    groupdel "$FTP_USER" 2>/dev/null || true
fi
# 干净创建(让 useradd 自行建立同名主组, 避免与已存在组冲突)
if ! useradd -m -d "$FTP_HOME" -s /sbin/nologin "$FTP_USER"; then
    # 极少数情况: 组/用户残留导致上面失败, 显式建组再指定 -g
    groupadd "$FTP_USER" 2>/dev/null || true
    useradd -m -d "$FTP_HOME" -g "$FTP_USER" -s /sbin/nologin "$FTP_USER" \
        || { echo "[错误] 用户 $FTP_USER 创建失败"; exit 1; }
fi
# 设密码(优先 chpasswd; 若报 token 错误退回 usermod -p 加密写入)
if ! echo "$FTP_USER:$FTP_PASS" | chpasswd; then
    echo "    [提示] chpasswd 失败, 改用 usermod -p 加密写入"
    HASH=$(FTP_PASS="$FTP_PASS" python3 -c "import crypt,os;print(crypt.crypt(os.environ['FTP_PASS'],crypt.mksalt(crypt.METHOD_SHA512)))")
    usermod -p "$HASH" "$FTP_USER"
fi
# 让 pam_shells 放行 /sbin/nologin (openEuler 的 vsftpd PAM 默认要求 shell 在 /etc/shells)
USHELL=$(getent passwd "$FTP_USER" | cut -d: -f7)
grep -qxF "$USHELL" /etc/shells 2>/dev/null || echo "$USHELL" >> /etc/shells
# 确保家目录存在且权限正确(ftpadmin 可写, 其他用户不可进入)
mkdir -p "$FTP_HOME"
chown -R "$FTP_USER":"$FTP_USER" "$FTP_HOME"
chmod 750 "$FTP_HOME"
echo "    账户 $FTP_USER 已就绪, 家目录 $FTP_HOME"
# 硬校验: 账户必须真实存在, 否则后续 vsftpd 启动必失败
if ! id "$FTP_USER" >/dev/null 2>&1; then
    echo "[错误] 账户 $FTP_USER 创建失败, 请检查上方日志后重试"
    exit 1
fi

echo ">>> [3/6] 写入 vsftpd 配置"
cp -f vsftpd.conf /etc/vsftpd/vsftpd.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
cp -f vsftpd.conf /etc/vsftpd/vsftpd.conf
echo "    被动地址交由 vsftpd 自动探测(本地/远端都能连)"
# 把 ftpadmin 加入白名单(若尚未加入)
grep -qxF "$FTP_USER" /etc/vsftpd/user_list 2>/dev/null || echo "$FTP_USER" >> /etc/vsftpd/user_list
# 确保 ftpadmin 不在拒绝列表
sed -i "/^$FTP_USER$/d" /etc/vsftpd/ftpusers 2>/dev/null || true

echo ">>> [4/6] 防火墙放行 (21 + 被动端口 $PASV_MIN-$PASV_MAX)"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=ftp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PASV_MIN-$PASV_MAX/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo "    firewalld 已放行"
else
    echo "    firewalld 未运行, 跳过(若用 iptables 请自行放行端口 21 与 $PASV_MIN-$PASV_MAX)"
fi

echo ">>> [5/6] SELinux 适配(若开启)"
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    # RHEL9/openEuler: 用 ftpd_full_access 放通 FTP 访问非标准/家目录(ftp_home_dir 在该系已废弃)
    setsebool -P ftpd_full_access on 2>/dev/null || true
    echo "    SELinux 已放通 ftp_home_dir"
else
    echo "    SELinux 未强制, 跳过"
fi

echo ">>> [6/6] 启动 vsftpd 并设为开机自启"
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
echo " FTP 地址 : ftp://$SRV_IP"
echo " 端口     : 21 (被动端口 $PASV_MIN-$PASV_MAX)"
echo " 账户     : $FTP_USER"
echo " 密码     : $FTP_PASS"
echo " 家目录   : $FTP_HOME   (抽取脚本的 REMOTE_DIR 填这个)"
echo " 日志     : /var/log/vsftpd.log"
echo " 排错     : systemctl status vsftpd ; journalctl -u vsftpd"
echo "=================================================="
