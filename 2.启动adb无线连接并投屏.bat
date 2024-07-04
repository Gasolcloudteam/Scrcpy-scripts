@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title adb无线连接并投屏

echo. 如果您是初次使用无线连接或者清除了相关凭证，请重新运行"有线下配置无线调试"脚本，并在完成后使用本无线连接脚本！

echo. 完成后首次配对后再使用无线功能！

echo. --by 叶玖洛·星尘 作者博客:https://blog.xingchencloud.top/

echo. 

set ADB_PATH=%~dp0adb.exe
set SCRCPY_PATH=%~dp0scrcpy.exe

set /p device_ip_port=请输入安卓无线调试IP:端口:

echo 正在尝试连接到设备 %device_ip_port%...

:: 运行 adb connect 并捕获输出
set connect_output=""
for /f "delims=" %%i in ('%ADB_PATH% connect %device_ip_port%') do (
    set "connect_output=%%i"
)

echo %connect_output%

:: 检查连接输出是否包含 "connected to"
echo %connect_output% | findstr /c:"connected to %device_ip_port%" >nul
if %errorlevel%==0 (
    echo 成功连接到无线调试设备！
    echo 正在启动scrcpy投屏功能...
    %SCRCPY_PATH% -s %device_ip_port%
) else (
    echo 无法连接到安卓无线调试，请检查设备相关设置是否正确！
)

endlocal
pause
