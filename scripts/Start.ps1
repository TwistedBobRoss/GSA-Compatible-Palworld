$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-BoolEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    switch ($value.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default { return $Default }
    }
}

function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value
}

function Escape-PalString {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return $Value.Replace("\", "\\").Replace('"', '\"').Replace("`r", "").Replace("`n", "\n")
}

function ConvertTo-PalBoolean {
    param([bool]$Value)

    if ($Value) {
        return "True"
    }
    return "False"
}

function Set-PalSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escapedName = [Regex]::Escape($Name)
    $pattern = "(?<=\(|,)$escapedName=(?:`"(?:\\.|[^`"])*`"|\((?:[^()]|\([^()]*\))*\)|[^,\)]*)"
    $replacement = "$Name=$Value"

    if ([Regex]::IsMatch($Content, $pattern)) {
        return [Regex]::Replace($Content, $pattern, $replacement, 1)
    }

    $optionEnd = $Content.LastIndexOf(")")
    if ($optionEnd -lt 0) {
        throw "PalWorldSettings.ini does not contain a valid OptionSettings tuple."
    }

    return $Content.Insert($optionEnd, ",$replacement")
}

function Invoke-SteamUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$SteamCmd,
        [Parameter(Mandatory = $true)][string]$ServerDir,
        [bool]$Validate
    )

    $arguments = @(
        "+force_install_dir", $ServerDir,
        "+login", "anonymous",
        "+app_update", "2394010"
    )

    if ($Validate) {
        $arguments += "validate"
    }

    $arguments += "+quit"
    Write-Host "*** Updating Palworld Dedicated Server with SteamCMD"
    & $SteamCmd @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SteamCMD failed with exit code $LASTEXITCODE."
    }
}

