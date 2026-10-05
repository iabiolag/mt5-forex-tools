@echo off
rem Double-click for the daily SL-TP tool on your FTMO challenge (FTMO's MT5 must be open).
rem Lot sizes respect the FTMO daily / max loss limits. Rules come from settings_ftmo.bat.
if exist "%~dp0settings_ftmo.bat" (call "%~dp0settings_ftmo.bat") else (call "%~dp0settings_ftmo.example.bat")
python "%~dp0daily_range.py" %PAIRS% %SL_ARGS% --risk %RISK% --max-trades %MAX_TRADES% --max-loss %MAX_DAY_LOSS% --max-losses %MAX_LOSSES% --max-week-loss %MAX_WEEK_LOSS% --max-month-loss %MAX_MONTH_LOSS% --floor %FLOOR% --max-lot %MAX_LOT% --max-open-risk 2 --prop --prop-initial %PROP_INITIAL% --prop-daily %PROP_DAILY% --prop-max %PROP_MAX% --prop-target %PROP_TARGET% --prop-buffer %PROP_BUFFER% --commission %COMMISSION% --terminal "%TERMINAL%" %*
pause
