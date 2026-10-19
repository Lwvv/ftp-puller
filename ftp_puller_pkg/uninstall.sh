#!/bin/bash
# ============================================================
# FTP Puller 卸载脚本
# 在部署机上以 root 执行:  bash /opt/ftp_puller/uninstall.sh
# 清理范围(仅移除 ftp_puller 自身引入的部分):
#   1. 停止 / 禁用 ftp_puller systemd 服务, 并删除服务文件
#   2. 删除网闸对接账户 ftpadmin(含家目录 /home/ftpadmin)
#   3. 删除部署目录 /opt/ftp_puller(含二进制 / 配置 / 日志 / 本脚本)
# 说明: vsftpd 软件包与防火墙放行规则属于系统级, 本脚本不卸载,
#       以免误伤其他依赖 vsftpd 的服务; 如确需清理可手动执行。
# ============================================================
set -e

DEST=/opt/ftp_puller
SVC=ftp_puller
GATE_USER=ftpadmin

echo "[1/3] 停止并移除 systemd 服务 $SVC ..."
systemctl stop "$SVC" 2>/dev/null || true
systemctl disable "$SVC" 2>/dev/null || true
rm -f "/etc/systemd/system/${SVC}.service"
systemctl daemon-reload 2>/dev/null || true
echo "    服务已移除"

echo "[2/3] 删除网闸对接账户 $GATE_USER (含家目录) ..."
if id "$GATE_USER" >/dev/null 2>&1; then
  userdel -r "$GATE_USER" 2>/dev/null || true
fi
getent group "$GATE_USER" >/dev/null 2>&1 && groupdel "$GATE_USER" 2>/dev/null || true
echo "    账户已删除"

echo "[3/3] 删除部署目录 $DEST ..."
rm -rf "$DEST"
echo "    已删除 $DEST"

echo "========================================="
echo "FTP Puller 卸载完成。"
echo "注: vsftpd 软件包与防火墙放行规则未卸载(系统级), 如需清理请手动处理。"
echo "========================================="
