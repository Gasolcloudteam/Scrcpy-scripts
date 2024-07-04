@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: 设置ADB路径
set ADB_PATH=%~dp0adb.exe

:: 执行adb tcpip 5555命令
%ADB_PATH% tcpip 5555

:: 显示执行完毕
echo 执行完毕

:: 保持命令行终端打开
pause

endlocal
