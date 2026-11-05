@echo off
setlocal DisableDelayedExpansion
set "STEAMPUNK_ROOT=%~dp0"
set "STEAMPUNK_SELF=%~f0"
set "STEAMPUNK_REPOSITORY=https://github.com/Game-Feel/SteamPunk.git"
set "STEAMPUNK_PACK=SteamPunk"
set "STEAMPUNK_ACTION=update"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:STEAMPUNK_SELF,[Text.Encoding]::UTF8); $marker='# STEAMPUNK_'+'POWERSHELL'; $script=$text.Substring($text.IndexOf($marker)+$marker.Length); & ([ScriptBlock]::Create($script))"
exit /b %errorlevel%
# STEAMPUNK_POWERSHELL
param(
    [string]$Root = $env:STEAMPUNK_ROOT,
    [string]$Repository = $env:STEAMPUNK_REPOSITORY,
    [string]$PackName = $env:STEAMPUNK_PACK,
    [switch]$LibraryOnly,
    [switch]$NoLaunch,
    [switch]$AcceptInstall,
    [switch]$Publish,
    [string]$GitOverride
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Save-Json($Value, [string]$Path) {
    $temp = $Path + '.new'
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 12), $script:Utf8)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, ($Path + '.previous')) }
    else { [IO.File]::Move($temp, $Path) }
}

