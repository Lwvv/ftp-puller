#!/bin/bash
# ============================================================
# ftp_puller.sh  ——  准实时从 FTP 服务器抽取(搬家式)文件
# 功能: 拉取服务器用 FTP 账号把目标机文件拉到本地, 并删除源文件
# 依赖: lftp  (Ubuntu/Debian: sudo apt install lftp ; CentOS/RHEL: sudo yum install lftp)
# 凭证: 账号密码放在 ~/.netrc (见下方说明), 脚本本身不含密码
# 启动: 见文件末尾的 cron / 循环 两种用法
# ============================================================

# ---------- 配置区(按需修改) ----------
FTP_HOST="目标服务器IP"          # 例如 192.168.1.100
REMOTE_DIR="/remote/source"     # 目标机上要抽的目录(结尾不要带 /)
LOCAL_DIR="/local/dest"         # 拉到本机存哪
LOCK_FILE="/var/run/ftp_puller.lock"
LOG_FILE="$HOME/ftp_puller.log"
# --------------------------------------

# 锁文件: 防止上一次还没跑完, 下一次又启动(短间隔必加, 否则会并发乱拉)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date '+%F %T') [WARN] 上一次仍在运行, 本次跳过" >> "$LOG_FILE"
    exit 0
fi

mkdir -p "$LOCAL_DIR"
log(){ echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

# 干跑模式: DRYRUN=1 ./ftp_puller.sh
# 只列出会动哪些文件, 不下载、不删除, 上线前先跑一次确认目标没错
if [ "${DRYRUN:-0}" = "1" ]; then
    log "[DRYRUN] 仅预览, 不下载不删除"
    lftp "ftp://$FTP_HOST" <<'LFTP'
set ftp:passive-mode on
mirror --only-newer --dry-run "'"$REMOTE_DIR"'" "'"$LOCAL_DIR"'"
bye
LFTP
    exit 0
fi

log "[START] 同步 $REMOTE_DIR -> $LOCAL_DIR (拉完删源)"

# --only-newer        : 只拉比本地新的文件, 重复跑不会全量重传
# --Remove-source-files: 下载成功后删除远程源文件(搬家式)
# --parallel=4        : 4 个文件并发, 提速
# 注意: 若远端文件正在被写入, 可能拉到半截就删。如担心, 可加:
#   mirror ... --newer-than=now-2minutes   (只动 2 分钟前修改的文件, 避开正在写的)
lftp "ftp://$FTP_HOST" <<'LFTP'
set ftp:passive-mode on
set net:timeout 10
set net:max-retries 3
mirror --only-newer --parallel=4 --verbose --Remove-source-files "'"$REMOTE_DIR"'" "'"$LOCAL_DIR"'"
bye
LFTP
RC=$?

if [ $RC -eq 0 ]; then
    log "[OK] 同步完成(源文件已删除)"
else
    log "[ERROR] lftp 退出码 $RC, 请检查网络/账号/目录权限"
fi
exit $RC

# ============================================================
# 用法一: cron 每分钟跑一次(最简, 但最快只能 1 分钟)
#   (crontab -l 2>/dev/null; echo "* * * * * $HOME/ftp_puller.sh >> $HOME/ftp_puller.log 2>&1") | crontab -
#
# 用法二: 想要 30 秒级, 用循环(后台常驻)。直接跑:
#   nohup bash -c 'while true; do ~/ftp_puller.sh; sleep 30; done' >> ~/ftp_puller.log 2>&1 &
#   或做成 systemd 服务(可开机自启+崩溃自愈), 需要我可另给 unit 文件。
#
# 上线前务必先干跑验证:
#   DRYRUN=1 ./ftp_puller.sh
#   看日志 ~/ftp_puller.log 确认它盯着的是正确目录, 再正式跑。
# ============================================================
