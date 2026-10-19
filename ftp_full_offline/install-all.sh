#!/bin/bash
# ============================================================
# 总离线安装 (openEuler 24.03 SP3 x86_64)
# 一键装齐: 基础工具 + FTP 服务端(vsftpd+ftpadmin) + 抽取端
# 用法: 以 root 运行   bash install-all.sh
# 说明: 本脚本统一用 bash 显式调用子脚本, 不依赖 .sh 的可执行位
#       (zip 压缩不保证保留 Unix 权限, 故全部以 bash 执行, 无需 chmod +x)
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1
[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root 运行: sudo bash install-all.sh"; exit 1; }

echo "============================================================"
echo " 总离线安装: 基础工具 + FTP 服务端 + 抽取端"
echo " 目标系统: openEuler 24.03 SP3 x86_64 (离线, 零联网)"
echo "============================================================"

rc=0

echo; echo ">>> [1/3] 基础工具 (tar / netstat / lsof / ps / wget / ftp)"
bash base_tools_offline/install.sh || { echo "[!] 基础工具安装失败, 见上方日志"; rc=1; }

echo; echo ">>> [2/3] FTP 服务端 (vsftpd + 账户 ftpadmin)"
bash ftp_server_offline/install.sh || { echo "[!] FTP 服务端安装失败, 见上方日志"; rc=1; }

echo; echo ">>> [3/3] 抽取端 (Python 拉取脚本 + systemd)"
bash ftp_puller_offline/install.sh || { echo "[!] 抽取端安装失败, 见上方日志"; rc=1; }

echo
echo "============================================================"
if [ "$rc" -eq 0 ]; then
    echo " 全部组件安装完成 ✓"
else
    echo " 部分组件安装失败 (rc=$rc), 请查看上方各步日志后重试"
fi
echo "------------------------------------------------------------"
echo " 后续步骤:"
echo "  1) 填抽取端配置:  vi /opt/ftp_puller/ftp_puller.conf"
echo "     (FTP_HOST 填目标机IP, REMOTE_DIR 填 /home/ftpadmin)"
echo "  2) 干跑验证:  FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 python3 /opt/ftp_puller/ftp_puller_verify.py"
echo "  3) 正式开跑:  systemctl enable --now ftp_puller"
echo "  4) 测试 FTP:  ftp 127.0.0.1  (用户 ftpadmin / 密码 CHANGE_ME_GATEWAY_PASSWORD)"
echo "  5) 看日志:    tail -f ~/ftp_puller_verify.log"
echo "============================================================"
exit $rc
