@echo off
REM Lance les tests unitaires en mode headless.
REM Définir GODOT si godot.exe n'est pas dans le PATH :  set GODOT=C:\Outils\Godot\Godot_v4.7-stable_win64.exe
if "%GODOT%"=="" set GODOT=godot
cd /d "%~dp0\.."
"%GODOT%" --headless --path . --import >nul 2>&1
"%GODOT%" --headless --path . -s tests/run_tests.gd
pause
