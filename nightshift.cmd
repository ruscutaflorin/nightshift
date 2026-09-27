@echo off
rem Lets you type `nightshift <command>` from cmd/PowerShell once this folder is on PATH.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nightshift.ps1" %*