function Install-UE4SS {
    param(
        [Parameter(Mandatory = $true)][string]$Win64Dir,
        [Parameter(Mandatory = $true)][string]$Release,
        [AllowEmptyString()][string]$DownloadUrl,
        [AllowEmptyString()][string]$Sha256,
        [bool]$Force
    )

    $proxyPath = Join-Path $Win64Dir "dwmapi.dll"
    $legacyDll = Join-Path $Win64Dir "UE4SS.dll"
    $newDll = Join-Path $Win64Dir "ue4ss\UE4SS.dll"
    if (-not $Force -and (Test-Path -LiteralPath $proxyPath) -and
        ((Test-Path -LiteralPath $legacyDll) -or (Test-Path -LiteralPath $newDll))) {
        Write-Host "*** UE4SS is already installed"
        return
    }

    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        Write-Host "*** Resolving official UE4SS release $Release"
        $releaseInfo = Invoke-RestMethod `
            -UseBasicParsing `
            -Headers @{ "User-Agent" = "GSA-Compatible-Palworld" } `
            -Uri "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/$Release"
        $asset = $releaseInfo.assets |
            Where-Object {
                $_.name -like "*.zip" -and
                $_.name -match "UE4SS" -and
                $_.name -notmatch "(?i)dev"
            } |
            Select-Object -First 1
        if ($null -eq $asset) {
            throw "No non-development UE4SS zip asset was found for release $Release."
        }
        $DownloadUrl = $asset.browser_download_url
    }

    $archive = Join-Path $env:TEMP "ue4ss.zip"
    Write-Host "*** Downloading UE4SS from its official GitHub release"
    Invoke-WebRequest `
        -UseBasicParsing `
        -Headers @{ "User-Agent" = "GSA-Compatible-Palworld" } `
        -Uri $DownloadUrl `
        -OutFile $archive
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if (-not $actualHash.Equals($Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $archive -Force
            throw "UE4SS checksum mismatch. Expected $Sha256 but downloaded $actualHash."
        }
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $Win64Dir -Force
    Remove-Item -LiteralPath $archive -Force

    if (-not (Test-Path -LiteralPath $proxyPath)) {
        throw "UE4SS extraction completed, but dwmapi.dll was not found in $Win64Dir."
    }
}

function Enable-UE4SSMod {
    param(
        [Parameter(Mandatory = $true)][string]$ModsDir,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
    $destination = Join-Path $ModsDir "PalBridge"
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Path (Join-Path $SourceDir "*") -Destination $destination -Recurse -Force

    $modsFile = Join-Path $ModsDir "mods.txt"
    $lines = @()
    if (Test-Path -LiteralPath $modsFile) {
        $lines = @(Get-Content -LiteralPath $modsFile |
            Where-Object { $_ -notmatch "^\s*PalBridge\s*:" })
    }

    $builtInMods = @(
        "ActorDumperMod",
        "BPML_GenericFunctions",
        "BPModLoaderMod",
        "CheatManagerEnablerMod",
        "ConsoleCommandsMod",
        "ConsoleEnablerMod",
        "Keybinds",
        "LineTraceMod",
        "SplitScreenMod",
        "jsbLuaProfilerMod"
    )
    foreach ($builtInMod in $builtInMods) {
        $pattern = "^\s*" + [Regex]::Escape($builtInMod) + "\s*:.*$"
        $lines = @($lines | ForEach-Object {
            if ($_ -match $pattern) { "$builtInMod : 0" } else { $_ }
        })
    }
    $lines += "PalBridge : 1"
    [IO.File]::WriteAllLines($modsFile, $lines, [Text.UTF8Encoding]::new($false))
}

function Configure-UE4SS {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return
    }

    $settings = Get-Content -LiteralPath $SettingsPath -Raw
    $settings = [Regex]::Replace($settings, "(?m)^\s*GuiConsoleEnabled\s*=.*$", "GuiConsoleEnabled = 0")
    $settings = [Regex]::Replace($settings, "(?m)^\s*GuiConsoleVisible\s*=.*$", "GuiConsoleVisible = 0")
    $settings = [Regex]::Replace($settings, "(?m)^\s*ConsoleEnabled\s*=.*$", "ConsoleEnabled = 1")
    $settings = [Regex]::Replace($settings, "(?m)^\s*bUseUObjectArrayCache\s*=.*$", "bUseUObjectArrayCache = false")
    [IO.File]::WriteAllText($SettingsPath, $settings, [Text.UTF8Encoding]::new($false))
}

$DataDir = Get-EnvOrDefault -Name "PAL_DATA_DIR" -Default "C:\serverfiles"
$ServerDir = $DataDir
$SteamDir = Join-Path $DataDir "_steamcmd"
$LogsDir = Join-Path $DataDir "Logs"
$BackupsDir = Join-Path $DataDir "Backups"
$SteamCmd = Join-Path $SteamDir "steamcmd.exe"
$ServerExe = Join-Path $ServerDir "Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"
$DefaultConfig = Join-Path $ServerDir "DefaultPalWorldSettings.ini"
$ConfigDir = Join-Path $ServerDir "Pal\Saved\Config\WindowsServer"
$ConfigPath = Join-Path $ConfigDir "PalWorldSettings.ini"
$ConsoleLog = Join-Path $LogsDir "PalServer-console.log"
$ChatLog = Join-Path $LogsDir "PalServer-chat.log"
$EventLog = Join-Path $LogsDir "PalServer-events.log"
$Win64Dir = Split-Path -Parent $ServerExe
$PalBridgeModSource = "C:\PalBridgeMod"

$GamePort = Get-EnvOrDefault -Name "PAL_GAME_PORT" -Default "8211"
$QueryPort = Get-EnvOrDefault -Name "PAL_QUERY_PORT" -Default "27015"
$RconPort = Get-EnvOrDefault -Name "PAL_RCON_PORT" -Default "25575"
$NativeRconPort = Get-EnvOrDefault -Name "PAL_NATIVE_RCON_PORT" -Default "25576"
$RestPort = Get-EnvOrDefault -Name "PAL_REST_PORT" -Default "8212"
$MaxPlayers = Get-EnvOrDefault -Name "PAL_MAX_PLAYERS" -Default "32"
$ServerName = Get-EnvOrDefault -Name "PAL_SERVER_NAME" -Default "Palworld Server"
$ServerDescription = Get-EnvOrDefault -Name "PAL_SERVER_DESCRIPTION" -Default "Palworld server hosted with GameServerApp"
$ServerPassword = Get-EnvOrDefault -Name "PAL_SERVER_PASSWORD" -Default ""
$AdminPassword = Get-EnvOrDefault -Name "PAL_ADMIN_PASSWORD" -Default ""
$PublicIp = Get-EnvOrDefault -Name "PAL_PUBLIC_IP" -Default ""
$PublicPort = Get-EnvOrDefault -Name "PAL_PUBLIC_PORT" -Default $GamePort
$ExtraArgs = Get-EnvOrDefault -Name "PAL_EXTRA_ARGS" -Default ""
$LogFormat = Get-EnvOrDefault -Name "PAL_LOG_FORMAT" -Default "Text"
$CaptureMode = Get-EnvOrDefault -Name "PAL_CAPTURE_MODE" -Default "pipe"
$BridgeEnabled = Get-BoolEnv -Name "PAL_BRIDGE_ENABLED" -Default $true
$ModEnabled = Get-BoolEnv -Name "PAL_MOD_ENABLED" -Default $true
$UE4SSForceInstall = Get-BoolEnv -Name "PAL_UE4SS_FORCE_INSTALL" -Default $false
$UE4SSRelease = Get-EnvOrDefault -Name "PAL_UE4SS_RELEASE" -Default "experimental-latest"
$UE4SSUrl = Get-EnvOrDefault -Name "PAL_UE4SS_URL" -Default ""
$UE4SSSha256 = Get-EnvOrDefault -Name "PAL_UE4SS_SHA256" -Default ""
$UpdateOnStart = Get-BoolEnv -Name "PAL_UPDATE_ON_START" -Default $true
$ValidateOnUpdate = Get-BoolEnv -Name "PAL_VALIDATE_ON_UPDATE" -Default $false
$PublicLobby = Get-BoolEnv -Name "PAL_PUBLIC_LOBBY" -Default $true
$UseBackupSaveData = Get-BoolEnv -Name "PAL_USE_BACKUP_SAVE_DATA" -Default $true
$AllowClientMod = Get-BoolEnv -Name "PAL_ALLOW_CLIENT_MOD" -Default $false
$CrossplayPlatforms = Get-EnvOrDefault -Name "PAL_CROSSPLAY_PLATFORMS" -Default "(Steam,Xbox,PS5,Mac)"
$ChatPostLimitPerMinute = Get-EnvOrDefault -Name "PAL_CHAT_POST_LIMIT" -Default "10"
$PvpEnabled = Get-BoolEnv -Name "PAL_PVP_ENABLED" -Default $false
$HardcoreEnabled = Get-BoolEnv -Name "PAL_HARDCORE_ENABLED" -Default $false
$DeathPenalty = Get-EnvOrDefault -Name "PAL_DEATH_PENALTY" -Default "All"
$InvaderEnabled = Get-BoolEnv -Name "PAL_INVADER_ENABLED" -Default $true
$FastTravelEnabled = Get-BoolEnv -Name "PAL_FAST_TRAVEL_ENABLED" -Default $true
$StartLocationSelect = Get-BoolEnv -Name "PAL_START_LOCATION_SELECT" -Default $true
$ExpRate = Get-EnvOrDefault -Name "PAL_EXP_RATE" -Default "1.0"
$CaptureRate = Get-EnvOrDefault -Name "PAL_CAPTURE_RATE" -Default "1.0"
$SpawnRate = Get-EnvOrDefault -Name "PAL_SPAWN_RATE" -Default "1.0"
$EnemyDropRate = Get-EnvOrDefault -Name "PAL_ENEMY_DROP_RATE" -Default "1.0"
$CollectionDropRate = Get-EnvOrDefault -Name "PAL_COLLECTION_DROP_RATE" -Default "1.0"
$DayTimeSpeedRate = Get-EnvOrDefault -Name "PAL_DAY_TIME_SPEED_RATE" -Default "1.0"
$NightTimeSpeedRate = Get-EnvOrDefault -Name "PAL_NIGHT_TIME_SPEED_RATE" -Default "1.0"
$EggHatchingTime = Get-EnvOrDefault -Name "PAL_EGG_HATCHING_TIME" -Default "72.0"
$PlayerDamageAttack = Get-EnvOrDefault -Name "PAL_PLAYER_DAMAGE_ATTACK" -Default "1.0"
$PlayerDamageDefense = Get-EnvOrDefault -Name "PAL_PLAYER_DAMAGE_DEFENSE" -Default "1.0"
$PalDamageAttack = Get-EnvOrDefault -Name "PAL_PAL_DAMAGE_ATTACK" -Default "1.0"
$PalDamageDefense = Get-EnvOrDefault -Name "PAL_PAL_DAMAGE_DEFENSE" -Default "1.0"
$PlayerHungerRate = Get-EnvOrDefault -Name "PAL_PLAYER_HUNGER_RATE" -Default "1.0"
$PlayerStaminaRate = Get-EnvOrDefault -Name "PAL_PLAYER_STAMINA_RATE" -Default "1.0"
$PalHungerRate = Get-EnvOrDefault -Name "PAL_PAL_HUNGER_RATE" -Default "1.0"
$PalStaminaRate = Get-EnvOrDefault -Name "PAL_PAL_STAMINA_RATE" -Default "1.0"
$GuildPlayerMax = Get-EnvOrDefault -Name "PAL_GUILD_PLAYER_MAX" -Default "20"
$BaseCampMaxInGuild = Get-EnvOrDefault -Name "PAL_BASE_CAMP_MAX_IN_GUILD" -Default "4"
$BaseCampWorkerMax = Get-EnvOrDefault -Name "PAL_BASE_CAMP_WORKER_MAX" -Default "15"
$MaxBuildingLimit = Get-EnvOrDefault -Name "PAL_MAX_BUILDING_LIMIT" -Default "0"

foreach ($directory in @($DataDir, $ServerDir, $SteamDir, $LogsDir, $BackupsDir, $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

if (-not (Test-Path -LiteralPath $SteamCmd)) {
    $steamZip = Join-Path $env:TEMP "steamcmd.zip"
    Write-Host "*** Downloading SteamCMD"
    Invoke-WebRequest -UseBasicParsing -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $steamZip
    Expand-Archive -LiteralPath $steamZip -DestinationPath $SteamDir -Force
    Remove-Item -LiteralPath $steamZip -Force
}

if ($UpdateOnStart -or -not (Test-Path -LiteralPath $ServerExe)) {
    Invoke-SteamUpdate -SteamCmd $SteamCmd -ServerDir $ServerDir -Validate $ValidateOnUpdate
}

if (-not (Test-Path -LiteralPath $ServerExe)) {
    throw "Palworld command server executable was not found at $ServerExe."
}

if ($ModEnabled) {
    if (-not (Test-Path -LiteralPath $PalBridgeModSource)) {
        throw "The packaged PalBridge mod source was not found at $PalBridgeModSource."
    }

    Install-UE4SS `
        -Win64Dir $Win64Dir `
        -Release $UE4SSRelease `
        -DownloadUrl $UE4SSUrl `
        -Sha256 $UE4SSSha256 `
        -Force $UE4SSForceInstall

    # UE4SS 3.x uses Win64\Mods. New experimental builds use Win64\ue4ss\Mods.
    # Installing our source in both locations keeps the image compatible with either layout.
    Enable-UE4SSMod -ModsDir (Join-Path $Win64Dir "Mods") -SourceDir $PalBridgeModSource
    Enable-UE4SSMod -ModsDir (Join-Path $Win64Dir "ue4ss\Mods") -SourceDir $PalBridgeModSource
    Configure-UE4SS -SettingsPath (Join-Path $Win64Dir "UE4SS-settings.ini")
    Configure-UE4SS -SettingsPath (Join-Path $Win64Dir "ue4ss\UE4SS-settings.ini")
    Write-Host "*** PalBridge UE4SS mod installed and enabled"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $DefaultConfig)) {
        throw "DefaultPalWorldSettings.ini was not found at $DefaultConfig."
    }

    Copy-Item -LiteralPath $DefaultConfig -Destination $ConfigPath -Force
}

