@echo off
REM Double-click this for a LIVE, self-updating progress window (refreshes every 15s).
REM Close the window or press Ctrl+C to stop.
powershell -ExecutionPolicy Bypass -File "%~dp0progress.ps1" -Watch
