@echo off
rem Double-click to open the dashboard in your browser (MT5 must be open).
rem Your rules come from settings.bat. Keep this window open while you use the page.
set "TERMINAL=" & set "COMMISSION=0"
if exist "%~dp0settings.bat" (call "%~dp0settings.bat") else (call "%~dp0settings.example.bat")
python "%~dp0dashboard.py" %SL_ARGS% --risk %RISK% --max-trades %MAX_TRADES% --max-loss %MAX_DAY_LOSS% --max-losses %MAX_LOSSES% --max-week-loss %MAX_WEEK_LOSS% --max-month-loss %MAX_MONTH_LOSS% --floor %FLOOR% --pairs %PAIRS% --max-lot %MAX_LOT% --max-open %MAX_OPEN% --commission %COMMISSION% --terminal "%TERMINAL%" %*
pause
