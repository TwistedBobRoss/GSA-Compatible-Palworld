$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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
    $pattern = "(?<=\(|,)$escapedName=(?:`\"(?:\\.|[^`\"])*`\"|\((?:[^()]|\([^()]*\))*\)|[^,\)]*)"
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

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Install-SteamCmd {
    param(
        [Parameter(Mandatory = $true)][string]$SteamCmdPath,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    if (Test-Path -LiteralPath $SteamCmdPath) {
        return
    }

    Ensure-Directory -Path $InstallRoot
    $archive = Join-Path $env:TEMP "steamcmd.zip"
    Write-Host "*** Downloading SteamCMD"
    Invoke-WebRequest -UseBasicParsing -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $InstallRoot -Force
    Remove-Item -LiteralPath $archive -Force
}

function Invoke-PalworldInstall {
    param(
        [Parameter(Mandatory = $true)][string]$SteamCmdPath,
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [bool]$Validate
    )

    $arguments = @(
        "+force_install_dir", $ServerRoot,
        "+login", "anonymous",
        "+app_update", "2394010"
    )

    if ($Validate) {
        $arguments += "validate"
    }

    $arguments += "+quit"

    Write-Host "*** Installing or updating Palworld Dedicated Server"
    & $SteamCmdPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SteamCMD failed with exit code $LASTEXITCODE."
    }
}

function Install-UE4SS {
    param(
        [Parameter(Mandatory = $true)][string]$Win64Dir,
        [Parameter(Mandatory = $true)][string]$Release,
        [AllowEmptyString()][string]$DownloadUrl,
        [AllowEmptyString()][string]$Sha256
    )

    $proxyPath = Join-Path $Win64Dir "dwmapi.dll"
    if (Test-Path -LiteralPath $proxyPath) {
        Write-Host "*** UE4SS already present"
        return
    }

    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        throw "PAL_UE4SS_URL must be set when PAL_INSTALL_UE4SS is enabled in the clean-room image."
    }

    $archive = Join-Path $env:TEMP "ue4ss.zip"
    Write-Host "*** Downloading UE4SS"
    Invoke-WebRequest -UseBasicParsing -Headers @{ "User-Agent" = "GSA-Compatible-Palworld" } -Uri $DownloadUrl -OutFile $archive

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
        throw "UE4SS installation completed, but dwmapi.dll was not found at $Win64Dir."
    }

    Write-Host ("*** UE4SS installed from release " + $Release)
}

function Copy-BuiltInMods {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        Write-Host "*** No built-in mods directory found; skipping mod staging"
        return @()
    }

    Ensure-Directory -Path $TargetRoot
    $enabledMods = New-Object System.Collections.Generic.List[string]

    Get-ChildItem -LiteralPath $SourceRoot -Directory | Sort-Object Name | ForEach-Object {
        $destination = Join-Path $TargetRoot $_.Name
        Ensure-Directory -Path $destination
        Copy-Item -Path (Join-Path $_.FullName "*") -Destination $destination -Recurse -Force
        $enabledMods.Add($_.Name) | Out-Null
    }

    return $enabledMods.ToArray()
}

function Write-ModManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ModsDir,
        [Parameter(Mandatory = $true)][string[]]$ModNames
    )

    Ensure-Directory -Path $ModsDir
    $modsFile = Join-Path $ModsDir "mods.txt"

    $lines = @(
        "ActorDumperMod : 0",
        "BPML_GenericFunctions : 0",
        "BPModLoaderMod : 0",
        "CheatManagerEnablerMod : 0",
        "ConsoleCommandsMod : 0",
        "ConsoleEnablerMod : 0",
        "Keybinds : 0",
        "LineTraceMod : 0",
        "SplitScreenMod : 0",
        "jsbLuaProfilerMod : 0"
    )

    foreach ($modName in $ModNames) {
        $lines += "$modName : 1"
    }

    [IO.File]::WriteAllLines($modsFile, $lines, [Text.UTF8Encoding]::new($false))
}

function Initialize-PalworldConfig {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultConfigPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )

    $configDirectory = Split-Path -Parent $ConfigPath
    Ensure-Directory -Path $configDirectory

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not (Test-Path -LiteralPath $DefaultConfigPath)) {
            throw "DefaultPalWorldSettings.ini was not found at $DefaultConfigPath."
        }

        Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
    }

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    foreach ($entry in $Settings.GetEnumerator()) {
        $content = Set-PalSetting -Content $content -Name $entry.Key -Value $entry.Value
    }

    [IO.File]::WriteAllText($ConfigPath, $content, [Text.UTF8Encoding]::new($false))
}

