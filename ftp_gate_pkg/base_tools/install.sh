#!/bin/bash
# ============================================================
# 基础工具离线安装脚本 (openEuler 24.03 SP3 x86_64)
# 用于: 最小安装的系统里缺 tar / netstat 等常用命令, 离线补上
# 方式: 纯 rpm -Uvh 装本地包, 不调用 dnf/yum, 零联网
# 用法: 以 root 运行:  bash install.sh
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1
[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root 运行 (sudo bash install.sh)"; exit 1; }

echo ">>> 离线安装基础工具 (纯本地 rpm, 不联网)"
# 一次性事务安装目录内全部 rpm; 依赖均为系统自带(systemd/基础库), 无需联网
if rpm -Uvh --replacepkgs ./rpms/*.rpm; then
    echo "    安装事务完成"
else
    echo "[错误] rpm 安装失败, 上方会列出缺失的依赖; 请把缺失的 rpm 也放进 rpms/ 后重试"
    exit 1
fi

echo ">>> 验证命令是否就位:"
for c in tar netstat lsof ps wget ftp; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "    $c  ✓  $(command -v "$c")"
    else
        echo "    $c  ✗ 未找到, 请检查上方安装日志"
    fi
done
