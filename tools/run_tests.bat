@echo off
REM Lance les tests en mode headless (sans fenetre).
REM Definir GODOT si godot.exe n'est pas dans le PATH :  set GODOT=C:\Outils\Godot\Godot_v4.7-stable_win64.exe
if "%GODOT%"=="" set GODOT=godot
cd /d "%~dp0\.."
"%GODOT%" --headless --path . --import >nul 2>&1
echo --- Tests unitaires (regles D&D, donnees) ---
"%GODOT%" --headless --path . -s tests/run_tests.gd
echo.
echo --- Test solo (arene, combat) ---
"%GODOT%" --headless --path . res://tests/net_smoke.tscn 2>nul | findstr /C:"[solo]" /C:"==="
echo.
echo --- Test reseau : hote + client sur 127.0.0.1 ---
start "hote" /B "%GODOT%" --headless --path . res://tests/net_smoke.tscn -- --host > tests\_host.log 2>&1
timeout /t 2 >nul
"%GODOT%" --headless --path . res://tests/net_smoke.tscn -- --join 127.0.0.1 2>nul | findstr /C:"[client]" /C:"==="
timeout /t 2 >nul
findstr /C:"[hôte]" /C:"[hote]" /C:"===" tests\_host.log
pause
