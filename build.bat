@echo off
rem Shortcut: build.bat [debug|release] is inspecteurtool build.
rem Every other step: odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -- <command> (help lists them).
cd /d "%~dp0"
if not exist build mkdir build
odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- build %*
