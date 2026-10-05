@echo off
rem Double-click to open the FTMO dashboard in your browser (FTMO's MT5 must be open).
rem Runs on port 8766, so it can be open next to the normal dashboard (8765).
if exist "%~dp0settings_ftmo.bat" (call "%~dp0settings_ftmo.bat") else (call "%~dp0settings_ftmo.example.bat")
python "%~dp0dashboard.py" %SL_ARGS% --risk %RISK% --max-trades %MAX_TRADES% --max-loss %MAX_DAY_LOSS% --max-losses %MAX_LOSSES% --max-week-loss %MAX_WEEK_LOSS% --max-month-loss %MAX_MONTH_LOSS% --floor %FLOOR% --max-lot %MAX_LOT% --pairs %PAIRS% --max-open %MAX_OPEN% --max-open-risk 2 --port 8766 --prop --prop-initial %PROP_INITIAL% --prop-daily %PROP_DAILY% --prop-max %PROP_MAX% --prop-target %PROP_TARGET% --prop-buffer %PROP_BUFFER% --commission %COMMISSION% --terminal "%TERMINAL%" %*
pause
