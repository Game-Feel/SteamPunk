@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
set "BRANCH=main"

rem Работаем из копии во временной папке: получение чужих правок может перезаписать этот файл.
if /i not "%~1"=="--run" (
  copy /y "%~f0" "%TEMP%\steampunk-publish.cmd" >nul
  call "%TEMP%\steampunk-publish.cmd" --run "%~dp0." & exit /b
)
cd /d "%~2" || goto fail
title SteamPunk: отправка изменений сборки

call :findgit || goto nogit
if not exist ".git\" (
  echo Эта папка ещё не подключена к сборке. Сначала запусти Обновить.cmd.
  goto fail
)
"%GIT%" config core.quotepath false

rem Подпись коммитов: если в Git не настроено имя, берём имя пользователя Windows.
"%GIT%" config user.name >nul 2>nul || "%GIT%" config user.name "%USERNAME%"
"%GIT%" config user.email >nul 2>nul || "%GIT%" config user.email "%USERNAME%@users.noreply.github.com"

"%GIT%" add -A || goto fail
"%GIT%" diff --cached --quiet
if not errorlevel 1 (
  set "AHEAD=0"
  for /f %%n in ('"%GIT%" rev-list --count @{u}..HEAD 2^>nul') do set "AHEAD=%%n"
  if "!AHEAD!"=="0" (
    echo Изменений нет, отправлять нечего.
    goto done
  )
  echo Новых изменений нет, но есть неотправленные: !AHEAD! шт. Пробую отправить.
  goto sync
)

echo Будут отправлены изменения:
echo.
"%GIT%" -c color.status=always status --short
echo.
set "MSG="
set /p "MSG=Коротко опиши, что изменил. Пусто: отмена. > "
if not defined MSG (
  "%GIT%" reset -q
  echo Отменено, ничего не отправлено.
  goto done
)
set "MSG=!MSG:"=!"
"%GIT%" commit -q -m "!MSG!" || goto fail

:sync
for /l %%t in (1,1,3) do (
  "%GIT%" fetch -q origin %BRANCH% || goto netfail
  "%GIT%" rebase -q origin/%BRANCH% >nul 2>nul
  if errorlevel 1 (
    "%GIT%" rebase --abort >nul 2>nul
    echo.
    echo Кто-то уже отправил изменения тех же файлов. Автоматически объединить нельзя.
    echo Твои изменения сохранены у тебя и никуда не пропали.
    echo Договорись с другим издателем, чья версия этих файлов остаётся.
    goto fail
  )
  "%GIT%" push -q origin HEAD:%BRANCH% && goto pushed
  echo Сборка изменилась во время отправки, пробую ещё раз.
)
goto netfail

:pushed
"%GIT%" branch -q -u origin/%BRANCH% >nul 2>nul
echo.
echo Отправлено. Остальные получат это через Обновить.cmd.

:done
timeout /t 8 >nul
exit /b 0

:findgit
where git >nul 2>nul && (set "GIT=git" & exit /b 0)
for %%p in ("%ProgramFiles%\Git\cmd\git.exe" "%LOCALAPPDATA%\Programs\Git\cmd\git.exe") do (
  if exist %%p (set "GIT=%%~p" & exit /b 0)
)
exit /b 1

:nogit
echo Не найден Git. Установи Git for Windows: https://git-scm.com/download/win
goto fail

:netfail
echo.
echo Не получилось отправить. Проверь интернет и что у тебя есть право записи
echo в репозиторий Game-Feel/SteamPunk. Отправлять может только владелец сборки.

:fail
echo.
echo Отправка не выполнена.
pause
exit /b 1
