@echo off
rem Double-click for your profit/loss by day, week and month (MT5 must be open).
set "TERMINAL="
if exist "%~dp0settings.bat" (call "%~dp0settings.bat") else (call "%~dp0settings.example.bat")
python "%~dp0pnl_report.py" --terminal "%TERMINAL%" %*
pause
