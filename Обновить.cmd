@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
set "REPO=https://github.com/Game-Feel/SteamPunk.git"
set "BRANCH=main"

rem Работаем из копии во временной папке: обновление может перезаписать этот файл.
if /i not "%~1"=="--run" (
  copy /y "%~f0" "%TEMP%\steampunk-update.cmd" >nul
  call "%TEMP%\steampunk-update.cmd" --run "%~dp0." "%~1" & exit /b
)
set "QUIET="
if /i "%~3"=="--quiet" set "QUIET=1"
cd /d "%~2" || goto fail
title SteamPunk: обновление сборки

call :findgit || goto nogit

tasklist /fi "imagename eq javaw.exe" 2>nul | find /i "javaw.exe" >nul
if not errorlevel 1 if not defined QUIET (
  echo Похоже, запущена Java: игра или лаунчер.
  echo Закрой Minecraft и нажми любую клавишу. Лаунчер можно не закрывать.
  pause >nul
)

if not exist ".git\" (
  echo Первая установка сборки в папку:
  echo   %CD%
  rem Папка mods из архива сборки помечена файлом .minevillagers, её просто обновляем.
  if exist "mods\" if not exist "mods\.minevillagers" (
    set "OLDMODS=mods_old_%RANDOM%"
    ren "mods" "!OLDMODS!" || goto fail
    echo Старая папка mods переименована в !OLDMODS!
  )
  "%GIT%" init -q || goto fail
  "%GIT%" remote add origin "%REPO%" || goto fail
)
rem Репозиторий переезжал: старые папки переключаем на текущий адрес.
"%GIT%" remote set-url origin "%REPO%" || goto fail
"%GIT%" config core.quotepath false
rem Длинные пути библиотек загрузчика не помещаются в лимит Windows в 260 символов.
"%GIT%" config core.longpaths true

echo Скачиваю свежую версию. При первом запуске откроется вход в GitHub.
"%GIT%" fetch -q origin %BRANCH% || goto netfail

rem Неотправленные изменения издателя не трогаем.
set "AHEAD=0"
for /f %%n in ('"%GIT%" rev-list --count origin/%BRANCH%..HEAD 2^>nul') do set "AHEAD=%%n"
if not "!AHEAD!"=="0" (
  echo.
  echo У тебя есть изменения, которые ещё не отправлены: !AHEAD! шт.
  echo Сначала запусти Отправить.cmd, потом обновляйся.
  goto fail
)

rem Локальные правки модов и конфигов сохраняем в резерв, а не выбрасываем.
"%GIT%" rev-parse -q --verify HEAD >nul 2>nul
if not errorlevel 1 (
  "%GIT%" status --porcelain --untracked-files=all -- mods config resourcepacks shaderpacks | findstr . >nul
  if not errorlevel 1 (
    "%GIT%" -c user.name=MineVillagers -c user.email=backup@localhost stash push -q -u -m "Резерв перед обновлением" -- mods config resourcepacks shaderpacks
    echo Твои локальные изменения сохранены в резерве git stash.
    for /l %%i in (1,1,20) do "%GIT%" stash drop -q "stash@{5}" >nul 2>nul
  )
)

"%GIT%" -c advice.detachedHead=false checkout -q -f -B %BRANCH% origin/%BRANCH% || goto fail
"%GIT%" reset -q --hard origin/%BRANCH% || goto fail
"%GIT%" clean -fdq -- mods
"%GIT%" branch -q -u origin/%BRANCH% >nul 2>nul

echo.
"%GIT%" log -1 --date=format:"%%d.%%m.%%Y %%H:%%M" --format="Готово. Версия от %%cd, %%an: %%s"
echo Можно запускать игру.
if not defined QUIET timeout /t 8 >nul
exit /b 0

:findgit
where git >nul 2>nul && (set "GIT=git" & exit /b 0)
for %%p in ("%ProgramFiles%\Git\cmd\git.exe" "%LOCALAPPDATA%\Programs\Git\cmd\git.exe") do (
  if exist %%p (set "GIT=%%~p" & exit /b 0)
)
exit /b 1

:nogit
echo Не найден Git. Установи Git for Windows: https://git-scm.com/download/win
echo Все пункты установщика можно оставить по умолчанию. Потом запусти этот файл снова.
goto fail

:netfail
echo.
echo Не получилось скачать сборку. Проверь интернет и что твой аккаунт GitHub
echo принял приглашение в репозиторий Game-Feel/SteamPunk.

:fail
echo.
echo Обновление не выполнено.
if not defined QUIET pause
exit /b 1
