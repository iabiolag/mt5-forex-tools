@echo off
rem Double-click to see today's per-pair daily range and suggested SL/TP (MT5 must be open).
rem Your rules come from settings.bat (copy settings.example.bat to create it).
if exist "%~dp0settings.bat" (call "%~dp0settings.bat") else (call "%~dp0settings.example.bat")
python "%~dp0daily_range.py" %SL_ARGS% --risk %RISK% --max-trades %MAX_TRADES% --max-loss %MAX_DAY_LOSS% --max-losses %MAX_LOSSES% --max-week-loss %MAX_WEEK_LOSS% --max-month-loss %MAX_MONTH_LOSS% --floor %FLOOR% --max-lot %MAX_LOT% %*
pause
