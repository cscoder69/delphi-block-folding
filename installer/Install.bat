@echo off
rem CS.Coder - Block Folding: installs the plugin in every Delphi (11, 12, 13) found.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlockFoldingSetup.ps1" -Action install
echo.
pause
