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

where git >nul 2>&1 || (
    echo  !! Git n'est pas installe : https://git-scm.com/download/win
    echo     On lance le jeu sans mise a jour.
    goto :launch
)
if not exist ".git" (
    echo  Ce dossier vient d'un ZIP : on le relie a GitHub pour les mises a jour...
    git init -q
    git remote add origin https://github.com/Ryus4ki/ActionRPG.git
    git fetch -q origin
    git checkout -q -B main origin/main
    git reset -q --hard origin/main
)
echo [1/3] Recuperation des mises a jour...
git pull --ff-only
if errorlevel 1 (
    echo.
    echo  !! La mise a jour a echoue ^(pas de reseau ?^).
    echo     On lance quand meme la version presente sur ce PC.
    echo.
)

:launch
echo [2/3] Verification de Godot...
set "EXE="
if defined GODOT if exist "%GODOT%" set "EXE=%GODOT%"
if not defined EXE for %%F in ("%~dp0godot*.exe" "%~dp0Godot*.exe") do if not defined EXE set "EXE=%%~fF"
if not defined EXE where godot >nul 2>&1 && set "EXE=godot"
if not defined EXE (
    echo.
    echo  !! Godot introuvable. Copie l'executable Godot 4.7 dans ce dossier
    echo     ^(un fichier qui commence par godot et finit par .exe^),
    echo     ou definis la variable d'environnement GODOT vers son chemin.
    pause
    exit /b 1
)
REM Import du projet (cache des classes, modeles 3D) : necessaire apres un clone
REM ou une mise a jour, sinon les scripts ne compilent pas hors de l'editeur.
set "CUR="
for /f %%H in ('git rev-parse HEAD 2^>nul') do set "CUR=%%H"
set "LAST="
if exist ".godot\last_import.txt" set /p LAST=<.godot\last_import.txt
if not exist ".godot\global_script_class_cache.cfg" set "LAST="
if not "%CUR%"=="%LAST%" (
    echo [2/3] Import du projet ^(premiere fois ou mise a jour, 10-30 s^)...
    "%EXE%" --headless --path "%~dp0." --import >nul 2>&1
    if not exist ".godot" mkdir ".godot"
    >.godot\last_import.txt echo %CUR%
)
echo [3/3] Lancement du jeu...
start "" "%EXE%" --path "%~dp0."
endlocal
