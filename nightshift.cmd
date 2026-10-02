@echo off
rem `nightshift <command>` from cmd or PowerShell once this folder is on PATH (nightshift install).
rem The engine lives in lib\cli.ps1, so PowerShell never tries to run a .ps1 here under your execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\cli.ps1" %*
