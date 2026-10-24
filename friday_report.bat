@echo off
rem Weekly report for your main + FTMO accounts in the browser (runs by itself every Friday night,
rem see README). Pages are saved in the reports folder.
python "%~dp0friday_report.py" %*
if errorlevel 1 pause