$config = Get-Content -LiteralPath $ConfigPath -Raw
$config = Set-PalSetting -Content $config -Name "ServerName" -Value ('"' + (Escape-PalString $ServerName) + '"')
$config = Set-PalSetting -Content $config -Name "ServerDescription" -Value ('"' + (Escape-PalString $ServerDescription) + '"')
$config = Set-PalSetting -Content $config -Name "ServerPassword" -Value ('"' + (Escape-PalString $ServerPassword) + '"')
$config = Set-PalSetting -Content $config -Name "AdminPassword" -Value ('"' + (Escape-PalString $AdminPassword) + '"')
$config = Set-PalSetting -Content $config -Name "ServerPlayerMaxNum" -Value $MaxPlayers
$config = Set-PalSetting -Content $config -Name "PublicIP" -Value ('"' + (Escape-PalString $PublicIp) + '"')
$config = Set-PalSetting -Content $config -Name "PublicPort" -Value $PublicPort
$config = Set-PalSetting -Content $config -Name "RCONEnabled" -Value "True"
$config = Set-PalSetting -Content $config -Name "RCONPort" -Value $(if ($BridgeEnabled) { $NativeRconPort } else { $RconPort })
$config = Set-PalSetting -Content $config -Name "RESTAPIEnabled" -Value "True"
$config = Set-PalSetting -Content $config -Name "RESTAPIPort" -Value $RestPort
$config = Set-PalSetting -Content $config -Name "LogFormatType" -Value $LogFormat
$config = Set-PalSetting -Content $config -Name "bIsShowJoinLeftMessage" -Value "True"
$config = Set-PalSetting -Content $config -Name "bIsUseBackupSaveData" -Value (ConvertTo-PalBoolean $UseBackupSaveData)
$config = Set-PalSetting -Content $config -Name "bAllowClientMod" -Value (ConvertTo-PalBoolean $AllowClientMod)
$config = Set-PalSetting -Content $config -Name "CrossplayPlatforms" -Value $CrossplayPlatforms
$config = Set-PalSetting -Content $config -Name "ChatPostLimitPerMinute" -Value $ChatPostLimitPerMinute
$config = Set-PalSetting -Content $config -Name "bIsPvP" -Value (ConvertTo-PalBoolean $PvpEnabled)
$config = Set-PalSetting -Content $config -Name "bEnablePlayerToPlayerDamage" -Value (ConvertTo-PalBoolean $PvpEnabled)
$config = Set-PalSetting -Content $config -Name "bEnableDefenseOtherGuildPlayer" -Value (ConvertTo-PalBoolean $PvpEnabled)
$config = Set-PalSetting -Content $config -Name "bHardcore" -Value (ConvertTo-PalBoolean $HardcoreEnabled)
$config = Set-PalSetting -Content $config -Name "DeathPenalty" -Value $DeathPenalty
$config = Set-PalSetting -Content $config -Name "bEnableInvaderEnemy" -Value (ConvertTo-PalBoolean $InvaderEnabled)
$config = Set-PalSetting -Content $config -Name "bEnableFastTravel" -Value (ConvertTo-PalBoolean $FastTravelEnabled)
$config = Set-PalSetting -Content $config -Name "bIsStartLocationSelectByMap" -Value (ConvertTo-PalBoolean $StartLocationSelect)
$config = Set-PalSetting -Content $config -Name "ExpRate" -Value $ExpRate
$config = Set-PalSetting -Content $config -Name "PalCaptureRate" -Value $CaptureRate
$config = Set-PalSetting -Content $config -Name "PalSpawnNumRate" -Value $SpawnRate
$config = Set-PalSetting -Content $config -Name "EnemyDropItemRate" -Value $EnemyDropRate
$config = Set-PalSetting -Content $config -Name "CollectionDropRate" -Value $CollectionDropRate
$config = Set-PalSetting -Content $config -Name "DayTimeSpeedRate" -Value $DayTimeSpeedRate
$config = Set-PalSetting -Content $config -Name "NightTimeSpeedRate" -Value $NightTimeSpeedRate
$config = Set-PalSetting -Content $config -Name "PalEggDefaultHatchingTime" -Value $EggHatchingTime
$config = Set-PalSetting -Content $config -Name "PlayerDamageRateAttack" -Value $PlayerDamageAttack
$config = Set-PalSetting -Content $config -Name "PlayerDamageRateDefense" -Value $PlayerDamageDefense
$config = Set-PalSetting -Content $config -Name "PalDamageRateAttack" -Value $PalDamageAttack
$config = Set-PalSetting -Content $config -Name "PalDamageRateDefense" -Value $PalDamageDefense
$config = Set-PalSetting -Content $config -Name "PlayerStomachDecreaceRate" -Value $PlayerHungerRate
$config = Set-PalSetting -Content $config -Name "PlayerStaminaDecreaceRate" -Value $PlayerStaminaRate
$config = Set-PalSetting -Content $config -Name "PalStomachDecreaceRate" -Value $PalHungerRate
$config = Set-PalSetting -Content $config -Name "PalStaminaDecreaceRate" -Value $PalStaminaRate
$config = Set-PalSetting -Content $config -Name "GuildPlayerMaxNum" -Value $GuildPlayerMax
$config = Set-PalSetting -Content $config -Name "BaseCampMaxNumInGuild" -Value $BaseCampMaxInGuild
$config = Set-PalSetting -Content $config -Name "BaseCampWorkerMaxNum" -Value $BaseCampWorkerMax
$config = Set-PalSetting -Content $config -Name "MaxBuildingLimitNum" -Value $MaxBuildingLimit
[IO.File]::WriteAllText($ConfigPath, $config, [Text.UTF8Encoding]::new($false))