function Resolve-PackPath([string]$Base, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[\\:\x00-\x1f]' -or $Relative.StartsWith('/')) {
        throw "Недопустимый путь: $Relative"
    }
    foreach ($part in $Relative.Split('/')) {
        if ($part -in @('', '.', '..') -or $part -match '[. ]$|[<>"|?*]' -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw "Недопустимый путь: $Relative"
        }
    }
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\')
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($baseFull, $Relative.Replace('/', '\')))
    if (-not $full.StartsWith($baseFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Путь выходит за папку сборки.' }
    $cursor = $baseFull
    foreach ($part in (@('') + $Relative.Split('/'))) {
        if ($part) { $cursor = [IO.Path]::Combine($cursor, $part) }
        $probe = $cursor
        if ($probe.Length -ge 240 -and -not $probe.StartsWith('\\?\')) { $probe='\\?\' + $probe }
        try { $attributes = [IO.File]::GetAttributes($probe) }
        catch {
            $cause=$_.Exception
            while ($cause.InnerException) { $cause=$cause.InnerException }
            if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) { break }
            throw
        }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Ссылки на другие папки не поддерживаются: $cursor" }
    }
    if ($full.Length -ge 240 -and -not $full.StartsWith('\\?\')) { return '\\?\' + $full }
    return $full
}

function Get-FileRule([string]$Path) {
    # Only explicitly permitted game files can ever enter a player's folder.
    $p = $Path.ToLowerInvariant()
    if ($p -match '(^|/)(\.git|\.connector|natives|logs|crash-reports|saves|screenshots|backups|cache|caches|spark|ias|accountswitcher)(/|$)' -or
        $p -match '(^|/)[^/]*(account|access.token|refresh.token|session|credential|launcher.profile)[^/]*' -or
        $p -match '(^|/)(usercache|usernamecache|servers)\.' -or
        $p -match '\.(log|tmp|bak|backup[0-9]+)$' -or
        $p -match '(^|/)(desktop\.ini|thumbs\.db|sodium-fingerprint\.json|embeddium-fingerprint\.json)$' -or
        $p -match '^config/(ias\.json|voicechat/username-cache\.json|sounds/chat\.json|fml\.toml|fancymenu/user_variables\.db)$' -or
        $p -match '^config/inventoryprofilesnext/(?!integrationhints/).+/' -or
        $p -match '^fancymenu_data/last_world\.fmdata$' -or
        $p -match '^kubejs/(fenix_dump/|exported/|fenix_night_spawn_status\.json$)') { return $null }
    if ($p.StartsWith('.playerdefaults/')) {
        $target = $Path.Substring('.playerdefaults/'.Length)
        $kind = Get-FileRule $target
        if ($kind -eq 'seed') { return 'default' }
        return $null
    }
    # Bundled resource and data packs are game content, not player preferences.
    if ($p -match '^config/(openloader/(resources|data)/|paxi/(resourcepacks|datapacks)/|fancymenu/(assets|customization)/)') { return 'managed' }
    if ($p -eq 'options.txt' -or $p -match '^config/' -or $p -match '^defaultconfigs/' -or
        $p -match '^shaderpacks/[^/]+\.txt$' -or $p -match '^kubejs/config/') { return 'seed' }
    if ($p -in @('обновить.cmd', 'отправить.cmd', 'играть.cmd')) { return 'managed' }
    if ($p -match '^(mods|resourcepacks|shaderpacks|versions|libraries|kubejs|fancymenu_data|schematics|ftbquests|patchouli_books)/') { return 'managed' }
    return $null
}

function Invoke-Git([string[]]$Arguments, [string]$Directory, [switch]$Quiet, [switch]$Live) {
    $gitArgs = @('-c', 'core.longpaths=true', '-c', 'core.quotepath=false', '-c', 'core.autocrlf=false')
    $anonymous = $Repository -eq 'https://github.com/Game-Feel/SteamPunk.git' -and -not $Publish -and $env:STEAMPUNK_ACTION -ne 'publish'
    if ($anonymous) {
        $gitArgs += @('-c', 'credential.helper=', '-c', 'credential.interactive=never', '-c', 'http.extraHeader=',
            '-c', 'http.lowSpeedLimit=1024', '-c', 'http.lowSpeedTime=120')
    }
    if ($Directory) { $gitArgs += @('-C', $Directory) }
    $gitArgs += $Arguments
    # Windows PowerShell turns native stderr into terminating errors under Stop.
    $saved = $ErrorActionPreference
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $oldInteractive = $env:GCM_INTERACTIVE
    $ErrorActionPreference = 'Continue'
    try {
        if ($anonymous) { $env:GIT_TERMINAL_PROMPT='0'; $env:GCM_INTERACTIVE='Never' }
        if ($Live) {
            & $script:Git @gitArgs 2>&1 | ForEach-Object { Write-Host $_.ToString() }
            $output = @()
        } else { $output = @(& $script:Git @gitArgs 2>&1) }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
        $env:GIT_TERMINAL_PROMPT = $oldPrompt
        $env:GCM_INTERACTIVE = $oldInteractive
    }
    if ($code -ne 0) {
        # Do not echo remote URLs or credential manager diagnostic output.
        if ($anonymous) { throw "Не удалось скачать данные сборки. Код Git: $code. Аккаунт не нужен. Проверь соединение с GitHub и запусти кнопку снова." }
        throw "Git не смог выполнить операцию $($Arguments[0]). Код $code. Проверь интернет и доступ к сборке в GitHub."
    }
    if (-not $Quiet) { return @($output | ForEach-Object { $_.ToString() }) }
}

function Find-Git([string]$Tools) {
    $candidates = @()
    if ($GitOverride) { $candidates += $GitOverride }
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @((Join-Path $Tools 'git/cmd/git.exe'), "$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $script:Git = $candidate
            try { Invoke-Git @('lfs', 'version') '' -Quiet; return $candidate } catch { }
        }
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Для этой сборки нужна 64 битная Windows.' }
    Write-Host 'Подготавливаю Git. Установка в систему и права администратора не нужны.'
    [IO.Directory]::CreateDirectory($Tools) | Out-Null
    $release = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = @($release.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' }) | Select-Object -First 1
    if (-not $asset -or -not $asset.digest -or $asset.digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Не удалось проверить официальный пакет Git.' }
    $archive = Join-Path $Tools 'PortableGit.exe'
    Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.digest.Substring(7)) { throw 'Контрольная сумма Git не совпала.' }
    $gitFolder = Join-Path $Tools 'git'
    # The official PortableGit 7z SFX accepts the extraction directory via -o.
    $p = Start-Process -FilePath $archive -ArgumentList @('-y', ('-o"' + $gitFolder + '"')) -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw 'Не удалось распаковать Git.' }
    $script:Git = Join-Path $gitFolder 'cmd/git.exe'
    Invoke-Git @('lfs', 'version') '' -Quiet
    return $script:Git
}

function Get-RepositoryFiles([string]$Cache, [string]$Commit) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $lines = @(Invoke-Git @('ls-tree', '-r', $Commit) $Cache)
    $checked = 0
    foreach ($line in $lines) {
        $checked++
        if ($checked % 250 -eq 0) { Write-Progress -Activity 'Проверяю состав сборки' -Status "$checked из $($lines.Count)" -PercentComplete ([int](100*$checked/$lines.Count)) }
        if ($line -notmatch '^([0-9]+) blob ([a-f0-9]{40,64})\t(.+)$') { continue }
        $mode = $Matches[1]; $oid = $Matches[2]; $source = $Matches[3]
        $rule = Get-FileRule $source
        if (-not $rule) { continue }
        if ($mode -ne '100644' -and $mode -ne '100755') { throw "В сборке обнаружена ссылка вместо файла: $source" }
        $target = $source
        if ($rule -eq 'default') { $target = $source.Substring('.playerdefaults/'.Length); $rule = 'seed' }
        $null = Resolve-PackPath $Cache $source
        if ($seen.ContainsKey($target)) { throw "Два источника для одного файла: $target" }
        $seen[$target] = $true
        $entries.Add([pscustomobject]@{ path=$target; source=$source; oid=$oid; kind=$rule })
    }
    Write-Progress -Activity 'Проверяю состав сборки' -Completed
    return $entries.ToArray()
}

function New-UpdatePlan([string]$Destination, $Files, $Previous) {
    $known = @{}; $present = @{}
    if ($Previous) { foreach ($old in @($Previous.files)) { $known[$old.path] = $old } }
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Files) {
        $target = Resolve-PackPath $Destination $entry.path
        $present[$entry.path] = $true
        if ($entry.kind -eq 'seed') {
            # Existing settings and intentional deletions are permanent choices.
            if (-not (Test-Path -LiteralPath $target) -and -not $known.ContainsKey($entry.path)) {
                $plan.Add([pscustomobject]@{ action='copy'; entry=$entry })
            }
        } elseif (-not $known.ContainsKey($entry.path) -or $known[$entry.path].oid -ne $entry.oid -or -not (Test-Path -LiteralPath $target)) {
            $plan.Add([pscustomobject]@{ action='copy'; entry=$entry })
        }
    }
    foreach ($old in $known.Values) {
        if ($old.kind -eq 'managed' -and (Get-FileRule $old.path) -eq 'managed' -and -not $present.ContainsKey($old.path)) {
            $target = Resolve-PackPath $Destination $old.path
            if (Test-Path -LiteralPath $target -PathType Leaf) { $plan.Add([pscustomobject]@{ action='retire'; entry=$old }) }
        }
    }
    return $plan.ToArray()
}

function Restore-Transaction([string]$Destination, [string]$Control) {
    $journalPath = Join-Path $Control 'transaction.json'
    if (-not (Test-Path -LiteralPath $journalPath)) { return }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.state -eq 'committed') { return }
    Write-Host 'Восстанавливаю файлы после незавершённого обновления.'
    foreach ($record in @($journal.records)) {
        $target = Resolve-PackPath $Destination $record.path
        $backup = Resolve-PackPath $Control $record.backup
        if ($record.existed) {
            if (-not (Test-Path -LiteralPath $backup)) { throw 'Не найден резерв для восстановления. Обновление остановлено.' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.File]::Copy($backup, $target, $true)
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            # Move partial new files into the transaction backup, never delete user files.
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup)) | Out-Null
            [IO.File]::Move($target, $backup + '.incomplete.' + [guid]::NewGuid().ToString('N'))
        }
    }
    $statePath = Join-Path $Control 'installed.json'
    if ($journal.hadState) {
        [IO.File]::Copy((Resolve-PackPath $Control $journal.stateBackup), $statePath, $true)
    } elseif (Test-Path -LiteralPath $statePath) {
        [IO.File]::Move($statePath, (Join-Path $Control ('incomplete.state.' + [guid]::NewGuid().ToString('N') + '.json')))
    }
    $journal.state = 'committed'
    Save-Json $journal $journalPath
}

function Apply-Update([string]$Destination, [string]$Cache, [string]$Control, $Files, $Previous, [string]$Commit, [string]$Repo) {
    Write-Host 'Подготавливаю установку. Проверяю файлы и сохраняю резерв.'
    $plan = @(New-UpdatePlan $Destination $Files $Previous)
    $transaction = 'backups/' + [guid]::NewGuid().ToString('N')
    $records = New-Object 'System.Collections.Generic.List[object]'
    # Stage and verify every changed file before touching the installation.
    $processed = 0
    foreach ($step in $plan) {
        $processed++
        if ($processed % 100 -eq 0) { Write-Progress -Activity 'Подготавливаю файлы' -Status "$processed из $($plan.Count)" -PercentComplete ([int](100*$processed/$plan.Count)) }
        $relative = $step.entry.path
        $target = Resolve-PackPath $Destination $relative
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Вместо файла найдена папка: $relative" }
        if ($step.action -eq 'copy') {
            $source = Resolve-PackPath $Cache $step.entry.source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "В загрузке отсутствует файл: $relative" }
            $stream = [IO.File]::OpenRead($source)
            try { $bytes=New-Object byte[] 128; $n=$stream.Read($bytes,0,128) } finally { $stream.Dispose() }
            if ([Text.Encoding]::ASCII.GetString($bytes,0,$n).StartsWith('version https://git-lfs.github.com/spec/v1')) { throw "Git LFS не загрузил файл: $relative" }
        }
        $backupRelative = $transaction + '/' + $relative
        $backup = Resolve-PackPath $Control $backupRelative
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        if ($existed) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup)) | Out-Null
            [IO.File]::Copy($target, $backup, $false)
            # A running game may hold a destination open. Fail before applying anything.
            $handle = [IO.File]::Open($target, 'Open', 'ReadWrite', 'None'); $handle.Dispose()
        }
        $records.Add([pscustomobject]@{ path=$relative; backup=$backupRelative; existed=[bool]$existed })
    }
    Write-Progress -Activity 'Подготавливаю файлы' -Completed
    $journalPath = Join-Path $Control 'transaction.json'
    $statePath = Join-Path $Control 'installed.json'
    $stateBackup = $transaction + '/installed.json'
    $hadState = Test-Path -LiteralPath $statePath
    $stateBackupPath = Resolve-PackPath $Control $stateBackup
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stateBackupPath)) | Out-Null
    if ($hadState) { [IO.File]::Copy($statePath, $stateBackupPath, $false) }
    $journal = [pscustomobject]@{ state='pending'; hadState=[bool]$hadState; stateBackup=$stateBackup; records=@($records.ToArray()) }
    Save-Json $journal $journalPath
    try {
        $processed = 0
        foreach ($step in $plan) {
            $processed++
            if ($processed % 100 -eq 0) { Write-Progress -Activity 'Устанавливаю сборку' -Status "$processed из $($plan.Count)" -PercentComplete ([int](100*$processed/$plan.Count)) }
            $target = Resolve-PackPath $Destination $step.entry.path
            if ($step.action -eq 'retire') {
                # Old mod versions leave mods, but remain recoverable in backups.
                $retired = Resolve-PackPath $Control ($transaction + '/retired/' + $step.entry.path)
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($retired)) | Out-Null
                [IO.File]::Move($target, $retired)
            } else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.File]::Copy((Resolve-PackPath $Cache $step.entry.source), $target, $true)
            }
        }
        Write-Progress -Activity 'Устанавливаю сборку' -Completed
        # Keep removed seed paths as tombstones, so an update cannot reset them later.
        $next = @{}; foreach ($file in $Files) { $next[$file.path]=$file }
        if ($Previous) { foreach ($file in @($Previous.files)) { if ($file.kind -eq 'seed' -and -not $next.ContainsKey($file.path)) { $next[$file.path]=$file } } }
        $state = [pscustomobject]@{ schema=1; repository=$Repo; commit=$Commit; files=@($next.Values) }
        Save-Json $state (Join-Path $Control 'installed.json')
        $journal.state='committed'
        Save-Json $journal $journalPath
    } catch {
        $failure = $_
        Restore-Transaction $Destination $Control
        throw $failure
    }
    return $plan.Count
}

