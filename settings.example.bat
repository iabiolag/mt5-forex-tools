@echo off
rem Your trading rules, used by every .bat launcher. Copy this file to settings.bat
rem (settings.bat is private: git-ignored) and change the values to match your own plan.
rem If settings.bat does not exist, the launchers use these example values.

rem SL/TP: 2x / 4x the typical H4 candle. Or e.g. --sl 0.7 --tp 1 for multiples of the typical day.
set "SL_ARGS=--sl-tf H4 --sl 2 --tp 4"
rem Risk per trade, %% of the account (lot sizes are built from it)
set "RISK=1"
rem Stop rules: max new trades a day, stop at this %% loss for the day / week / month,
rem stop after this many losses in a row (0 = off for week / month)
set "MAX_TRADES=3"
set "MAX_DAY_LOSS=3"
set "MAX_LOSSES=3"
set "MAX_WEEK_LOSS=5"
set "MAX_MONTH_LOSS=10"
rem Stop live trading at/below this balance (0 = off)
set "FLOOR=0"
rem Pairs your plan allows, space-separated (empty = any pair), e.g. set "PAIRS=EURUSD GBPUSD USDJPY"
set "PAIRS="
rem Biggest lot your plan allows (0 = no cap) and max trades open at once
set "MAX_LOT=0"
set "MAX_OPEN=3"
rem Which MT5 to read when more than one terminal is open (empty = the one that is open), e.g.
rem set "TERMINAL=C:\Program Files\MetaTrader 5\terminal64.exe"
set "TERMINAL="
rem Commission per 1.00 lot, open + close, in account money (0 = none; added to "Loss if SL hit")
set "COMMISSION=0"