$dataDir = Get-EnvOrDefault -Name "PAL_DATA_DIR" -Default "C:\serverfiles"
$steamCmdRoot = Get-EnvOrDefault -Name "PAL_STEAMCMD_DIR" -Default (Join-Path $dataDir "_steamcmd")
$logsDir = Get-EnvOrDefault -Name "PAL_LOG_DIR" -Default (Join-Path $dataDir "Logs")
$modsSourceRoot = Get-EnvOrDefault -Name "PAL_MODS_DIR" -Default "C:\image-mods"
$bridgeDir = Get-EnvOrDefault -Name "PAL_BRIDGE_DIR" -Default (Join-Path $dataDir "TKGBridge")
$serverRoot = Get-EnvOrDefault -Name "PAL_SERVER_ROOT" -Default $dataDir
$serverName = Get-EnvOrDefault -Name "PAL_SERVER_NAME" -Default "Palworld Server"
$serverDescription = Get-EnvOrDefault -Name "PAL_SERVER_DESCRIPTION" -Default "Palworld server hosted with GameServerApp"
$serverPassword = Get-EnvOrDefault -Name "PAL_SERVER_PASSWORD" -Default ""
$adminPassword = Get-EnvOrDefault -Name "PAL_ADMIN_PASSWORD" -Default ""
$publicIp = Get-EnvOrDefault -Name "PAL_PUBLIC_IP" -Default ""
$gamePort = Get-EnvOrDefault -Name "PAL_GAME_PORT" -Default "8211"
$queryPort = Get-EnvOrDefault -Name "PAL_QUERY_PORT" -Default "27015"
$restPort = Get-EnvOrDefault -Name "PAL_REST_PORT" -Default "8212"
$publicPort = Get-EnvOrDefault -Name "PAL_PUBLIC_PORT" -Default $gamePort
$slotLimit = Get-EnvOrDefault -Name "PAL_MAX_PLAYERS" -Default "32"
$crossplayPlatforms = Get-EnvOrDefault -Name "PAL_CROSSPLAY_PLATFORMS" -Default "(Steam,Xbox,PS5,Mac)"
$chatPostLimit = Get-EnvOrDefault -Name "PAL_CHAT_POST_LIMIT" -Default "10"
$deathPenalty = Get-EnvOrDefault -Name "PAL_DEATH_PENALTY" -Default "All"
$expRate = Get-EnvOrDefault -Name "PAL_EXP_RATE" -Default "1.0"
$captureRate = Get-EnvOrDefault -Name "PAL_CAPTURE_RATE" -Default "1.0"
$spawnRate = Get-EnvOrDefault -Name "PAL_SPAWN_RATE" -Default "1.0"
$enemyDropRate = Get-EnvOrDefault -Name "PAL_ENEMY_DROP_RATE" -Default "1.0"
$collectionDropRate = Get-EnvOrDefault -Name "PAL_COLLECTION_DROP_RATE" -Default "1.0"
$dayTimeSpeedRate = Get-EnvOrDefault -Name "PAL_DAY_TIME_SPEED_RATE" -Default "1.0"
$nightTimeSpeedRate = Get-EnvOrDefault -Name "PAL_NIGHT_TIME_SPEED_RATE" -Default "1.0"
$eggHatchingTime = Get-EnvOrDefault -Name "PAL_EGG_HATCHING_TIME" -Default "72.0"
$playerDamageAttack = Get-EnvOrDefault -Name "PAL_PLAYER_DAMAGE_ATTACK" -Default "1.0"
$playerDamageDefense = Get-EnvOrDefault -Name "PAL_PLAYER_DAMAGE_DEFENSE" -Default "1.0"
$palDamageAttack = Get-EnvOrDefault -Name "PAL_PAL_DAMAGE_ATTACK" -Default "1.0"
$palDamageDefense = Get-EnvOrDefault -Name "PAL_PAL_DAMAGE_DEFENSE" -Default "1.0"
$playerHungerRate = Get-EnvOrDefault -Name "PAL_PLAYER_HUNGER_RATE" -Default "1.0"
$playerStaminaRate = Get-EnvOrDefault -Name "PAL_PLAYER_STAMINA_RATE" -Default "1.0"
$palHungerRate = Get-EnvOrDefault -Name "PAL_PAL_HUNGER_RATE" -Default "1.0"
$palStaminaRate = Get-EnvOrDefault -Name "PAL_PAL_STAMINA_RATE" -Default "1.0"
$guildPlayerMax = Get-EnvOrDefault -Name "PAL_GUILD_PLAYER_MAX" -Default "20"
$baseCampMaxInGuild = Get-EnvOrDefault -Name "PAL_BASE_CAMP_MAX_IN_GUILD" -Default "4"
$baseCampWorkerMax = Get-EnvOrDefault -Name "PAL_BASE_CAMP_WORKER_MAX" -Default "15"
$maxBuildingLimit = Get-EnvOrDefault -Name "PAL_MAX_BUILDING_LIMIT" -Default "0"
$extraArgs = Get-EnvOrDefault -Name "PAL_EXTRA_ARGS" -Default ""

