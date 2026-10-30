@echo off
REM ============================================================
REM  ActionRPG - mise a jour + lancement du jeu (sans l'editeur)
REM  1) git pull : recupere la derniere version publiee sur GitHub
REM  2) lance Godot directement sur le jeu
REM  Godot est cherche : variable GODOT, puis godot*.exe a cote de
REM  ce fichier, puis dans le PATH.
REM ============================================================
setlocal
cd /d "%~dp0"

echo [1/2] Recuperation des mises a jour...
git pull --ff-only
if errorlevel 1 (
    echo.
    echo  !! La mise a jour a echoue (pas de reseau, ou Git non installe ?).
    echo     On lance quand meme la version presente sur ce PC.
    echo.
)

echo [2/2] Lancement du jeu...
set "EXE="
if defined GODOT if exist "%GODOT%" set "EXE=%GODOT%"
if not defined EXE for %%F in ("%~dp0godot*.exe" "%~dp0Godot*.exe") do if not defined EXE set "EXE=%%~fF"
if not defined EXE where godot >nul 2>&1 && set "EXE=godot"
if not defined EXE (
    echo.
    echo  !! Godot introuvable. Copie Godot_v4.7-stable_win64.exe dans ce dossier,
    echo     ou definis la variable GODOT (ex: set GODOT=C:\Outils\Godot\Godot_v4.7-stable_win64.exe).
    pause
    exit /b 1
)
start "" "%EXE%" --path "%~dp0."
endlocal
