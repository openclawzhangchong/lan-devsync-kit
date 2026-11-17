#!/usr/bin/env python3
"""
DevSyncTray — DevSync 枢纽状态托盘（枢纽机专用）

显示枢纽(Gitea)实时状态：
  绿点 = 服务 RUNNING 且 3300 端口可连（正常服务中）
  黄点 = 启动中 / 服务在但端口未就绪
  红点 = 服务已停止 / 异常
状态变化时弹气泡通知，一眼可知枢纽开没开。

托盘菜单：
  状态行 ｜ 🌐 打开枢纽网页 ｜ ▶ 启动服务 / ■ 停止服务 / 🔄 重启服务
  ｜ 🩺 devsync 体检 ｜ 开机自启 ｜ 退出

服务启停走 UAC 静默提权（要求 ConsentPromptBehaviorAdmin=0，本机已满足）。
打包：python -m PyInstaller --onefile --noconsole --name DevSyncTray devsync_tray.py
"""
import os
import sys
import time
import socket
import subprocess
import tempfile
import threading
import webbrowser
import ctypes
import winreg

import pystray
from PIL import Image, ImageDraw, ImageFont

# ────────────────────────── 常量 ──────────────────────────

APP_NAME = 'DevSyncTray'
APP_VERSION = '1.0.0'
MUTEX_NAME = 'DevSyncTray-Mutex'
SERVICE_NAME = 'DevSyncGitea'
HUB_PORT = 3300
WEB_URL = 'http://192.168.168.199:3300/'
RUN_KEY = r'Software\Microsoft\Windows\CurrentVersion\Run'
DS_BIN = r'E:\devsync\bin'
LOG_FILE = r'E:\devsync\logs\tray.log'

GREEN = (70, 220, 110, 255)
YELLOW = (240, 190, 60, 255)
RED = (255, 82, 82, 255)

# ────────────────────────── 日志 ──────────────────────────

def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(time.strftime('[%Y-%m-%d %H:%M:%S] ') + msg + '\n')
    except Exception:
        pass

# ────────────────────────── 图标 ──────────────────────────

def _font(size):
    for name in ('msyh.ttc', 'msyhbd.ttc', 'simhei.ttf'):
        try:
            return ImageFont.truetype('C:/Windows/Fonts/' + name, size)
        except Exception:
            continue
    return ImageFont.load_default()

