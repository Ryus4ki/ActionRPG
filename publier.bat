@echo off
REM ============================================================
REM  ActionRPG - publie la version locale sur GitHub
REM  Usage : publier.bat ["message du commit"]
REM  Sans message, il en demande un (Entree = message par defaut).
REM ============================================================
setlocal
cd /d "%~dp0"

git status --short
echo.
set "MSG=%~1"
if "%MSG%"=="" set /p "MSG=Message du commit (Entree = 'Mise a jour') : "
if "%MSG%"=="" set "MSG=Mise a jour"

git add -A
git commit -m "%MSG%"
if errorlevel 1 (
    echo.
    echo  (rien a commiter, ou erreur ci-dessus) - on tente quand meme le push.
)
git push
if errorlevel 1 (
    echo.
    echo  !! Le push a echoue (pas de reseau ? identification ?).
    pause
    exit /b 1
)
echo.
git status -sb
echo.
echo  Publie sur GitHub. Ton coequipier recevra la mise a jour au prochain jouer.bat.
pause
endlocal