function Confirm-Installation([string]$Destination, [string]$Name) {
    Add-Type -AssemblyName System.Windows.Forms
    $text = "Игра не обнаружена. Установить Minecraft $Name здесь?`r`n`r`n$Destination`r`n`r`nЭто папка, в которой находится кнопка «Обновить»."
    return [Windows.Forms.MessageBox]::Show($text, "Minecraft $Name", 'YesNo', 'Question') -eq 'Yes'
}

function Assert-GameClosed([string]$Destination) {
    $escaped = [regex]::Escape($Destination)
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped -and $_.CommandLine -match 'net\.minecraft|cpw\.mods|modlauncher|bootstraplauncher|net\.fabricmc' })
    if ($running.Count) { throw 'Сначала закрой Minecraft этой сборки и запусти кнопку снова.' }
}

function Test-LoaderProfileEquivalent([string]$Before, [string]$After) {
    try {
        $old = $Before | ConvertFrom-Json
        $new = $After | ConvertFrom-Json
        # Legacy Launcher rewrites this timestamp after launching the game.
        $old.PSObject.Properties.Remove('time')
        $new.PSObject.Properties.Remove('time')
        return (ConvertTo-Json $old -Depth 100 -Compress) -ceq (ConvertTo-Json $new -Depth 100 -Compress)
    } catch { return $false }
}

