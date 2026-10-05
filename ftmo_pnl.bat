@echo off
rem Double-click for the profit/loss by day, week and month of your FTMO account.
if exist "%~dp0settings_ftmo.bat" (call "%~dp0settings_ftmo.bat") else (call "%~dp0settings_ftmo.example.bat")
python "%~dp0pnl_report.py" --terminal "%TERMINAL%" %*
pause
