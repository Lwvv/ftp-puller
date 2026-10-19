#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ftp_puller_verify.py  ——  FTP 抽取(搬家式) + 文件校验 + 详细日志
- 纯 FTP, 仅用 Python 标准库(无需 pip install, Linux 自带 python3)
- 下载后先做 大小校验; 哈希校验优先用远端 file.md5 随车文件, 否则自动尝试 FTP 扩展 XMD5/XCRC; 都没有则退回仅大小校验
- 校验通过才删除远端源文件(搬家式); 校验失败则保留远端并告警(不会丢数据)
- 递归抽取子目录; 可跳过"正在写入"的新文件(MIN_AGE)
- 带运行锁(flock): 防止 cron 重叠执行导致并发冲突
- 断线自动重连重试(最多 MAX_RETRIES 次); 启动清理上次崩溃残留的 .part 半截文件
- 中文文件名兼容(utf-8); 老服务器(无 MLSD)也尽量补 size/modify 以支持大小校验与 MIN_AGE
- 【日志增强】每轮: 监听源端目录文件清单/数量 -> 标注是否上传完毕(太新跳过) -> 逐个开始抽取时间戳 -> 本轮抽走/跳过/失败 + 源端剩余 + 累计抽走
用法:
  python3 ftp_puller_verify.py            # 正式跑(拉完删源); 无 conf 时交互询问
  DRYRUN=1 python3 ftp_puller_verify.py   # 只预览, 不下载不删
  FTP_PULLER_CONF=/path/to/conf python3 ftp_puller_verify.py
