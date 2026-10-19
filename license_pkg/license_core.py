# -*- coding: utf-8 -*-
"""
license_core.py — 期限授权核心 (零依赖, 纯标准库)

设计目标(单一职责, 与具体业务/机器码无关):
  - 只做一件事: 校验"使用期限"。没有合法且未过期的 license.dat, 程序拒绝运行。
  - 防篡改: 用 HMAC-SHA256 对密文签名, 任何人改 license 都会校验失败。
  - 轻量混淆: XOR 加密, 配合编译成二进制后密钥不可读, 足以防"白嫖/随手拷贝"。
  - 不绑定机器码、不依赖任何业务路径/网络, 可独立复用于任意程序。

用法:
  校验(运行端):  from license_core import check_license; ok, msg = check_license(path)
  生成(授权端):  python3 gen_license.py --expire 2027-12-31 --out license.dat
"""

import os
import sys
import json
import base64
import hashlib
import hmac
import datetime

# ---- 授权密钥 (硬编码, 编译成二进制后不可读) ----
# 改这个字符串即可「换锁」(让旧 license 全部失效)。长度随意, 会经 PBKDF2 派生。
AUTH_KEY = b"FTP-PULLER-AUTH-KEY-2026-GOLDENCIS-9f3a2c7b"

_SALT = b"ftp-puller-license-salt-v1"
_MAC_LEN = 32  # sha256


def _derive(key):
    """PBKDF2 派生 32 字节密钥"""
    return hashlib.pbkdf2_hmac("sha256", key, _SALT, 10000)


def _xor(data, key):
    out = bytearray(len(data))
    for i, b in enumerate(data):
        out[i] = b ^ key[i % len(key)]
    return bytes(out)


def _sign(payload, key):
    return hmac.new(key, payload, hashlib.sha256).digest()


def make_license(expire, issued=None, key=AUTH_KEY):
    """生成授权 blob 字符串 (base64)。expire/issued 为 'YYYY-MM-DD'"""
    if issued is None:
        issued = datetime.date.today().isoformat()
    doc = json.dumps({"issued": issued, "expire": expire},
                     ensure_ascii=False, sort_keys=True).encode("utf-8")
    dk = _derive(key)
    enc = _xor(doc, dk[:32])
    mac = _sign(enc, dk)
    return base64.b64encode(enc + mac).decode("ascii")


def verify_license(blob, key=AUTH_KEY):
    """返回 (ok: bool, msg: str)"""
    try:
        raw = base64.b64decode(blob.strip(), validate=True)
    except Exception:
        return False, "授权文件不是合法的 base64 编码"
    if len(raw) < _MAC_LEN + 1:
        return False, "授权文件长度异常(可能被截断或篡改)"
    enc, mac = raw[:-_MAC_LEN], raw[-_MAC_LEN:]
    dk = _derive(key)
    if not hmac.compare_digest(mac, _sign(enc, dk)):
        return False, "授权文件签名校验失败(可能被篡改)"
    try:
        doc = json.loads(_xor(enc, dk[:32]).decode("utf-8"))
    except Exception:
        return False, "授权文件解密失败(可能密钥不匹配或被破坏)"
    exp = doc.get("expire")
    if not exp:
        return False, "授权文件缺少到期字段"
    try:
        ed = datetime.date.fromisoformat(exp)
    except Exception:
        return False, "授权到期日期格式错误: %s" % exp
    today = datetime.date.today()
    if today > ed:
        return False, "授权已过期 (到期 %s, 今天 %s)" % (exp, today.isoformat())
    remain = (ed - today).days
    return True, "授权有效 (到期 %s, 剩余 %d 天)" % (exp, remain)


def _default_license_path():
    """默认授权文件路径: 优先 sys.argv[0] 所在目录(适配 Nuitka onefile),
    回退 __file__ 目录。两者都找不到文件时返回首个候选目录下的 license.dat。"""
    cands = []
    if getattr(sys, "argv", None) and sys.argv:
        try:
            cands.append(os.path.dirname(os.path.abspath(sys.argv[0])))
        except Exception:
            pass
    try:
        cands.append(os.path.dirname(os.path.abspath(__file__)))
    except Exception:
        pass
    for d in cands:
        p = os.path.join(d, "license.dat")
        if os.path.isfile(p):
            return p
    return os.path.join(cands[0], "license.dat") if cands else "license.dat"


def check_license(license_path=None):
    """对外校验入口: 返回 (ok, msg)。
    license_path 为 None 时自动查找 license.dat。"""
    if license_path is None:
        license_path = _default_license_path()
    if not os.path.isfile(license_path):
        return False, ("未找到授权文件: %s\n"
                       "  - 请用【授权包 license_pkg】里的 index.html 授权生成器 生成,\n"
                       "    并放到此处(或与二进制同目录)" % license_path)
    try:
        with open(license_path, "r", encoding="utf-8") as f:
            blob = f.read()
    except Exception as e:
        return False, "读取授权文件失败: %s" % e
    return verify_license(blob)


def _cli():
    import argparse
    p = argparse.ArgumentParser(description="FTP Puller 授权生成/校验工具")
    sub = p.add_subparsers(dest="cmd")
    mk = sub.add_parser("make", help="生成授权(打印到屏幕)")
    mk.add_argument("expire", help="到期日 YYYY-MM-DD")
    mk.add_argument("--issued", default=None, help="签发日 YYYY-MM-DD (默认今天)")
    ck = sub.add_parser("check", help="校验授权文件")
    ck.add_argument("path", help="license.dat 路径")
    args = p.parse_args()
    if args.cmd == "make":
        print(make_license(args.expire, args.issued))
    elif args.cmd == "check":
        ok, msg = check_license(args.path)
        print(("OK: " if ok else "FAIL: ") + msg)
        sys.exit(0 if ok else 1)
    else:
        p.print_help()


if __name__ == "__main__":
    _cli()
