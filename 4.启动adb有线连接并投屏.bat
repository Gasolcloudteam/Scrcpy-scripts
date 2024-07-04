@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title adb有线连接并投屏

echo. 请确定您已打开开发者选项的USB调试功能，并数据线连接好手机。

echo. --by 叶玖洛星尘 作者博客:https://blog.xingchencloud.top/

echo. 

set ADB_PATH=%~dp0adb.exe
set SCRCPY_PATH=%~dp0scrcpy.exe

echo 连接手机中...
adb start-server

set timeout=5
set /a start_time=%time:~0,2%*3600 + %time:~3,2%*60 + %time:~6,2%
set connected=0

:wait_for_device
adb get-state 1>nul 2>nul
if %errorlevel% equ 0 (
    set connected=1
    goto device_connected
)
set /a current_time=%time:~0,2%*3600 + %time:~3,2%*60 + %time:~6,2%
set /a elapsed_time=current_time-start_time
if %elapsed_time% geq %timeout% (
    echo 连接超时！尝试与设备连失败，请检查开发者选项和USB调试功能是否开启。
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait_for_device

:device_connected
echo 手机已连接，启动scrcpy投屏...
scrcpy
if %errorlevel% neq 0 (
    echo scrcpy启动失败，请确保scrcpy已经正确安装并添加到系统PATH。
    pause
    exit /b 1
)
echo 操作完成
pause