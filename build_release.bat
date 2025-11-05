@echo off

set OUT_DIR=dist\release
set ODIN_BIN=odin\odin.exe
set ODIN_ROOT=odin
if not exist %OUT_DIR% mkdir %OUT_DIR%

%ODIN_BIN% build source\game.odin -file -o:speed -define:EMBED_ASSETS=true -out:%OUT_DIR%\game.exe
IF %ERRORLEVEL% NEQ 0 exit /b 1

echo RELEASE build created in %OUT_DIR%