$publicLobby = Get-BoolEnv -Name "PAL_PUBLIC_LOBBY" -Default $true
$updateOnStart = Get-BoolEnv -Name "PAL_UPDATE_ON_START" -Default $true
$validateOnUpdate = Get-BoolEnv -Name "PAL_VALIDATE_ON_UPDATE" -Default $false
$installUE4SS = Get-BoolEnv -Name "PAL_INSTALL_UE4SS" -Default $false
$bridgeTrace = Get-BoolEnv -Name "PAL_BRIDGE_TRACE" -Default $false
$allowClientMod = Get-BoolEnv -Name "PAL_ALLOW_CLIENT_MOD" -Default $false
$useBackupSaveData = Get-BoolEnv -Name "PAL_USE_BACKUP_SAVE_DATA" -Default $true
$showJoinLeave = Get-BoolEnv -Name "PAL_SHOW_JOIN_LEAVE" -Default $true
$pvpEnabled = Get-BoolEnv -Name "PAL_PVP_ENABLED" -Default $false
$hardcoreEnabled = Get-BoolEnv -Name "PAL_HARDCORE_ENABLED" -Default $false
$invaderEnabled = Get-BoolEnv -Name "PAL_INVADER_ENABLED" -Default $true
$fastTravelEnabled = Get-BoolEnv -Name "PAL_FAST_TRAVEL_ENABLED" -Default $true
$startLocationSelect = Get-BoolEnv -Name "PAL_START_LOCATION_SELECT" -Default $true

$ue4ssRelease = Get-EnvOrDefault -Name "PAL_UE4SS_RELEASE" -Default "manual"
$ue4ssUrl = Get-EnvOrDefault -Name "PAL_UE4SS_URL" -Default ""
$ue4ssSha256 = Get-EnvOrDefault -Name "PAL_UE4SS_SHA256" -Default ""

$steamCmdPath = Join-Path $steamCmdRoot "steamcmd.exe"
$serverExe = Join-Path $serverRoot "Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"
$defaultConfigPath = Join-Path $serverRoot "DefaultPalWorldSettings.ini"
$configPath = Join-Path $serverRoot "Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"
$win64Dir = Split-Path -Parent $serverExe

Ensure-Directory -Path $dataDir
Ensure-Directory -Path $logsDir
Ensure-Directory -Path $bridgeDir
Ensure-Directory -Path $serverRoot

Install-SteamCmd -SteamCmdPath $steamCmdPath -InstallRoot $steamCmdRoot

if ($updateOnStart -or -not (Test-Path -LiteralPath $serverExe)) {
    Invoke-PalworldInstall -SteamCmdPath $steamCmdPath -ServerRoot $serverRoot -Validate $validateOnUpdate
}

if (-not (Test-Path -LiteralPath $serverExe)) {
    throw "Palworld command server executable was not found at $serverExe."
}