$serverArguments = @(
    "Pal",
    "-port=$GamePort",
    "-players=$MaxPlayers",
    "-queryport=$QueryPort",
    "-publicport=$PublicPort",
    "-useperfthreads",
    "-NoAsyncLoadingThread",
    "-UseMultithreadForDS",
    "-logformat=$($LogFormat.ToLowerInvariant())"
)

if ($PublicLobby) {
    $serverArguments += "-publiclobby"
}

if (-not [string]::IsNullOrWhiteSpace($PublicIp)) {
    $serverArguments += "-publicip=$PublicIp"
}

if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) {
    $serverArguments += [Management.Automation.PSParser]::Tokenize($ExtraArgs, [ref]$null) |
        Where-Object { $_.Type -in @("CommandArgument", "Command") } |
        ForEach-Object { $_.Content }
}

$hostArguments = @(
    "--exe", $ServerExe,
    "--workdir", $ServerDir,
    "--log", $ConsoleLog,
    "--chat-log", $ChatLog,
    "--event-log", $EventLog,
    "--rest-url", "http://127.0.0.1:$RestPort",
    "--rest-user", "admin",
    "--rest-password", $AdminPassword,
    "--shutdown-wait", "5",
    "--poll-seconds", "10",
    "--capture-mode", $CaptureMode,
    "--"
) + $serverArguments

Write-Host "*** Starting Palworld through PalConHost"
Write-Host ("*** Server arguments: " + ($serverArguments -join " "))
$bridgeProcess = $null
try {
    if ($BridgeEnabled) {
        if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
            throw "PAL_ADMIN_PASSWORD must not be empty when PAL_BRIDGE_ENABLED is true."
        }

        $env:PAL_REST_URL = "http://127.0.0.1:$RestPort"
        $bridgeProcess = Start-Process `
            -FilePath "C:\GsaRconBridge.exe" `
            -PassThru `
            -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        if ($bridgeProcess.HasExited) {
            throw "GsaRconBridge exited during startup with code $($bridgeProcess.ExitCode)."
        }
        Write-Host "*** GSA Source RCON gateway listening on port $RconPort"
        Write-Host "*** Palworld native RCON compatibility port is internal-only on $NativeRconPort"
    }

    & "C:\PalConHost.exe" @hostArguments
    $exitCode = $LASTEXITCODE
}
finally {
    if ($null -ne $bridgeProcess -and -not $bridgeProcess.HasExited) {
        Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
        $bridgeProcess.WaitForExit(3000)
    }
}
Write-Host "*** Palworld wrapper exited with code $exitCode"
exit $exitCode
