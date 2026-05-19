FROM ghcr.io/chrysoljq/aistudio-api:latest

USER root

# ============================================================
# 基础工具
# ============================================================
RUN apt-get update && apt-get install -y \
    nginx \
    openssl \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# setproctitle：修改 Python 进程的 /proc/PID/cmdline
# camoufox[geoip]：安装包本体（含 GeoIP 数据库支持）
# playwright install-deps firefox：安装 Firefox 运行时系统依赖（apt 层）
# playwright install firefox：下载 Playwright 管理的 Firefox 二进制
# camoufox fetch：下载 Camoufox 专用浏览器二进制（镜像会因此增大）
RUN pip3 install --no-cache-dir setproctitle "camoufox[geoip]" && \
    python3 -m playwright install-deps firefox && \
    python3 -m playwright install firefox && \
    python3 -m camoufox fetch

# Cloudflare Tunnel 辅助程序（重命名避免特征）
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd

# ============================================================
# proc_shim.py — 启动时劫持 Python 进程名
# 内嵌写入，无需额外 COPY 文件
# ============================================================
RUN cat > /usr/local/bin/proc_shim.py << 'SHIMEOF'
#!/usr/bin/env python3
"""
proc_shim.py
替代 python3 直接运行 main.py，在任何业务代码加载前完成进程名伪装。
伪装覆盖三个层面：
  1. /proc/PID/comm     (ps、top、htop 看到的短名)  — prctl PR_SET_NAME
  2. /proc/PID/cmdline  (ps aux COMMAND 完整列)     — setproctitle
  3. sys.argv[0]        (Python 内部)
"""
import sys, os, ctypes

FAKE_NAME = "dbus-daemon"   # ← 按需修改

# --- 1. prctl PR_SET_NAME (最多15字节，影响 comm) ---
try:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(15, FAKE_NAME.encode()[:15], 0, 0, 0)
except Exception:
    pass

# --- 2. setproctitle (影响 cmdline) ---
try:
    import setproctitle
    setproctitle.setproctitle(FAKE_NAME)
except ImportError:
    pass

# --- 3. 透传 argv 并 exec main.py ---
app_dir = "/app"
main_py = os.path.join(app_dir, "main.py")
sys.argv[0] = main_py
os.chdir(app_dir)

with open(main_py, "rb") as _f:
    _code = compile(_f.read(), main_py, "exec")

exec(_code, {"__file__": main_py, "__name__": "__main__", "__spec__": None})
SHIMEOF

RUN chmod +x /usr/local/bin/proc_shim.py

# ============================================================
# 浏览器二进制进程名伪装
# 覆盖：Camoufox / Playwright(firefox+chromium+webkit) / CloakBrowser
# 原理：将真实二进制备份为 xxx.real，原路径替换为 exec -a 的 shell wrapper
# ============================================================
RUN python3 - << 'PYEOF'
import os, shutil, glob, stat

FAKE_BROWSER = "Xwayland"       # 浏览器进程伪装名
FAKE_NODE    = "dbus-launch"    # Node 进程伪装名

def is_elf_or_script(path):
    """判断是否是真实的二进制/脚本（非我们自己写的 wrapper）"""
    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
        # 我们的 wrapper 以 #!/bin/sh 开头，跳过避免二次封装
        if magic[:2] == b'#!':
            with open(path, 'r', errors='replace') as f:
                first = f.readline()
            if 'exec -a' in first or 'exec -a' in open(path).read(256):
                return False   # 已经是我们的 wrapper
        return True
    except Exception:
        return False

def wrap(real_path, fake_name):
    real_path = os.path.realpath(real_path)
    if not os.path.isfile(real_path):
        return
    if not os.access(real_path, os.X_OK):
        return
    if not is_elf_or_script(real_path):
        print(f"  [skip] already wrapped: {real_path}")
        return
    backup = real_path + ".real"
    if not os.path.exists(backup):
        shutil.copy2(real_path, backup)
        shutil.copymode(real_path, backup)
    wrapper = (
        '#!/bin/sh\n'
        f'exec -a "{fake_name}" "{backup}" "$@"\n'
    )
    with open(real_path, 'w') as f:
        f.write(wrapper)
    os.chmod(real_path, 0o755)
    print(f"  [wrapped] {real_path}  →  argv[0]='{fake_name}'")

targets = set()

# ── Camoufox ─────────────────────────────────────────────────
try:
    import camoufox
    pkg_dir = os.path.dirname(camoufox.__file__)
    for root, dirs, files in os.walk(pkg_dir):
        for fname in files:
            if fname in (
                "firefox", "firefox-bin",
                "camoufox", "camoufox-bin", "camoufox.bin",
            ):
                targets.add(os.path.join(root, fname))
    print(f"  [camoufox] pkg_dir={pkg_dir}, found={len(targets)}")
except Exception as e:
    print(f"  [camoufox] not importable: {e}")

