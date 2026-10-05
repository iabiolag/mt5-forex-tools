@echo off
rem Double-click for your weekly report card (MT5 must be open).
rem Grades you against the rules in settings.bat.
set "TERMINAL=" & set "COMMISSION=0"
if exist "%~dp0settings.bat" (call "%~dp0settings.bat") else (call "%~dp0settings.example.bat")
python "%~dp0weekly_report.py" --risk %RISK% --max-trades %MAX_TRADES% --max-loss %MAX_DAY_LOSS% --max-losses %MAX_LOSSES% --pairs %PAIRS% --max-lot %MAX_LOT% --max-open %MAX_OPEN% --floor %FLOOR% --terminal "%TERMINAL%" %*
pause