function Get-PendingManagedChanges([string]$Destination) {
    $paths = @(Invoke-Git @('diff', '--name-only', 'HEAD') $Destination) + @(Invoke-Git @('ls-files', '--others', '--exclude-standard') $Destination)
    foreach ($path in $paths) {
        if ((Get-FileRule $path) -ne 'managed') { continue }
        if ($path -match '^versions/[^/]+/[^/]+\.json$') {
            try {
                $before = (Invoke-Git @('show', ('HEAD:' + $path)) $Destination) -join "`n"
                $after = [IO.File]::ReadAllText((Resolve-PackPath $Destination $path))
                if (Test-LoaderProfileEquivalent $before $after) { continue }
            } catch { }
        }
        $path
    }
}

function Start-PackLauncher([string]$Destination, [string]$Name, [string]$Control) {
    $launcherFolder = Join-Path $Control 'launcher'
    [IO.Directory]::CreateDirectory($launcherFolder) | Out-Null
    $bootstrap = Join-Path $launcherFolder 'bootstrap.jar'
    $alreadyRunning = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($bootstrap) })
    if ($alreadyRunning.Count) { Write-Host 'Legacy Launcher этой сборки уже открыт.'; return }
    $bootstrapHash = '09ba7517c8a9b30780ff9a6de230b8905247835ae0da914d66991e2b3b4b6c4e'
    if (-not (Test-Path -LiteralPath $bootstrap)) {
        Write-Host 'Подготавливаю Legacy Launcher.'
        $downloaded = $false
        foreach ($hostName in @('updates.legacylauncher.ru', 'updates.llaun.ch')) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "https://$hostName/legacy/bootstrap/$bootstrapHash.jar" -OutFile ($bootstrap + '.new')
                if ((Get-FileHash -LiteralPath ($bootstrap + '.new') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $bootstrapHash) { throw 'Контрольная сумма Legacy Launcher не совпала.' }
                [IO.File]::Move(($bootstrap + '.new'), $bootstrap)
                $downloaded=$true; break
            } catch { }
        }
        if (-not $downloaded) { throw 'Сборка установлена, но сервер Legacy Launcher недоступен. Запусти кнопку позже.' }
    }
    $runtime = Join-Path $Control 'runtime'
    $java = @(Get-ChildItem -LiteralPath $runtime -Filter javaw.exe -File -Recurse -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $java) {
        Write-Host 'Скачиваю Java для лаунчера.'
        $assets = Invoke-RestMethod 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jre&os=windows&vendor=eclipse'
        $package = @($assets)[0].binary.package
        $archive = Join-Path $Control 'java.zip'
        Invoke-WebRequest -UseBasicParsing -Uri $package.link -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $package.checksum.ToLowerInvariant()) { throw 'Контрольная сумма Java не совпала.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $runtime -Force
        $java = Get-ChildItem -LiteralPath $runtime -Filter javaw.exe -File -Recurse | Select-Object -First 1
        if (-not $java) { throw 'Не удалось подготовить Java.' }
    }
    $profile = 'Forge 1.20.1'
    if ($Name -eq 'Steampunk 1.3') { $profile = 'NeoForge 1.21.1' }
    $settings = Join-Path $launcherFolder 'tl.properties'
    if (-not (Test-Path -LiteralPath $settings)) {
        # Safe launcher preferences only. Never copy a publisher's accounts or identifiers.
        [IO.File]::WriteAllText($settings, "locale=ru_RU`r`nminecraft.versions.modified=true`r`nminecraft.mods.removeUndesirable=false`r`ngui.notices.enabled=false`r`nminecraft.servers.promoted=false`r`nminecraft.servers.promoted.ingame=false`r`n", $script:Utf8)
    }
    $launchArgs = @('-jar', $bootstrap, '--targetJar', (Join-Path $launcherFolder 'launcher.jar'), '--targetLibFolder', (Join-Path $launcherFolder 'libraries'), '--', '--directory', $Destination, '--settings', $settings, '--jre-dir', (Join-Path $Control 'jre'), '--version', $profile)
    $quoted = @($launchArgs | ForEach-Object { '"' + $_ + '"' })
    Start-Process -FilePath $java.FullName -ArgumentList ($quoted -join ' ') -WorkingDirectory $launcherFolder
}

