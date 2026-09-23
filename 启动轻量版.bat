@echo off
setlocal
cd /d "%~dp0"
dotnet run --project windows-lite\GiWifiLite.csproj
