#!/bin/bash
# ============================================================
# build_linux.sh — 在 Linux 上把 ftp_puller 编译成单文件二进制
# ============================================================
# 作用: 把源码(纯 .py)用 Nuitka 编译成无源码的 ELF 二进制,
#       防拷贝 / 防篡改 / 授权密钥编译后不可读。
#
# 【前置依赖】(编译前需具备, 离线环境见末尾说明)
#   1) gcc / g++        : 系统编译器   例: dnf install gcc gcc-c++
#   2) python3-devel    : Python 头文件 例: dnf install python3-devel
#   3) nuitka           : 编译工具     例: python3 -m pip install nuitka
#
# 【用法】
#   chmod +x build_linux.sh
#   ./build_linux.sh
# 产物: 当前目录 ./ftp_puller  (ELF 二进制)
#
# 【部署】
#   把 ./ftp_puller 和 license.dat 一起放到目标机 /opt/ftp_puller/
#   运行时 license.dat 放在二进制同目录即可(脚本自动查找)。
#
# 【离线编译链说明】
#   若目标机/编译机无外网, 需提前在有网的同版本 Linux 上:
#     python3 -m pip download nuitka -d nuitka_pkgs
#   把 nuitka_pkgs/ 连同 gcc/python3-devel 的离线 rpm 一起拷到编译机,
#   再: python3 -m pip install --no-index --find-links nuitka_pkgs nuitka
#
# 【注意】
#   编译机与目标机 glibc 版本应尽量一致或编译机更低, 否则目标机可能报
#   "version 'GLIBC_2.xx' not found"。建议在和目标机同发行版/同版本的机上编译。
# ============================================================
set -e
cd "$(dirname "$0")"

PY="${PY:-python3}"
echo "[build] 使用的 Python: $($PY --version 2>&1)"
echo "[build] 检查 nuitka ..."
if ! "$PY" -m nuitka --version >/dev/null 2>&1; then
  echo "缺少 nuitka, 请先安装: $PY -m pip install nuitka" >&2
  exit 1
fi

echo "[build] 开始编译单文件二进制 (可能需要几分钟) ..."
"$PY" -m nuitka --onefile \
  --jobs=4 \
  --output-filename=ftp_puller \
  ftp_puller_verify.py

echo "[build] 完成 -> ./ftp_puller"
ls -lh ./ftp_puller
echo "[build] 下一步: 把 ./ftp_puller 与 license.dat 放到目标机 /opt/ftp_puller/ 即可运行。"
