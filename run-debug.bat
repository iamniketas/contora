@echo off
cd /d "%~dp0"

set EXE=src\AudioRecorder.App\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\Contora.exe

if not exist "%EXE%" (
    echo [build] Debug binary not found, building...
    dotnet build src\AudioRecorder.App\AudioRecorder.csproj -c Debug -p:Platform=x64 -v quiet
)

echo [launch] %~dp0%EXE%
start "" "%~dp0%EXE%"
