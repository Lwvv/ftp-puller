import sys, paramiko

host, user, pwd = sys.argv[1], sys.argv[2], sys.argv[3]
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, port=22, username=user, password=pwd, timeout=15)

def run(cmd, title=""):
    if title: print("\n--- "+title+" ---")
    i,o,e = c.exec_command(cmd)
    print(o.read().decode('utf-8','replace'))
    err=e.read().decode('utf-8','replace')
    if err.strip(): print("[stderr]", err)

# 1) 备份
run("cp -p /opt/ftp_puller/ftp_puller.conf /opt/ftp_puller/ftp_puller.conf.bak.$(date +%s)", "① 备份 conf")
# 2) 改 REMOTE_DIR=/home/ftp -> /
run("sed -i 's#^REMOTE_DIR=.*#REMOTE_DIR=/#' /opt/ftp_puller/ftp_puller.conf", "② 修正 REMOTE_DIR=/")
# 3) 确认关键行
run("grep -E '^(FTP_HOST|FTP_USER|FTP_PASS|REMOTE_DIR|LOCAL_DIR|MIN_AGE)=' /opt/ftp_puller/ftp_puller.conf", "③ 改后关键配置")
# 4) DRYRUN 干跑, 看能否枚举到源端文件(只读, 不下载不删)
run("FTP_PULLER_CONF=/opt/ftp_puller/ftp_puller.conf DRYRUN=1 /usr/bin/python3 /opt/ftp_puller/ftp_puller_verify.py 2>&1 | tail -20", "④ DRYRUN 干跑(只读验证)")
c.close()
