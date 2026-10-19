#!/bin/bash
# ============================================================
# FTP Puller 预检 + 交互启动脚本
# 用法(安装之后):  你填好 /opt/ftp_puller/ftp_puller.conf, 再运行:
#                    bash /opt/ftp_puller/test.sh
# 流程:
#   ① 只读预检(不下载/不删除): 配置完整性 + 本地落盘目录可写 + 源端 FTP 可登录并进入 REMOTE_DIR
#   ② 交互确认"源端删除策略(搬家式)"
#   ③ 交互确认"启动服务 + 开启开机自启"
# 仅当预检通过且你明确确认后, 才启动服务; 启动成功后自动清理交付包与解压目录。
# ============================================================
set -e

DEST=/opt/ftp_puller
CONF="$DEST/ftp_puller.conf"
EXEC="$DEST/ftp_puller"
[ -x "$EXEC" ] || EXEC="python3 $DEST/ftp_puller_verify.py"

if [ ! -f "$CONF" ]; then
  echo "错误: 找不到配置文件 $CONF, 请先运行 install.sh"
  exit 1
fi

# ---- ① 只读预检(纯 python3 + ftplib, 不下载/不删除) ----
echo "================ 预检测试(配置 + 本地目录 + 源端可达性) ================"
set +e
FTP_PULLER_CONF="$CONF" python3 - "$CONF" <<'PYEOF'
import sys, os, ftplib
conf = {}
path = sys.argv[1] if len(sys.argv) > 1 else "/opt/ftp_puller/ftp_puller.conf"
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            conf[k.strip()] = v.strip()
except FileNotFoundError:
    print("FAIL  找不到配置文件: " + path)
    sys.exit(2)

errors = []
warns = []
PLACE = "请填写源服务器FTP密码"

for key in ("FTP_HOST", "FTP_USER", "FTP_PASS", "REMOTE_DIR", "LOCAL_DIR"):
    if not conf.get(key, ""):
        errors.append("配置项缺失或为空: " + key)
if conf.get("FTP_PASS", "") == PLACE:
    errors.append("FTP_PASS 仍为占位符, 请填写真实源端密码")

ds = conf.get("DELETE_SOURCE", "1")
if ds not in ("0", "1"):
    errors.append("DELETE_SOURCE 取值非法: " + ds + " (应为 0 或 1)")

ld = conf.get("LOCAL_DIR", "")
if ld:
    try:
        os.makedirs(ld, exist_ok=True)
        t = os.path.join(ld, ".preflight_test_" + str(os.getpid()))
        with open(t, "w") as f:
            f.write("ok")
        os.remove(t)
        print("OK    本地落盘目录可写: " + ld)
    except Exception as e:
        errors.append("本地落盘目录不可写: " + ld + " (" + str(e) + ")")

host = conf.get("FTP_HOST", "")
user = conf.get("FTP_USER", "")
pw = conf.get("FTP_PASS", "")
rdir = conf.get("REMOTE_DIR", "") or "/"
if host and user and pw and pw != PLACE:
    try:
        ftp = ftplib.FTP(host, timeout=15)
        try:
            ftp.encoding = "utf-8"
        except Exception:
            pass
        ftp.login(user, pw)
        ftp.set_pasv(True)
        ftp.cwd(rdir)
        try:
            items = ftp.nlst()[:5]
        except Exception:
            items = []
        print("OK    源端 FTP 登录并进入目录成功: " + host + " -> " + rdir)
        if items:
            print("OK    目录内容样例: " + ", ".join(items))
        else:
            warns.append("源端目录为空或无法列目录(可继续, 但请确认是否为预期)")
        try:
            ftp.quit()
        except Exception:
            pass
    except ftplib.error_perm as e:
        tok = str(e).split()
        code = tok[0] if tok else ""
        if code == "530":
            errors.append("源端 FTP 登录失败(530, 账户或密码错误): " + str(e))
        elif code in ("550", "500", "501"):
            errors.append("源端目录访问失败(" + code + ", 请检查 REMOTE_DIR): " + str(e))
        else:
            errors.append("源端 FTP 操作被拒绝: " + str(e))
    except (ConnectionRefusedError, TimeoutError, OSError) as e:
        warns.append("源端 FTP 暂不可达(网络/防火墙? 守护进程会重试): " + str(e))
    except ftplib.Error as e:
        warns.append("源端 FTP 连接异常(守护进程会重试): " + str(e))

print("")
if errors:
    print("==== 预检未通过, 停止在启动前 ====")
    for e in errors:
        print("FAIL  " + e)
    for w in warns:
        print("WARN  " + w)
    sys.exit(1)
if warns:
    for w in warns:
        print("WARN  " + w)
print("==== 预检通过, 等待你确认启动 ====")
sys.exit(0)
PYEOF
_PF_RC=$?
set -e

if [ "$_PF_RC" -ne 0 ]; then
  echo ""
  echo "预检未通过, 请按上面 FAIL 提示修正 $CONF 后, 重跑本脚本: bash $DEST/test.sh"
  exit 1
fi

# ---- ② 交互: 源端删除策略 ----
echo ""
cur_del=$(grep '^DELETE_SOURCE=' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' ')
cur_del=${cur_del:-1}
echo "【源端文件删除】抽取校验通过后, 是否从 FTP 源端删除已拉取的文件(搬家式)?"
echo "  y / 1 = 启用(源端有删权限才真正删除, 无权限自动降级为留存, 仅告警一次)"
echo "  n / 0 = 不启用(纯留存模式, 源端文件永久保留, 适用于留底审计)"
printf "请选择 [默认 %s]: " "$cur_del"
read -r _ans
case "$_ans" in y|Y|1) _del=1;; n|N|0) _del=0;; *) _del="$cur_del";; esac
sed -i "s/^DELETE_SOURCE=.*/DELETE_SOURCE=$_del/" "$CONF"
echo "    源端删除策略已设为 DELETE_SOURCE=$_del"

# ---- ③ 交互: 确认启动 + 开启开机自启 ----
echo ""
printf "预检通过。是否现在启动服务并开启开机自启? [y/N]: "
read -r _go
case "$_go" in
  y|Y|1)
    echo "启动服务(开机自启 + 崩溃自愈)..."
    systemctl daemon-reload || true
    systemctl enable ftp_puller || true
    systemctl restart ftp_puller || true
    sleep 1
    if systemctl is-active --quiet ftp_puller; then
      echo "    [已启动] 服务状态 active —— 正式运行开始, 已开启开机自启"
      # 启动成功后清理交付包与解压目录(避免源文件残留在客户机上)
      if [ -f "$DEST/.install_src" ]; then
        SRC_DIR=$(cat "$DEST/.install_src" 2>/dev/null)
        if [ -n "$SRC_DIR" ] && [ "$SRC_DIR" != "$DEST" ] && [ -d "$SRC_DIR" ]; then
          for z in "$SRC_DIR/../ftp_puller_pkg.zip" "$SRC_DIR/../ftp_puller.zip"; do
            if [ -f "$z" ]; then rm -f "$z" && echo "    已删除交付包: $z"; fi
          done
          rm -rf "$SRC_DIR" && echo "    已删除解压目录: $SRC_DIR"
        fi
        rm -f "$DEST/.install_src"
      fi
    else
      echo "    [警告] 服务未运行, 请查看日志: tail -f $DEST/logs/ftp_puller_verify.log"
    fi
    ;;
  *)
    echo "未启动。确认配置无误后可手动启动(并开启开机自启):"
    echo "    systemctl enable --now ftp_puller"
    ;;
esac
