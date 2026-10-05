@echo off
rem Rules for the FTMO (prop firm) launchers: ftmo.bat, ftmo_dashboard.bat, ftmo_pnl.bat.
rem Copy this file to settings_ftmo.bat (git-ignored) and change the values to your challenge.
rem If settings_ftmo.bat does not exist, the FTMO launchers use these values.

rem The FTMO MT5 terminal (the tools must not read your other broker's account by mistake)
set "TERMINAL=C:\Program Files\FTMO Global Markets MT5 Terminal\terminal64.exe"
rem FTMO 1-Step objectives, %% of the initial capital (0 = take the first deposit)
set "PROP_INITIAL=0"
set "PROP_DAILY=3"
set "PROP_MAX=10"
set "PROP_TARGET=10"
rem Keep this %% of the initial capital unused above both FTMO loss limits (slippage, gaps, spread)
set "PROP_BUFFER=1"
rem Commission per 1.00 lot, open + close (check it on your first closed trade in MT5 History)
set "COMMISSION=5"

rem SL/TP: 2x / 4x the typical H4 candle
set "SL_ARGS=--sl-tf H4 --sl 2 --tp 4"
rem Risk per trade, %% of the INITIAL capital (1%% of $10,000 = $100). Halved automatically when
rem you are within half of the max loss, and cut further if the FTMO limits are close.
set "RISK=1"
rem Your own stop rules - tighter than FTMO's, so you stop BEFORE their limits are near
set "MAX_TRADES=2"
set "MAX_DAY_LOSS=2"
set "MAX_LOSSES=2"
set "MAX_WEEK_LOSS=4"
set "MAX_MONTH_LOSS=0"
set "FLOOR=0"
rem Pairs your plan allows, biggest lot (0 = no cap), max trades open at once
set "PAIRS=EURUSD GBPUSD USDJPY AUDUSD EURJPY"
set "MAX_LOT=0"
set "MAX_OPEN=2"