def make_icon(dot):
    """品牌图标：青绿渐变圆角方块 + 居中「枢纽」 + 右上角状态点"""
    img = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
    grad = Image.new('RGBA', (64, 64))
    top, bot = (13, 148, 136), (34, 197, 94)   # teal → green
    g = ImageDraw.Draw(grad)
    for y in range(64):
        t = y / 63
        g.line([(0, y), (63, y)],
               fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,))
    mask = Image.new('L', (64, 64), 0)
    ImageDraw.Draw(mask).rounded_rectangle((3, 3, 61, 61), radius=15, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.text((30, 30), '枢纽', font=_font(22), fill='white', anchor='mm')
    d.ellipse((46, 6, 58, 18), fill=dot)
    return img

# ────────────────────────── 状态探测 ──────────────────────────

state = {'svc': '?', 'port': False, 'label': '检测中…'}
_last_key = None  # 用于状态变化通知

def _query_service():
    """返回服务状态字符串：RUNNING / STOPPED / START_PENDING / ... / NOT_INSTALLED"""
    try:
        p = subprocess.run(['sc', 'query', SERVICE_NAME],
                           capture_output=True, timeout=8)
        out = p.stdout
        if b'RUNNING' in out:
            return 'RUNNING'
        if b'STOPPED' in out:
            return 'STOPPED'
        if b'PENDING' in out:
            return 'PENDING'
        if b'1060' in out or p.returncode == 1060:
            return 'NOT_INSTALLED'
        return 'UNKNOWN'
    except Exception as e:
        log(f'query service error: {e}')
        return 'UNKNOWN'

def _check_port():
    try:
        with socket.create_connection(('127.0.0.1', HUB_PORT), timeout=1.5):
            return True
    except Exception:
        return False

def _eval_state():
    """综合服务状态与端口连通，返回 (色点, 短标签, 状态key)"""
    svc = _query_service()
    port = _check_port()
    if svc == 'RUNNING' and port:
        return GREEN, '运行中（服务正常，端口 %d 可连）' % HUB_PORT, 'ok'
    if svc == 'RUNNING' and not port:
        return YELLOW, '启动中（服务在跑，端口未就绪）', 'warming'
    if svc == 'PENDING':
        return YELLOW, '启动中…', 'pending'
    if svc == 'STOPPED':
        return RED, '已停止', 'stopped'
    if svc == 'NOT_INSTALLED':
        return RED, '服务未安装（本机不是枢纽机？）', 'noinstall'
    return RED, '状态未知', 'unknown'

def poll_loop(icon):
    global _last_key
    while True:
        try:
            dot, label, key = _eval_state()
            changed = key != _last_key
            state['label'] = label
            if changed:
                log(f'state -> {key}: {label}')
                _last_key = key
                if key == 'ok' and state.get('prev_key') not in (None, 'ok'):
                    icon.notify('枢纽已就绪 ✓ 代码接力可用', 'DevSync 枢纽')
                elif key in ('stopped', 'noinstall') and state.get('prev_key') == 'ok':
                    icon.notify('⚠ 枢纽已停止！换机接力暂不可用', 'DevSync 枢纽')
                state['prev_key'] = key
            icon.icon = make_icon(dot)
            icon.title = f'DevSync 枢纽 · {label}'
            icon.update_menu()
        except Exception as e:
            log(f'poll error: {e}')
        time.sleep(3)

# ────────────────────────── 动作 ──────────────────────────

def act_open_web(icon, item):
    webbrowser.open(WEB_URL)

def _svc_via_uac(powershell_statement):
    """把语句写成 ASCII 临时 ps1，走 Start-Process -Verb RunAs 静默提权执行"""
    ps1 = os.path.join(tempfile.gettempdir(), 'devsync-svc-action.ps1')
    script = (
        "$ErrorActionPreference='Continue'\n"
        f"{powershell_statement}\n"
        "exit 0\n"
    )
    with open(ps1, 'w', encoding='ascii') as f:
        f.write(script)
    subprocess.Popen(
        ['powershell', '-NoProfile', '-Command',
         f'Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '
         f"'-NoProfile','-ExecutionPolicy','Bypass','-File','{ps1}'"],
        creationflags=subprocess.CREATE_NO_WINDOW)
    log(f'uac action dispatched: {powershell_statement}')

def act_start(icon, item):
    icon.notify('正在启动枢纽服务…', 'DevSync')
    _svc_via_uac(f'Start-Service -Name "{SERVICE_NAME}"')

def act_stop(icon, item):
    icon.notify('正在停止枢纽服务…', 'DevSync')
    _svc_via_uac(f'Stop-Service -Name "{SERVICE_NAME}" -Force')

def act_restart(icon, item):
    icon.notify('正在重启枢纽服务…', 'DevSync')
    _svc_via_uac(f'Restart-Service -Name "{SERVICE_NAME}" -Force')

def act_doctor(icon, item):
    icon.notify('正在运行 devsync doctor…', 'DevSync')
    def run():
        try:
            p = subprocess.run(
                ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', os.path.join(DS_BIN, 'devsync.ps1'), 'doctor'],
                capture_output=True, timeout=120)
            out = (p.stdout or b'').decode('utf-8', 'ignore')
            fail = p.returncode != 0
            brief = '体检全部通过 ✓' if not fail else '有问题，点菜单「体检详情」'
            if fail:
                tail = [l for l in out.splitlines() if ('✘' in l)][:3]
                brief = ' | '.join(tail) or '体检未通过'
            icon.notify(brief, 'DevSync 枢纽体检')
            log(f'doctor rc={p.returncode}')
        except Exception as e:
            log(f'doctor error: {e}')
            icon.notify(f'体检执行失败: {e}', 'DevSync 枢纽体检')
    threading.Thread(target=run, daemon=True).start()

# ────────────────────────── 开机自启（HKCU Run） ──────────────────────────

def _self_exe():
    return os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__)

def autostart_enabled():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP_NAME)
            return True
    except FileNotFoundError:
        return False
    except Exception:
        return False

def toggle_autostart(icon, item):
    exe = _self_exe()
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_WRITE) as k:
        if autostart_enabled():
            winreg.DeleteValue(k, APP_NAME)
            icon.notify('已关闭开机自启', APP_NAME)
        else:
            winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ, f'"{exe}"')
            icon.notify('已开启开机自启（下次开机随服务一起就绪）', APP_NAME)
    icon.update_menu()

# ────────────────────────── 菜单 ──────────────────────────

def menu_status(item):
    return f'枢纽状态：{state["label"]}'

def menu_autostart_checked(item):
    return autostart_enabled()

def main():
    # 单实例
    ctypes.windll.kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if ctypes.windll.kernel32.GetLastError() == 183:
        log('another instance running, exit')
        sys.exit(0)
    log(f'{APP_NAME} v{APP_VERSION} started')

    menu = pystray.Menu(
        pystray.MenuItem(lambda item: menu_status(item), None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem('🌐 打开枢纽网页', act_open_web, default=True),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem('▶ 启动服务', act_start),
        pystray.MenuItem('■ 停止服务', act_stop),
        pystray.MenuItem('🔄 重启服务', act_restart),
        pystray.MenuItem('🩺 devsync 体检', act_doctor),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem('开机自启', toggle_autostart, checked=menu_autostart_checked),
        pystray.MenuItem('退出', lambda icon, item: icon.stop()),
    )
    icon = pystray.Icon(APP_NAME, make_icon(YELLOW),
                        'DevSync 枢纽 · 检测中…', menu)
    threading.Thread(target=poll_loop, args=(icon,), daemon=True).start()
    icon.run()

if __name__ == '__main__':
    main()
