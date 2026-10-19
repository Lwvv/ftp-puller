#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ftp_puller_verify.py  ——  FTP 抽取(搬家式) + 文件校验
- 纯 FTP, 仅用 Python 标准库(无需 pip install, Linux 自带 python3)
- 下载后先做 大小校验; 哈希校验优先用远端 file.md5 随车文件, 否则自动尝试 FTP 扩展 XMD5/XCRC(纯 FTP, 无需源端配合, 取决于服务器是否启用); 都没有则退回仅大小校验
- 校验通过才删除远端源文件(搬家式); 校验失败则保留远端并告警(不会丢数据)
- 递归抽取子目录; 可跳过"正在写入"的新文件(MIN_AGE)
- 带运行锁(flock): 防止 cron 重叠执行导致并发冲突
- 断线自动重连重试(最多 MAX_RETRIES 次); 启动清理上次崩溃残留的 .part 半截文件
- 中文文件名兼容(utf-8); 老服务器(无 MLSD)也尽量补 size/modify 以支持大小校验与 MIN_AGE
用法:
  python3 ftp_puller_verify.py            # 正式跑(拉完删源); 无 conf 时交互询问
  DRYRUN=1 python3 ftp_puller_verify.py   # 只预览, 不下载不删
  # 用 conf 文件(放账号/目录, 见上方说明): 建 ~/.ftp_puller.conf 后直接跑即可
  # 指定别的 conf 路径: FTP_PULLER_CONF=/path/to/conf python3 ftp_puller_verify.py
  # 注意: cron 定时跑必须配 conf 或环境变量, 不能靠交互输入(无终端会卡住)