"""
import ftplib, os, hashlib, sys, datetime, time, tempfile, zlib, fcntl, socket, json, shutil

# ---------------- 配置加载 ----------------
# 配置优先级: 环境变量 > conf 文件 > 下方默认值
CONF_PATH  = os.environ.get("FTP_PULLER_CONF", os.path.expanduser("~/.ftp_puller.conf"))
DRYRUN     = os.environ.get("DRYRUN", "0") == "1"
LOG_PATH   = os.path.expanduser("~/ftp_puller_verify.log")
LOCK_PATH  = os.path.expanduser("~/ftp_puller_verify.lock")
STATS_PATH = os.path.expanduser("~/ftp_puller_verify.stats")  # 累计抽走文件数(持久化)
MAX_RETRIES = 3                    # 连接/运行中掉线后, 最多重连重试次数

# 先把 conf 文件读成字典, 供 conf_get 使用
CONF = {}
if os.path.isfile(CONF_PATH):
    with open(CONF_PATH, encoding="utf-8") as _f:
        for _line in _f:
            _line = _line.strip()
            if not _line or _line.startswith("#") or "=" not in _line:
                continue
            _k, _v = _line.split("=", 1)
            CONF[_k.strip()] = _v.strip()

def conf_get(key, default):
    if key in os.environ and os.environ[key] != "":
        return os.environ[key]
    return CONF.get(key, default)

# ---- 以下均为可配置项(写进 conf 文件即可, 无需改脚本) ----
MIN_AGE        = int(conf_get("MIN_AGE", "120"))            # 跳过 N 秒内修改的文件, 0=不限制
DISK_PATH      = conf_get("DISK_PATH", "/home")             # 监控该路径所在分区的使用率
DISK_THRESHOLD = int(conf_get("DISK_THRESHOLD", "80"))      # 使用率%达到此阈值后, 自动清理 LOCAL_DIR 最久的文件
LOG_KEEP_DAYS  = int(conf_get("LOG_KEEP_DAYS", "180"))     # 日志按天轮转, 保留最近 N 天(超过自动删); 0=永久保留
CHOWN_LOCAL   = conf_get("CHOWN_LOCAL", "0") == "1"         # 落盘后是否把属主改为 LOCAL_DIR 拥有者(网闸可删)
# -------------------------------------------------

def _rotate_daily():
    """按天轮转: 当前日志文件 mtime 不是今天 -> 归档为 .YYYY-MM-DD; 并清理超过 LOG_KEEP_DAYS 天的历史"""
    try:
        if os.path.exists(LOG_PATH):
            mtime_date = datetime.datetime.fromtimestamp(os.path.getmtime(LOG_PATH)).date()
            today = datetime.datetime.now().date()
            if mtime_date != today:
                archive = f"{LOG_PATH}.{mtime_date:%Y-%m-%d}"
                try:
                    if os.path.exists(archive):
                        os.remove(archive)
                    os.rename(LOG_PATH, archive)
                except OSError:
                    pass
        if LOG_KEEP_DAYS > 0:
            cutoff = datetime.datetime.now().date() - datetime.timedelta(days=LOG_KEEP_DAYS)
            d = os.path.dirname(LOG_PATH) or "."
            base = os.path.basename(LOG_PATH)
            for fn in os.listdir(d):
                if not fn.startswith(base + "."):
                    continue
                datestr = fn[len(base) + 1:]
                try:
                    fdate = datetime.datetime.strptime(datestr, "%Y-%m-%d").date()
                except ValueError:
                    continue
                if fdate < cutoff:
                    try:
                        os.remove(os.path.join(d, fn))
                    except OSError:
                        pass
    except Exception:
        pass

def log(msg):
    line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    try:
        _rotate_daily()
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def human(n):
    """把字节数转成人类可读(KB/MB/GB)"""
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024

def load_stats():
    try:
        with open(STATS_PATH) as f:
            return int(json.load(f).get("total_moved", 0))
    except Exception:
        return 0

def save_stats(n):
    try:
        with open(STATS_PATH, "w") as f:
            json.dump({"total_moved": int(n)}, f)
    except Exception:
        pass

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
    h = hashlib.md5()
    c = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
            c = zlib.crc32(chunk, c)
    return h.hexdigest(), "%08x" % (c & 0xffffffff)

def remote_hash(ftp, rfile):
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
    ftp = ftplib.FTP(FTP_HOST, timeout=120)
    try:
        ftp.encoding = "utf-8"
    except Exception:
        pass
    ftp.login(FTP_USER, FTP_PASS)
    ftp.set_pasv(True)
    return ftp

def enum_dir(ftp, path):
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

def collect_data_files(ftp, path, collected, depth=0, limit=50):
    """递归收集源端"数据文件"相对路径(不含 .md5 随车校验文件), 结果追加到 collected"""
    if depth > 20 or len(collected) >= limit:
        return
    try:
        files, dirs = enum_dir(ftp, path)
    except Exception as e:
        log(f"[WARN] 统计目录失败 {path}: {e}")
        return
    for name in files:
        if name.endswith(".md5"):
            continue
        rel = name if path in ("", "/") else path.rstrip("/") + "/" + name
        collected.append(rel)
        if len(collected) >= limit:
            return
    for name in dirs:
        sub = path if path in ("", "/") else path.rstrip("/") + "/" + name
        collect_data_files(ftp, sub, collected, depth + 1, limit)

def process(ftp, rel_path):
    """rel_path: 相对 REMOTE_DIR 的目录(根目录为 '')。返回 (moved, skip, fail)"""
    moved = skip = fail = 0
    remote_path = REMOTE_DIR if rel_path == "" else REMOTE_DIR.rstrip("/") + "/" + rel_path
    local_path  = LOCAL_DIR if rel_path == "" else os.path.join(LOCAL_DIR, rel_path)
    os.makedirs(local_path, exist_ok=True)
    # 网闸场景: 把创建的子目录属主改成 LOCAL_DIR 的拥有者(便于下游 FTP 账户删除)
    if CHOWN_LOCAL:
        try:
            st = os.stat(LOCAL_DIR)
            os.chown(local_path, st.st_uid, st.st_gid)
        except Exception:
            pass

    files, dirs = enum_dir(ftp, remote_path)

    # ---- 目录扫描日志: 列出本目录每个文件, 标注状态 ----
    data_files = [n for n in files if not n.endswith(".md5")]
    log(f"[SCAN] 目录 {remote_path}: 共 {len(files)} 项 (数据文件 {len(data_files)} 个, .md5 {len(files)-len(data_files)} 个, 子目录 {len(dirs)} 个)")
    for name, facts in files.items():
        sz = facts.get("size", "?")
        mt = facts.get("modify", "?")
        note = []
        if name.endswith(".md5"):
            note.append("随车校验文件")
        if MIN_AGE and "modify" in facts:
            mtime = datetime.datetime.strptime(facts["modify"], "%Y%m%d%H%M%S").timestamp()
            if (time.time() - mtime) < MIN_AGE:
                note.append(f"太新(距现在 {int(time.time()-mtime)}s<{MIN_AGE}, 可能仍在上传)")
        if note:
            log(f"    · {name}  大小={sz}  修改={mt}  [{' ; '.join(note)}]")

    for name, facts in files.items():
        if name.endswith(".md5"):
            continue   # 随车校验文件稍后配对处理, 这里跳过

        # 跳过正在写入的文件(按修改时间) —— 即判断是否"已上传完毕"
        if MIN_AGE and "modify" in facts:
            mtime = datetime.datetime.strptime(facts["modify"], "%Y%m%d%H%M%S").timestamp()
            dt = time.time() - mtime
            if dt < MIN_AGE:
                log(f"[SKIP] 文件可能仍在写入/未上传完(修改于 {facts['modify']}, 距现在 {int(dt)}s < MIN_AGE={MIN_AGE}), 暂不抽取: {remote_path}/{name}")
                skip += 1
                continue

        rfile  = remote_path.rstrip("/") + "/" + name
        lfile  = os.path.join(local_path, name)
        sidecar = name + ".md5"

        if DRYRUN:
            log(f"[DRYRUN] 将抽取: {rfile} (大小 {facts.get('size','?')} 字节)")
            continue

        # 1) 下载到临时文件(.part), 带单行实时刷新进度条
        tmp = lfile + ".part"
        exp_sz = int(facts["size"]) if "size" in facts else None
        if exp_sz is not None:
            log(f"[PULL] 开始抽取 {rfile}  总大小 {exp_sz} 字节 @ {datetime.datetime.now():%H:%M:%S}")
        else:
            log(f"[PULL] 开始抽取 {rfile}  (大小未知) @ {datetime.datetime.now():%H:%M:%S}")
        BARW = 30
        def draw_bar(pct, cur, tot):
            """单行 \r 刷新进度条(终端/ tail -f 原地刷新)"""
            filled = pct * BARW // 100
            bar = "█" * filled + "░" * (BARW - filled)
            tot_s = human(tot) if tot else "?"
            line = f"[PROGRESS] {name} [{bar}] {pct:3d}% {human(cur)}/{tot_s}"
            try:
                sys.stdout.write("\r" + line); sys.stdout.flush()
            except Exception:
                pass
            try:
                with open(LOG_PATH, "a", encoding="utf-8") as lf:
                    lf.write("\r" + line)   # 不带 \n, 与下一帧 \r 原地叠加
            except Exception:
                pass
        try:
            got = 0
            last_pct = -1
            last_t = 0.0
            def cb(b):
                nonlocal got, last_pct, last_t
                f.write(b)
                got += len(b)
                now = time.time()
                if exp_sz:
                    pct = got * 100 // exp_sz
                    # 每前进 1% 或每 0.5 秒刷新一次(取先到): 慢速传输也频繁动
                    if (pct - last_pct >= 1) or (now - last_t >= 0.5):
                        last_pct = pct
                        last_t = now
                        draw_bar(pct, got, exp_sz)
                else:
                    # 无总大小: 每 0.5 秒刷新, 进度条按已下载字节循环表示"传输中"
                    if now - last_t >= 0.5:
                        last_t = now
                        pos = (got // (2 * 1024 * 1024)) % BARW
                        bar = "█" * pos + "░" * (BARW - pos)
                        line = f"[PROGRESS] {name} [{bar}] ??% {human(got)} (总大小未知,传输中)"
                        try:
                            sys.stdout.write("\r" + line); sys.stdout.flush()
                        except Exception:
                            pass
                        try:
                            with open(LOG_PATH, "a", encoding="utf-8") as lf:
                                lf.write("\r" + line)
                        except Exception:
                            pass
            with open(tmp, "wb") as f:
                ftp.retrbinary("RETR " + rfile, cb)
            # 落定完成行(带换行, 让日志文件正常结束这一行)
            bar = "█" * BARW
            tot_s = human(exp_sz) if exp_sz else human(got)
            line = f"[PROGRESS] {name} [{bar}] 100% {human(got)}/{tot_s}"
            try:
                sys.stdout.write("\r" + line + "\n"); sys.stdout.flush()
            except Exception:
                pass
            with open(LOG_PATH, "a", encoding="utf-8") as lf:
                lf.write(line + "\n")
        except Exception as e:
            # 异常时补一个换行, 避免进度条片段污染后续日志
            try:
                sys.stdout.write("\n"); sys.stdout.flush()
                with open(LOG_PATH, "a", encoding="utf-8") as lf:
                    lf.write("\n")
            except Exception:
                pass
            log(f"[ERROR] 下载失败 {rfile}: {e}")
            try: os.remove(tmp)
            except: pass
            fail += 1
            continue

        # 2) 大小校验
        ok = True
        if "size" in facts:
            exp, got_sz = int(facts["size"]), os.path.getsize(tmp)
            if exp != got_sz:
                log(f"[FAIL] 大小不符 {rfile}: 期望 {exp} 实得 {got_sz}")
                ok = False

        # 3) 哈希校验: 优先远端随车 .md5; 否则尝试 FTP 扩展 XMD5/XCRC
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
            fail += 1
            continue

        # 4) 校验通过 -> 落盘 + 删源(搬家式)
        os.replace(tmp, lfile)
        # 网闸场景: 把落盘文件属主改成 LOCAL_DIR 的拥有者(便于下游 FTP 账户删除, 搬家式不残留)
        if CHOWN_LOCAL:
            try:
                st = os.stat(LOCAL_DIR)
                os.chown(lfile, st.st_uid, st.st_gid)
                log(f"[CHOWN] 落盘文件已改属主 {st.st_uid}:{st.st_gid} -> {lfile}")
            except Exception as e:
                log(f"[WARN] chown 失败 {lfile}: {e}")
        try:
            ftp.delete(rfile)
            if sidecar in files:
                try: ftp.delete(remote_path.rstrip("/") + "/" + sidecar)
                except: pass
            log(f"[MOVED] 已抽取并删除源: {rfile} ({os.path.getsize(lfile)} 字节)")
        except Exception as e:
            log(f"[ERROR] 删除源失败 {rfile}: {e} (本地已存 {lfile}, 请手动处理)")
        moved += 1

    # 递归处理子目录
    for name in dirs:
        nxt = name if rel_path == "" else rel_path + "/" + name
        m, s, f = process(ftp, nxt)
        moved += m; skip += s; fail += f
    return moved, skip, fail

def acquire_lock():
    lock_fd = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log(f"[WARN] 另一实例正在运行, 本实例直接退出(锁: {LOCK_PATH})")
        sys.exit(0)
    return lock_fd

def cleanup_part_files():
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

def purge_oldest():
    """硬盘监控: 当 DISK_PATH 所在分区使用率 >= DISK_THRESHOLD 时,
    按修改时间从最旧到最新删除 LOCAL_DIR 中的文件, 直到降到阈值以下或无可删。
    只删 LOCAL_DIR 内部的真实文件(.part 临时文件不删, 避免损坏下载), 不碰其他目录。"""
    try:
        du = shutil.disk_usage(DISK_PATH)
        pct = du.used * 100 // du.total
    except Exception as e:
        log(f"[WARN] 磁盘用量获取失败 {DISK_PATH}: {e}")
        return
    if pct < DISK_THRESHOLD:
        return
    log(f"[PURGE] {DISK_PATH} 分区使用率 {pct}% >= 阈值 {DISK_THRESHOLD}%, 开始清理 LOCAL_DIR 最久文件")
    items = []
    for root, _, names in os.walk(LOCAL_DIR):
        for n in names:
            if n.endswith(".part"):          # 不删正在下载的临时文件
                continue
            p = os.path.join(root, n)
            try:
                items.append((os.path.getmtime(p), os.path.getsize(p), p))
            except OSError:
                pass
    if not items:
        log(f"[PURGE] LOCAL_DIR 无可删文件, 当前 {DISK_PATH} 使用率仍 {pct}%")
        return
    items.sort()   # 按 mtime 升序: 最旧的排在最前
    deleted = 0
    freed = 0
    for mtime, size, p in items:
        if pct < DISK_THRESHOLD:
            break
        try:
            os.remove(p)
            deleted += 1
            freed += size
            log(f"[PURGE] 已删最久文件 {p} (修改于 {datetime.datetime.fromtimestamp(mtime):%Y-%m-%d %H:%M:%S}, {human(size)})")
        except OSError as e:
            log(f"[WARN] 删除失败 {p}: {e}")
            continue
        try:
            du = shutil.disk_usage(DISK_PATH)
            pct = du.used * 100 // du.total
        except Exception:
            pass
    log(f"[PURGE] 清理完成: 删除 {deleted} 个文件, 释放 {human(freed)}, 当前 {DISK_PATH} 使用率 {pct}%")

def main():
    log("========== 开始 FTP 抽取(带校验) ==========")
    lock_fd = acquire_lock()
    cleanup_part_files()
    purge_oldest()
    last_err = None
    moved = skip = fail = before = after = 0
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            ftp = connect()
        except Exception as e:
            log(f"[FATAL] 连接/登录失败(第{attempt}次): {e}")
            last_err = e
            time.sleep(5)
            continue
        try:
            before_list = []
            collect_data_files(ftp, REMOTE_DIR, before_list)
            before = len(before_list)
            if before == 0:
                log(f"[WATCH] 监听源端 {FTP_HOST}:{REMOTE_DIR} -> 当前【无】待抽取文件")
            else:
                log(f"[WATCH] 监听源端 {FTP_HOST}:{REMOTE_DIR} -> 当前有 {before} 个数据文件待抽取:")
                for rel in before_list[:30]:
                    log(f"    · 待抽取: {rel}")
                if before > 30:
                    log(f"    · … 等其余 {before - 30} 个文件")
            moved, skip, fail = process(ftp, "")
            after_list = []
            collect_data_files(ftp, REMOTE_DIR, after_list)
            after = len(after_list)
            last_err = None
            break
        except (ftplib.Error, OSError) as e:
            log(f"[WARN] 运行中连接异常(第{attempt}次), 将重连重试: {e}")
            last_err = e
            time.sleep(5)
        finally:
            try: ftp.quit()
            except Exception: pass
    if last_err is not None:
        log(f"[FATAL] 重试 {MAX_RETRIES} 次仍失败, 退出: {last_err}")
        sys.exit(1)
    if DRYRUN:
        log(f"[SUMMARY][DRYRUN] 本轮预览: 将抽走 {moved} 个(未实际下载/删除); 源端当前 {after} 个; 累计已抽走 {load_stats()} 个")
    else:
        total = load_stats() + moved
        save_stats(total)
        log(f"[SUMMARY] 本轮: 抽走 {moved} / 跳过(上传中) {skip} / 失败 {fail}; 源端剩余 {after} 个(抽取前 {before}); 累计已抽走 {total} 个")
    log("========== 结束 ==========")

if __name__ == "__main__":
    FTP_HOST, FTP_USER, FTP_PASS, REMOTE_DIR, LOCAL_DIR = load_config()
    main()
