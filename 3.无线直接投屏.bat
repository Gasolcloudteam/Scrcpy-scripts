@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title 直接投屏
echo. 请确定您的设备无线调试仍然和电脑保持配对状态，否则无法直接使用本功能！

echo. --by 叶玖洛星尘 作者博客:https://blog.xingchencloud.top/

echo. 

scrcpy.exe --pause-on-exit=if-error %*