"""
import ftplib, os, hashlib, sys, datetime, time, tempfile, zlib, fcntl, socket

# ---------------- 配置加载 ----------------
# 凭证/目录来源优先级: 环境变量 > conf 文件 > 交互输入
# conf 文件(默认 ~/.ftp_puller.conf, 可用环境变量 FTP_PULLER_CONF 指定别的路径), 每行一个:
#   FTP_HOST=1.2.3.4
#   FTP_USER=myuser
#   FTP_PASS=******
#   REMOTE_DIR=/remote/source
#   LOCAL_DIR=/local/dest
# 没有 conf 或某字段缺失时, 运行时交互式询问(密码不回显); 也可直接用环境变量传入。
CONF_PATH  = os.environ.get("FTP_PULLER_CONF", os.path.expanduser("~/.ftp_puller.conf"))
MIN_AGE    = int(os.environ.get("MIN_AGE", "120"))   # 跳过 N 秒内修改的文件, 0=不限制
DRYRUN     = os.environ.get("DRYRUN", "0") == "1"
LOG_PATH   = os.path.expanduser("~/ftp_puller_verify.log")
LOCK_PATH  = os.path.expanduser("~/ftp_puller_verify.lock")
MAX_RETRIES = 3                    # 连接/运行中掉线后, 最多重连重试次数
# -------------------------------------------------

def log(msg):
    line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line + "\n")

def load_config():
    """按 环境变量 > conf 文件 > 交互输入 的优先级取配置"""
    vals = {}
    if os.path.isfile(CONF_PATH):
        with open(CONF_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
        # 安全提醒: conf 含密码, 权限应仅本人可读
        mode = os.stat(CONF_PATH).st_mode & 0o777
        if mode & 0o077:
            print(f"[WARN] conf 文件权限 {oct(mode)}, 建议执行: chmod 600 {CONF_PATH}")
    def get(key, prompt, secret=False):
        if key in os.environ and os.environ[key]:
            return os.environ[key]
        if key in vals and vals[key]:
            return vals[key]
        if secret:
            import getpass
            return getpass.getpass(prompt)
        return input(prompt)
    host = get("FTP_HOST", "FTP 服务器 IP: ")
    user = get("FTP_USER", "FTP 账号: ")
    pw   = get("FTP_PASS", "FTP 密码: ", secret=True)
    rdir = get("REMOTE_DIR", "远端目录(回车=/): ").strip() or "/"
    ldir = get("LOCAL_DIR", "本机存放目录: ").strip()
    return host, user, pw, rdir, ldir

def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def hashes_of(path):
    """一次读取同时算 MD5 与 CRC32"""
    h = hashlib.md5()
    c = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
            c = zlib.crc32(chunk, c)
    return h.hexdigest(), "%08x" % (c & 0xffffffff)

def remote_hash(ftp, rfile):
    """尝试用 FTP 扩展 XMD5 / XCRC 取远端哈希; 返回 (algo, hex) 或 None。
    纯 FTP, 不需要源端配合, 但取决于服务器是否启用该扩展(你只有 FTP 账号也能用, 只是开不了)。"""
    for cmd, algo, width in (("XMD5", "md5", 32), ("XCRC", "crc32", 8)):
        try:
            resp = ftp.voidcmd(f"{cmd} {rfile}")
            token = resp.split()[-1].strip().lower()
            if len(token) == width and all(ch in "0123456789abcdef" for ch in token):
                return algo, token
        except ftplib.error_perm:
            continue
        except Exception:
            continue
    return None

def connect():
    ftp = ftplib.FTP(FTP_HOST, timeout=30)
    try:
        ftp.encoding = "utf-8"  # 服务器用 UTF-8 时中文文件名才正常; 不支持则忽略
    except Exception:
        pass
    ftp.login(FTP_USER, FTP_PASS)
    ftp.set_pasv(True)          # 被动模式, 跨防火墙更稳
    return ftp

def enum_dir(ftp, path):
    """返回 (files, dirs) 字典: name -> facts"""
    files, dirs = {}, {}
    try:
        for name, facts in ftp.mlsd(path):
            if name in (".", ".."):
                continue
            if facts.get("type") == "dir":
                dirs[name] = facts
            else:
                files[name] = facts
    except ftplib.error_perm:
        # 个别老服务器不支持 MLSD, 退回 NLST, 并逐个补 size/modify 以便继续做大小校验与 MIN_AGE
        for name in ftp.nlst(path):
            bn = os.path.basename(name)
            if bn in (".", ".."):
                continue
            item = name if path == "" else path.rstrip("/") + "/" + bn
            facts = {}
            try:
                sz = ftp.size(item)
                if sz is not None:
                    facts["size"] = str(sz)
            except Exception:
                pass
            try:
                resp = ftp.voidcmd("MDTM " + item)
                facts["modify"] = resp.split()[-1]
            except Exception:
                pass
            files[bn] = facts
    return files, dirs

def process(ftp, rel_path):
    """rel_path: 相对 REMOTE_DIR 的目录(根目录为 '')"""
    remote_path = REMOTE_DIR if rel_path == "" else REMOTE_DIR.rstrip("/") + "/" + rel_path
    local_path  = LOCAL_DIR if rel_path == "" else os.path.join(LOCAL_DIR, rel_path)
    os.makedirs(local_path, exist_ok=True)

    files, dirs = enum_dir(ftp, remote_path)

    for name, facts in files.items():
        if name.endswith(".md5"):
            continue   # 随车校验文件稍后配对处理, 这里跳过

        # 跳过正在写入的文件(按修改时间)
        if MIN_AGE and "modify" in facts:
            mtime = datetime.datetime.strptime(facts["modify"], "%Y%m%d%H%M%S").timestamp()
            if (time.time() - mtime) < MIN_AGE:
                log(f"[SKIP] 正在写入(太新): {remote_path}/{name}")
                continue

        rfile  = remote_path.rstrip("/") + "/" + name
        lfile  = os.path.join(local_path, name)
        sidecar = name + ".md5"

        if DRYRUN:
            log(f"[DRYRUN] 会处理: {rfile}")
            continue

        # 1) 下载到临时文件(.part), 完成后再改名, 避免半截文件被当成品
        tmp = lfile + ".part"
        try:
            with open(tmp, "wb") as f:
                ftp.retrbinary("RETR " + rfile, f.write)
        except Exception as e:
            log(f"[ERROR] 下载失败 {rfile}: {e}")
            try: os.remove(tmp)
            except: pass
            continue

        # 2) 大小校验(挡住截断/网络中断)
        ok = True
        if "size" in facts:
            exp, got = int(facts["size"]), os.path.getsize(tmp)
            if exp != got:
                log(f"[FAIL] 大小不符 {rfile}: 期望 {exp} 实得 {got}")
                ok = False

        # 3) 哈希校验: 优先远端随车 .md5; 否则尝试 FTP 扩展 XMD5/XCRC(纯 FTP, 无需源端配合)
        local_md5, local_crc = hashes_of(tmp)
        if ok:
            expected_algo = expected = None
            if sidecar in files:
                try:
                    sremote = remote_path.rstrip("/") + "/" + sidecar
                    with tempfile.NamedTemporaryFile("wb", delete=False) as sf:
                        ftp.retrbinary("RETR " + sremote, sf.write)
                        scpath = sf.name
                    with open(scpath) as sfc:
                        expected = sfc.read().split()[0].strip().lower()
                    os.remove(scpath)
                    expected_algo = "md5"
                except Exception as e:
                    log(f"[WARN] 读取 .md5 失败 {sidecar}: {e}")
            else:
                rh = remote_hash(ftp, rfile)
                if rh:
                    expected_algo, expected = rh

            if expected_algo == "md5":
                actual = local_md5
            elif expected_algo == "crc32":
                actual = local_crc
            else:
                actual = None

            if expected_algo and actual is not None:
                if actual != expected:
                    log(f"[FAIL] {expected_algo.upper()} 不符 {rfile}: 期望 {expected} 实得 {actual}")
                    ok = False
                else:
                    log(f"[OK] {expected_algo.upper()} 校验通过 {rfile}")
            else:
                log(f"[INFO] 无可用哈希(源端无 .md5 且服务器不支持 XMD5/XCRC), 仅做大小校验")

        if not ok:
            try: os.remove(tmp)
            except: pass
            log(f"[KEEP] 保留远端(未通过校验, 等下轮重试): {rfile}")
            continue

        # 4) 校验通过 -> 落盘 + 删源(搬家式)
        os.replace(tmp, lfile)
        try:
            ftp.delete(rfile)
            if sidecar in files:
                try: ftp.delete(remote_path.rstrip("/") + "/" + sidecar)
                except: pass
            log(f"[MOVED] 已抽取并删除源: {rfile}")
        except Exception as e:
            log(f"[ERROR] 删除源失败 {rfile}: {e} (本地已存 {lfile}, 请手动处理)")

    # 递归处理子目录
    for name in dirs:
        nxt = name if rel_path == "" else rel_path + "/" + name
        process(ftp, nxt)

def acquire_lock():
    """用 flock 防止多个实例同时跑(cron 间隔短于运行时间时会重叠)"""
    lock_fd = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log(f"[WARN] 另一实例正在运行, 本实例直接退出(锁: {LOCK_PATH})")
        sys.exit(0)
    return lock_fd   # 持有不关, 进程结束随文件描述符自动释放

def cleanup_part_files():
    """清掉上次异常退出留下的 .part 半截文件, 避免越积越多"""
    if not os.path.isdir(LOCAL_DIR):
        return
    for root, _, names in os.walk(LOCAL_DIR):
        for n in names:
            if n.endswith(".part"):
                try:
                    os.remove(os.path.join(root, n))
                    log(f"[CLEAN] 删除残留临时文件 {n}")
                except OSError:
                    pass

def main():
    log("========== 开始 FTP 抽取(带校验) ==========")
    lock_fd = acquire_lock()       # 拿到锁才继续
    cleanup_part_files()           # 先扫一遍残留 .part
    last_err = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            ftp = connect()
        except Exception as e:
            log(f"[FATAL] 连接/登录失败(第{attempt}次): {e}")
            last_err = e
            time.sleep(5)
            continue
        try:
            process(ftp, "")
            last_err = None
            break
        except (ftplib.all_errors, socket.error, OSError) as e:
            # 运行中连接掉线/超时: 重连后从根目录重跑(已搬走的文件服务器端已不存在, 安全)
            log(f"[WARN] 运行中连接异常(第{attempt}次), 将重连重试: {e}")
            last_err = e
            time.sleep(5)
        finally:
            try: ftp.quit()
            except Exception: pass
    if last_err is not None:
        log(f"[FATAL] 重试 {MAX_RETRIES} 次仍失败, 退出: {last_err}")
        sys.exit(1)
    log("========== 结束 ==========")

if __name__ == "__main__":
    # 运行时才加载配置(支持 conf 文件 / 交互输入 / 环境变量)
    FTP_HOST, FTP_USER, FTP_PASS, REMOTE_DIR, LOCAL_DIR = load_config()
    main()
