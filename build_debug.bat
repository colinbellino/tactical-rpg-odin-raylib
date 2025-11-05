@echo off

set OUT_DIR=dist\debug
set ODIN_BIN=odin\odin.exe
set ODIN_ROOT=odin
if not exist %OUT_DIR% mkdir %OUT_DIR%

%ODIN_BIN% build source\game.odin -file -debug -out:%OUT_DIR%\game.exe
IF %ERRORLEVEL% NEQ 0 exit /b 1

echo DEBUG build created in %OUT_DIR%