function Save-PlayerDefaults([string]$Source) {
    $paths = @('options.txt', 'config/sodium-options.json', 'config/embeddium-options.json', 'config/embeddium++.toml',
        'config/rubidium-options.json', 'config/betterfpsdist.json', 'config/DistantHorizons.toml', 'config/bobby.toml',
        'config/iris.properties', 'config/oculus.properties', 'config/fzzy_config/keybinds.toml', 'config/punchy/triggerable-keybindings.json')
    $shaderFolder = Join-Path $Source 'shaderpacks'
    if (Test-Path -LiteralPath $shaderFolder) {
        foreach ($file in Get-ChildItem -LiteralPath $shaderFolder -File -Filter '*.txt') { $paths += 'shaderpacks/' + $file.Name }
    }
    foreach ($relative in $paths) {
        $sourcePath = Resolve-PackPath $Source $relative
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $dest = Resolve-PackPath $Source ('.playerdefaults/' + $relative)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        if ($relative -eq 'options.txt') {
            $lines = [IO.File]::ReadAllLines($sourcePath) | Where-Object { $_ -notmatch '^(lastServer|server|accessToken|session|username):' }
            [IO.File]::WriteAllLines($dest, [string[]]$lines, $script:Utf8)
        } else { [IO.File]::Copy($sourcePath, $dest, $true) }
    }
}