$settings = @{
    "ServerName" = '"' + (Escape-PalString $serverName) + '"'
    "ServerDescription" = '"' + (Escape-PalString $serverDescription) + '"'
    "ServerPassword" = '"' + (Escape-PalString $serverPassword) + '"'
    "AdminPassword" = '"' + (Escape-PalString $adminPassword) + '"'
    "ServerPlayerMaxNum" = $slotLimit
    "PublicIP" = '"' + (Escape-PalString $publicIp) + '"'
    "PublicPort" = $publicPort
    "QueryPort" = $queryPort
    "RCONEnabled" = "False"
    "RESTAPIEnabled" = "True"
    "RESTAPIPort" = $restPort
    "LogFormatType" = "Text"
    "bIsShowJoinLeftMessage" = ConvertTo-PalBoolean $showJoinLeave
    "bIsUseBackupSaveData" = ConvertTo-PalBoolean $useBackupSaveData
    "bAllowClientMod" = ConvertTo-PalBoolean $allowClientMod
    "CrossplayPlatforms" = $crossplayPlatforms
    "ChatPostLimitPerMinute" = $chatPostLimit
    "bIsPvP" = ConvertTo-PalBoolean $pvpEnabled
    "bEnablePlayerToPlayerDamage" = ConvertTo-PalBoolean $pvpEnabled
    "bEnableDefenseOtherGuildPlayer" = ConvertTo-PalBoolean $pvpEnabled
    "bHardcore" = ConvertTo-PalBoolean $hardcoreEnabled
    "DeathPenalty" = $deathPenalty
    "bEnableInvaderEnemy" = ConvertTo-PalBoolean $invaderEnabled
    "bEnableFastTravel" = ConvertTo-PalBoolean $fastTravelEnabled
    "bIsStartLocationSelectByMap" = ConvertTo-PalBoolean $startLocationSelect
    "ExpRate" = $expRate
    "PalCaptureRate" = $captureRate
    "PalSpawnNumRate" = $spawnRate
    "EnemyDropItemRate" = $enemyDropRate
    "CollectionDropRate" = $collectionDropRate
    "DayTimeSpeedRate" = $dayTimeSpeedRate
    "NightTimeSpeedRate" = $nightTimeSpeedRate
    "PalEggDefaultHatchingTime" = $eggHatchingTime
    "PlayerDamageRateAttack" = $playerDamageAttack
    "PlayerDamageRateDefense" = $playerDamageDefense
    "PalDamageRateAttack" = $palDamageAttack
    "PalDamageRateDefense" = $palDamageDefense
    "PlayerStomachDecreaceRate" = $playerHungerRate
    "PlayerStaminaDecreaceRate" = $playerStaminaRate
    "PalStomachDecreaceRate" = $palHungerRate
    "PalStaminaDecreaceRate" = $palStaminaRate
    "GuildPlayerMaxNum" = $guildPlayerMax
    "BaseCampMaxNumInGuild" = $baseCampMaxInGuild
    "BaseCampWorkerMaxNum" = $baseCampWorkerMax
    "MaxBuildingLimitNum" = $maxBuildingLimit
}

Initialize-PalworldConfig -DefaultConfigPath $defaultConfigPath -ConfigPath $configPath -Settings $settings

if ($installUE4SS) {
    Install-UE4SS -Win64Dir $win64Dir -Release $ue4ssRelease -DownloadUrl $ue4ssUrl -Sha256 $ue4ssSha256
    $enabledMods = Copy-BuiltInMods -SourceRoot $modsSourceRoot -TargetRoot (Join-Path $win64Dir "Mods")
    Write-ModManifest -ModsDir (Join-Path $win64Dir "Mods") -ModNames $enabledMods
    Write-Host ("*** Installed built-in mods: " + ($(if ($enabledMods.Count -gt 0) { $enabledMods -join ", " } else { "none" })))
} else {
    Write-Host "*** UE4SS installation disabled for this run"
}

$launchArgs = @(
    "-port=$gamePort",
    "-queryport=$queryPort",
    "-useperfthreads",
    "-NoAsyncLoadingThread",
    "-UseMultithreadForDS"
)

if ($publicLobby) {
    $launchArgs += "-publiclobby"
}

if (-not [string]::IsNullOrWhiteSpace($extraArgs)) {
    $launchArgs += $extraArgs
}

Write-Host "*** GSA-Compatible Palworld bootstrap"
Write-Host ("*** Executable: " + $serverExe)
Write-Host ("*** Config: " + $configPath)
Write-Host ("*** Logs directory: " + $logsDir)
Write-Host ("*** Bridge directory: " + $bridgeDir)
Write-Host ("*** Bridge trace: " + $bridgeTrace)
Write-Host ("*** Launch args: " + ($launchArgs -join " "))

Push-Location $win64Dir
try {
    & $serverExe @launchArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
