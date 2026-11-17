@echo off
rem DevSyncTray 打包：python -m PyInstaller 单文件、无控制台
cd /d "%~dp0"
python -m PyInstaller --onefile --noconsole --name DevSyncTray ^
  --distpath dist --workpath build --specpath build ^
  devsync_tray.py
if errorlevel 1 ( echo BUILD FAILED & exit /b 1 )
echo BUILD OK: dist\DevSyncTray.exe