function Publish-Pack([string]$Destination, [string]$Repo) {
    Assert-GameClosed $Destination
    $script:Git = Find-Git (Join-Path $Destination '.steampunk/tools')
    if (-not (Test-Path -LiteralPath (Join-Path $Destination '.git'))) { throw 'Для отправки нужна авторская копия репозитория. Эта кнопка предназначена владельцу сборки.' }
    $origin = (Invoke-Git @('remote', 'get-url', 'origin') $Destination | Select-Object -First 1).Trim()
    if ($origin -ne $Repo) { throw 'Адрес авторской копии не совпадает со сборкой.' }
    Save-PlayerDefaults $Destination
    Invoke-Git @('add', '-A') $Destination -Quiet
    $changes = @(Invoke-Git @('diff', '--cached', '--name-only') $Destination)
    if ($changes.Count) {
        Write-Host ('Изменено файлов: ' + $changes.Count)
        $message = Read-Host 'Коротко опиши изменения. Пустая строка отменяет отправку'
        if ([string]::IsNullOrWhiteSpace($message)) { Write-Host 'Отправка отменена.'; return }
        Invoke-Git @('commit', '-m', $message) $Destination -Quiet
    }
    Invoke-Git @('fetch', 'origin', 'main') $Destination -Quiet
    try { Invoke-Git @('rebase', 'origin/main') $Destination -Quiet }
    catch { try { Invoke-Git @('rebase', '--abort') $Destination -Quiet } catch { }; throw 'Есть конфликт с изменениями GitHub. Твои изменения сохранены локально.' }
    Invoke-Git @('push', 'origin', 'HEAD:main') $Destination -Quiet
    $head = (Invoke-Git @('rev-parse', 'HEAD') $Destination | Select-Object -First 1).Trim()
    $remote = (Invoke-Git @('ls-remote', 'origin', 'refs/heads/main') $Destination | Select-Object -First 1) -split '\s+'
    if ($remote[0] -ne $head) { throw 'Не удалось подтвердить версию на GitHub. Повтори отправку.' }
    Write-Host 'Отправлено. Версия на GitHub проверена. Начальные настройки для новых игроков тоже обновлены.'
}

