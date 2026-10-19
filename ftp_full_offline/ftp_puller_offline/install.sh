#!/bin/bash
# ============================================================
# FTP Puller 离线部署脚本
# 在目标 openEuler 服务器上, 以 root 执行:  bash install.sh
# 作用: 检查 python3 -> 部署脚本 -> 生成配置 -> 安装 systemd 服务
# ============================================================
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/ftp_puller

echo "[1/4] 检查 python3 ..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 找不到 python3!"
    echo "请从 openEuler 24.03 离线 ISO / 本地仓库安装:  yum install -y python3"
    exit 1
fi
# 校验脚本依赖的标准库是否齐全
python3 -c "import ftplib, hashlib, zlib, fcntl, getpass, tempfile" \
    || { echo "错误: Python 标准库缺失"; exit 1; }
echo "python3 OK: $(python3 --version 2>&1)"

echo "[2/4] 部署到 $DEST ..."
mkdir -p "$DEST"
cp "$SRC_DIR/ftp_puller_verify.py" "$DEST/ftp_puller_verify.py"
chmod 755 "$DEST/ftp_puller_verify.py"

echo "[3/4] 配置文件 ..."
if [ ! -f "$DEST/ftp_puller.conf" ]; then
    cp "$SRC_DIR/ftp_puller.conf.example" "$DEST/ftp_puller.conf"
    chmod 600 "$DEST/ftp_puller.conf"
    echo "已生成 $DEST/ftp_puller.conf  (权限 600)"
else
    echo "配置文件已存在, 不覆盖"
fi

echo "[4/4] systemd 服务 ..."
cp "$SRC_DIR/ftp_puller.service" /etc/systemd/system/ftp_puller.service
chmod 644 /etc/systemd/system/ftp_puller.service
systemctl daemon-reload
echo "已安装服务 ftp_puller (未自动启动, 待你填好配置后手动开)"

echo ""
echo "================ 部署完成 ================"
echo "下一步:"
echo "  1) 填配置:  vi $DEST/ftp_puller.conf"
echo "  2) 干跑验证(只看不拉, 确认目录正确):"
echo "       FTP_PULLER_CONF=$DEST/ftp_puller.conf DRYRUN=1 python3 $DEST/ftp_puller_verify.py"
echo "  3) 正式开跑(开机自启 + 崩溃自愈):"
echo "       systemctl enable --now ftp_puller"
echo "  4) 看日志:  tail -f ~/ftp_puller_verify.log"
echo "  5) 停服:    systemctl stop ftp_puller"
echo "========================================="
