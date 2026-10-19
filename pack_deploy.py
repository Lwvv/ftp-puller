# 打包"部署包": 只收编译后的二进制 + 配置/脚本/依赖, 排除明文源码/编译脚本/密钥
import zipfile, os, sys

ROOT = 'C:/Users/LW/WorkBuddy/2026-10-10-18-58-03/ftp_puller_pkg'
OUT  = 'C:/Users/LW/WorkBuddy/2026-10-10-18-58-03/ftp_puller_pkg.zip'

# 明确排除的开发/源码文件(不进部署包, 避免泄露明文源码与密钥)
EXCLUDE_FILES = {
    'ftp_puller_verify.py',   # 明文主源码
    'license_core.py',        # 含授权密钥的明文
    'build_linux.sh',         # 编译脚本(需源码)
    'ftp_puller.service',     # 旧 service 模板(install.sh 现动态生成)
}

# 解压后的顶层目录名(让 zip 解压即得同名文件夹, 而非散落文件)
TOP_DIR = 'ftp_puller_pkg'

if __name__ == '__main__':
    if not os.path.exists(os.path.join(ROOT, 'ftp_puller')):
        print('[警告] 未找到编译二进制 ftp_puller, 部署包将不含二进制(安装会回退源码, 但源码已排除)!')
    if os.path.exists(OUT):
        os.remove(OUT)
    n = 0
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for dp, dn, fn in os.walk(ROOT):
            if '__pycache__' in dp:
                continue
            if os.path.basename(dp) == 'logs':   # 运行期日志目录, 不随包发布
                continue
            for f in fn:
                if f.endswith('.pyc'):
                    continue
                if f in EXCLUDE_FILES:
                    continue
                p = os.path.join(dp, f)
                arcname = os.path.join(TOP_DIR, os.path.relpath(p, ROOT))
                z.write(p, arcname)
                n += 1
    print('部署包 %s : %d 个文件, %d 字节 (解压到 %s/)' % (OUT, n, os.path.getsize(OUT), TOP_DIR))
    with zipfile.ZipFile(OUT) as z:
        for name in z.namelist():
            print('   ', name)