function Main {
    if (-not $Root -or -not $Repository -or -not $PackName) { throw 'Не заданы папка или сборка.' }
    if ($Repository -notmatch '^https://github\.com/Game-Feel/(SteamPunk|Steampunk-1\.3)\.git$') { throw 'Неизвестный источник сборки.' }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    if ($fullRoot -eq [IO.Path]::GetPathRoot($fullRoot)) { throw 'Помести кнопку в отдельную папку для сборки.' }
    $destination = $fullRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw 'Папка кнопки не найдена.' }
    if ($Publish -or $env:STEAMPUNK_ACTION -eq 'publish') { Publish-Pack $destination $Repository; return }
    $control = Resolve-PackPath $destination '.steampunk'
    $statePath = Join-Path $control 'installed.json'
    $modsFolder = Resolve-PackPath $destination 'mods'
    $versionsFolder = Resolve-PackPath $destination 'versions'
    $hasGame = (@(Get-ChildItem -LiteralPath $modsFolder -File -Filter '*.jar' -ErrorAction SilentlyContinue).Count -gt 0) -and
        (@(Get-ChildItem -LiteralPath $versionsFolder -File -Filter '*.json' -Recurse -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $hasGame -and -not $AcceptInstall) {
        if (-not (Confirm-Installation $destination $PackName)) { return }
    }
    Assert-GameClosed $destination
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $lockPath = Join-Path $control 'update.lock'
    try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Обновление уже выполняется. Дождись его завершения.' }
    try {
        Restore-Transaction $destination $control
        $previous = $null
        if (Test-Path -LiteralPath $statePath) {
            $previous = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($previous.schema -ne 1 -or $previous.repository -ne $Repository) { throw 'Эта папка принадлежит другой сборке.' }
        }
        $script:Git = Find-Git (Join-Path $control 'tools')
        if (Test-Path -LiteralPath (Join-Path $destination '.git')) {
            $ahead = (Invoke-Git @('rev-list', '--count', 'origin/main..HEAD') $destination | Select-Object -First 1).Trim()
            if ($ahead -ne '0') { throw 'В авторской копии есть неотправленные коммиты. Сначала запусти Отправить.cmd.' }
            if (@(Get-PendingManagedChanges $destination).Count) {
                throw 'В авторской копии есть изменения файлов сборки. Сначала отправь их через Отправить.cmd. Настройки игрока обновлению не мешают.'
            }
        }
        $cache = Join-Path $control 'repository'
        $oldSmudge = $env:GIT_LFS_SKIP_SMUDGE
        $oldLfsProgress = $env:GIT_LFS_FORCE_PROGRESS
        try {
            $env:GIT_LFS_SKIP_SMUDGE='1'
            $env:GIT_LFS_FORCE_PROGRESS='1'
            if (-not (Test-Path -LiteralPath (Join-Path $cache '.git'))) {
                if ($Repository -eq 'https://github.com/Game-Feel/SteamPunk.git') {
                    Write-Host 'Скачиваю публичную SteamPunk. Аккаунт GitHub не требуется.'
                } else { Write-Host 'Скачиваю приватную сборку. GitHub может попросить войти в аккаунт.' }
                Write-Host 'Первая загрузка большая. Ниже отображается прогресс Git.'
                Write-Host 'До завершения загрузки папка игры может выглядеть пустой. Затем файлы распакуются.'
                $cloneArgs = @('clone', '--progress', '--depth=1', '--no-checkout', '--branch', 'main')
                if (Test-Path -LiteralPath (Join-Path $destination '.git')) { $cloneArgs += @('--reference-if-able', $destination, '--dissociate') }
                $cloneArgs += @('--', $Repository, $cache)
                Invoke-Git $cloneArgs '' -Quiet -Live
            } else {
                Write-Host 'Проверяю версию сборки.'
                # An interrupted first clone may not have finished configuring its remote.
                Invoke-Git @('config', 'remote.origin.url', $Repository) $cache -Quiet
                Invoke-Git @('config', 'remote.origin.fetch', '+refs/heads/main:refs/remotes/origin/main') $cache -Quiet
                Invoke-Git @('fetch', '--progress', '--depth=1', 'origin', 'main') $cache -Quiet -Live
            }
            Invoke-Git @('lfs', 'install', '--local') $cache -Quiet
            $commit = (Invoke-Git @('rev-parse', 'origin/main') $cache | Select-Object -First 1).Trim()
            if ($previous -and $previous.commit -eq $commit -and $hasGame) {
                Write-Host 'Установлена актуальная версия. Файлы игры и настройки не изменены.'
                if (-not $NoLaunch) { Start-PackLauncher $destination $PackName $control }
                return
            }
            Write-Host 'Проверяю состав сборки.'
            $files = @(Get-RepositoryFiles $cache $commit)
            if (-not @($files | Where-Object { $_.path -match '^mods/.+\.jar$' }).Count -or
                -not @($files | Where-Object { $_.path -match '^versions/.+\.json$' }).Count) { throw 'В репозитории не найдена полная сборка.' }
            if (-not @($files | Where-Object { $_.source -eq '.playerdefaults/options.txt' }).Count) {
                throw 'Версия сборки на GitHub ещё не подготовлена для этого установщика. Начальные настройки отсутствуют.'
            }
            Write-Host 'Распаковываю файлы сборки.'
            Invoke-Git @('checkout', '--progress', '--force', '--detach', $commit) $cache -Quiet -Live
            Write-Host 'Скачиваю большие файлы модов.'
            Invoke-Git @('lfs', 'pull', 'origin') $cache -Quiet -Live
            $count = Apply-Update $destination $cache $control $files $previous $commit $Repository
            Write-Host "Готово. Обработано файлов: $count. Твои настройки сохранены."
        } finally { $env:GIT_LFS_SKIP_SMUDGE = $oldSmudge; $env:GIT_LFS_FORCE_PROGRESS=$oldLfsProgress }
        if (-not $NoLaunch) { Start-PackLauncher $destination $PackName $control }
    } finally { $lock.Dispose() }
}

if (-not $LibraryOnly) {
    try { Main; exit 0 }
    catch {
        Write-Host ('Не удалось завершить: ' + $_.Exception.Message) -ForegroundColor Red
        [void](Read-Host 'Нажми Enter, чтобы закрыть окно')
        exit 1
    }
}
