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
echo [1/2] Recuperation des mises a jour...
git pull --ff-only
if errorlevel 1 (
    echo.
    echo  !! La mise a jour a echoue ^(pas de reseau ?^).
    echo     On lance quand meme la version presente sur ce PC.
    echo.
)

:launch
echo [2/2] Lancement du jeu...
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
start "" "%EXE%" --path "%~dp0."
endlocal