# ── Playwright ────────────────────────────────────────────────
# firefox / chromium / webkit / headless-chromium
playwright_patterns = [
    "/root/.cache/ms-playwright/**/firefox",
    "/root/.cache/ms-playwright/**/firefox-bin",
    "/root/.cache/ms-playwright/**/chrome",
    "/root/.cache/ms-playwright/**/chrome-linux/chrome",
    "/root/.cache/ms-playwright/**/chromium",
    "/root/.cache/ms-playwright/**/chromium-bin",
    "/root/.cache/ms-playwright/**/chromium-*/chrome-linux/chrome",
    "/root/.cache/ms-playwright/**/webkit",
    "/root/.cache/ms-playwright/**/minibrowser",
    "/root/.cache/ms-playwright/**/minibrowser-gtk",
    "/home/**/.cache/ms-playwright/**/firefox",
    "/home/**/.cache/ms-playwright/**/chrome",
    "/home/**/.cache/ms-playwright/**/chromium",
    "/tmp/ms-playwright/**/firefox",
    "/tmp/ms-playwright/**/chrome",
    # playwright installs to app venv sometimes
    "/app/**/.local/share/ms-playwright/**/firefox",
    "/app/**/.local/share/ms-playwright/**/chrome",
]
for pat in playwright_patterns:
    for found in glob.glob(pat, recursive=True):
        targets.add(found)

# Also search globally under known playwright cache root names
for base in ("/root", "/home", "/app"):
    if not os.path.isdir(base):
        continue
    for found in glob.glob(
        os.path.join(base, "**", "ms-playwright", "**", "firefox"),
        recursive=True,
    ):
        targets.add(found)
    for found in glob.glob(
        os.path.join(base, "**", "ms-playwright", "**", "chrome"),
        recursive=True,
    ):
        targets.add(found)

# ── CloakBrowser ─────────────────────────────────────────────
# 方式1: pip 包
try:
    import importlib.util
    spec = importlib.util.find_spec("cloakbrowser")
    if spec:
        pkg_dir = os.path.dirname(spec.origin)
        print(f"  [cloakbrowser] pip pkg_dir={pkg_dir}")
        for root, dirs, files in os.walk(pkg_dir):
            for fname in files:
                fpath = os.path.join(root, fname)
                # 匹配可执行的浏览器二进制
                if os.access(fpath, os.X_OK) and fname in (
                    "chrome", "chromium", "cloakbrowser",
                    "CloakBrowser", "cloak-browser",
                    "chrome-linux", "headless_shell",
                ):
                    targets.add(fpath)
except Exception as e:
    print(f"  [cloakbrowser] pip not found: {e}")

# 方式2: 常见安装路径
cloak_candidates = [
    "/opt/cloakbrowser/cloakbrowser",
    "/opt/cloakbrowser/chrome",
    "/opt/cloakbrowser/CloakBrowser",
    "/opt/CloakBrowser/CloakBrowser",
    "/opt/CloakBrowser/chrome",
    "/usr/bin/cloakbrowser",
    "/usr/local/bin/cloakbrowser",
    "/usr/local/bin/CloakBrowser",
    "/root/.cloakbrowser/cloakbrowser",
    "/root/.cloakbrowser/chrome",
    "/root/.local/share/cloakbrowser/chrome",
    "/app/cloakbrowser/chrome",
    "/app/cloakbrowser/cloakbrowser",
]
for p in cloak_candidates:
    if os.path.isfile(p):
        targets.add(p)
        print(f"  [cloakbrowser] found at {p}")

# 方式3: 在 /app /opt 下递归搜索含 "cloak" 的可执行文件
for search_root in ("/app", "/opt", "/root"):
    if not os.path.isdir(search_root):
        continue
    for root, dirs, files in os.walk(search_root):
        # 跳过太深的目录
        depth = root.replace(search_root, '').count(os.sep)
        if depth > 6:
            dirs.clear()
            continue
        for fname in files:
            if "cloak" in fname.lower():
                fpath = os.path.join(root, fname)
                if os.access(fpath, os.X_OK):
                    targets.add(fpath)
                    print(f"  [cloakbrowser] glob found: {fpath}")

# ── 系统级 fallback ───────────────────────────────────────────
for sys_bin in (
    "/usr/bin/firefox",
    "/usr/bin/firefox-esr",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
):
    if os.path.exists(sys_bin):
        targets.add(sys_bin)

# ── 执行 wrap ─────────────────────────────────────────────────
print(f"\n共发现 {len(targets)} 个目标，开始封装...")
for t in sorted(targets):
    wrap(t, FAKE_BROWSER)

# ── Node ──────────────────────────────────────────────────────
node_path = shutil.which("node")
if node_path:
    wrap(node_path, FAKE_NODE)
    # 同时 wrap npx / node 的真实路径
    for extra in ("/usr/bin/node", "/usr/local/bin/node"):
        if os.path.isfile(extra) and extra != node_path:
            wrap(extra, FAKE_NODE)
else:
    print("  [node] not found in PATH")

print("\n进程名伪装完成。")
PYEOF

# ============================================================
# Nginx 配置
# ============================================================
COPY main.conf /etc/nginx/conf.d/main.conf
RUN rm -f /etc/nginx/conf.d/default.conf && \
    rm -rf /etc/nginx/sites-enabled/* && \
    rm -rf /etc/nginx/sites-available/*
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# ============================================================
# 启动脚本 & 静态文件
# ============================================================
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

RUN chmod +x /entrypoint.sh && \
    sed -i 's/\r$//' /entrypoint.sh && \
    sed -i 's/\r$//' /usr/local/bin/proc_shim.py

EXPOSE 8080

ENV DD_DM="" \
    DD_DD="" \
    PORT=8080 \
    HOST=0.0.0.0 \
    AISTUDIO_BROWSER_PYTHON=/usr/local/bin/proc_shim.py \
    AISTUDIO_BROWSER=camoufox

CMD ["/entrypoint.sh"]