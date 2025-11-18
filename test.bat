@echo off

set ODIN_BIN=odin\odin.exe
set ODIN_ROOT=odin

%ODIN_BIN% test source
IF %ERRORLEVEL% NEQ 0 exit /b 1
