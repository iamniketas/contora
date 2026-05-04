@echo off
cd /d "%~dp0"

set EXE=src\AudioRecorder.App\bin\Debug\net8.0-windows10.0.19041.0\Contora.exe

if not exist "%EXE%" (
    echo [build] Debug binary not found, building...
    dotnet build src\AudioRecorder.App\AudioRecorder.csproj -c Debug -v quiet
)

echo [launch] %~dp0%EXE%
start "" "%~dp0%EXE%"
