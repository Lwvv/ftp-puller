import sys, paramiko

host, user, pwd = sys.argv[1], sys.argv[2], sys.argv[3]
port = 22

cmds = [
  ("/opt/ftp_puller 目录", "ls -la /opt/ftp_puller/ 2>&1"),
  ("ftp_puller.conf", "cat /opt/ftp_puller/ftp_puller.conf 2>&1"),
  ("ftp_puller.service", "cat /opt/ftp_puller/ftp_puller.service 2>&1"),
  ("ftp_puller 运行状态", "systemctl is-active ftp_puller 2>&1; echo '---'; systemctl status ftp_puller --no-pager 2>&1 | head -20"),
  ("vsftpd 配置", "cat /etc/vsftpd/vsftpd.conf 2>&1"),
  ("vsftpd 状态", "systemctl is-active vsftpd 2>&1; echo '---'; systemctl status vsftpd --no-pager 2>&1 | head -20"),
  ("抽取日志尾部", "tail -n 60 /root/ftp_puller_verify.log 2>&1"),
  ("防火墙", "firewall-cmd --list-all 2>&1 | head -20"),
  ("监听端口", "ss -tlnp 2>&1 | grep -E ':21|:300' "),
  ("python3 版本", "python3 --version 2>&1"),
]

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    client.connect(host, port=port, username=user, password=pwd, timeout=15)
except Exception as e:
    print("连接失败:", e); sys.exit(1)

for title, cmd in cmds:
    print("\n" + "="*60)
    print("### " + title)
    print("="*60)
    stdin, stdout, stderr = client.exec_command(cmd)
    out = stdout.read().decode('utf-8','replace')
    err = stderr.read().decode('utf-8','replace')
    print(out)
    if err.strip():
        print("[stderr]", err)

client.close()
