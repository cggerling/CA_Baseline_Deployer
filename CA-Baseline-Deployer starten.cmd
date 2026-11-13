@echo off
rem Startet die Weboberflaeche per Doppelklick. Braucht PowerShell 7 (pwsh).
cd /d "%~dp0"
where pwsh >nul 2>nul
if errorlevel 1 (
  echo.
  echo PowerShell 7 ist auf diesem Rechner nicht installiert.
  echo Der Browser oeffnet jetzt die Downloadseite von Microsoft.
  echo Installier PowerShell 7 und starte diese Datei danach noch einmal.
  echo.
  start "" "https://aka.ms/powershell-release?tag=stable"
  pause
  exit /b 1
)
rem Die Ausfuehrungsrichtlinie gilt nur fuer diesen Prozess, damit heruntergeladene Skripte laufen
pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0Start-CABaselineGui.ps1"
if errorlevel 1 pause
