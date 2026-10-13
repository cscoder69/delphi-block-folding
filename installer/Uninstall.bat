@echo off
rem CS.Coder - Block Folding: removes the plugin from every Delphi.
rem Uninstall.bat          keeps your settings
rem Uninstall.bat /data    deletes the settings and the diagnostic log too
if /i "%~1"=="/data" (
  echo This also deletes your Block Folding settings ^(shortcuts, kinds of block, marker text^)
  echo and the diagnostic log. They cannot be recovered.
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlockFoldingSetup.ps1" -Action uninstall -RemoveData
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlockFoldingSetup.ps1" -Action uninstall
)
echo.
pause
