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
    $pattern = '(?<=\(|,)' + $escapedName + '=(?:"(?:\\.|[^"])*"|\((?:[^()]|\([^()]*\))*\)|[^,\)]*)'
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

function Resolve-PalworldLayout {
    param(
        [Parameter(Mandatory = $true)][string]$PreferredRoot,
        [Parameter(Mandatory = $true)][string]$SearchRoot
    )

    $steamCmdRoot = Join-Path $SearchRoot "_steamcmd"
    $candidateRoots = @(
        $PreferredRoot,
        $SearchRoot,
        $steamCmdRoot
    ) | Select-Object -Unique

    $candidateExePaths = @(
        (Join-Path $PreferredRoot "Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"),
        (Join-Path $PreferredRoot "steamapps\common\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"),
        (Join-Path $SearchRoot "Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"),
        (Join-Path $SearchRoot "steamapps\common\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"),
        (Join-Path $steamCmdRoot "steamapps\common\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe")
    ) | Select-Object -Unique

    $serverExe = $null
    foreach ($candidate in $candidateExePaths) {
        if (Test-Path -LiteralPath $candidate) {
            $serverExe = $candidate
            break
        }
    }

    if ($null -eq $serverExe) {
        foreach ($root in $candidateRoots) {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }

            $match = Get-ChildItem `
                -LiteralPath $root `
                -Filter "PalServer-Win64-Shipping-Cmd.exe" `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $match) {
                $serverExe = $match.FullName
                break
            }
        }
    }

    if ($null -eq $serverExe) {
        return $null
    }

    $win64Dir = Split-Path -Parent $serverExe
    $binariesDir = Split-Path -Parent $win64Dir
    $palRoot = Split-Path -Parent $binariesDir
    $installRoot = Split-Path -Parent $palRoot

    $defaultConfigCandidates = @(
        (Join-Path $installRoot "DefaultPalWorldSettings.ini"),
        (Join-Path $palRoot "DefaultPalWorldSettings.ini")
    ) | Select-Object -Unique

    $defaultConfigPath = $defaultConfigCandidates[0]
    foreach ($candidate in $defaultConfigCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $defaultConfigPath = $candidate
            break
        }
    }

    if (-not (Test-Path -LiteralPath $defaultConfigPath)) {
        foreach ($root in @($installRoot, $palRoot) | Select-Object -Unique) {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }

            $match = Get-ChildItem `
                -LiteralPath $root `
                -Filter "DefaultPalWorldSettings.ini" `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $match) {
                $defaultConfigPath = $match.FullName
                break
            }
        }
    }

    return [PSCustomObject]@{
        InstallRoot = $installRoot
        PalRoot = $palRoot
        Win64Dir = $win64Dir
        ServerExe = $serverExe
        DefaultConfigPath = $defaultConfigPath
        ConfigPath = Join-Path $palRoot "Saved\Config\WindowsServer\PalWorldSettings.ini"
        NativeLogsDir = Join-Path $palRoot "Saved\Logs"
    }
}

function Invoke-PalworldInstall {
    param(
        [Parameter(Mandatory = $true)][string]$SteamCmdPath,
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$SearchRoot,
        [bool]$Validate,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $arguments = @(
            "+force_install_dir", $ServerRoot,
            "+login", "anonymous",
            "+app_update", "2394010"
        )

        if ($Validate) {
            $arguments += "validate"
        }

        $arguments += "+quit"

        Write-Host ("*** Installing or updating Palworld Dedicated Server (attempt {0}/{1})" -f $attempt, $MaxAttempts)
        & $SteamCmdPath @arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }

        $resolvedLayout = Resolve-PalworldLayout -PreferredRoot $ServerRoot -SearchRoot $SearchRoot
        $installLooksUsable = ($null -ne $resolvedLayout) -and
            (Test-Path -LiteralPath $resolvedLayout.ServerExe)

        if ($exitCode -eq 7 -and $installLooksUsable) {
            Write-Warning "SteamCMD returned exit code 7 after a usable Palworld install/update. Continuing."
            if (-not (Test-Path -LiteralPath $resolvedLayout.DefaultConfigPath)) {
                Write-Warning "DefaultPalWorldSettings.ini was not discovered; the launcher will bootstrap PalWorldSettings.ini directly."
            }
            return
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Warning ("SteamCMD attempt {0} failed with exit code {1}. Retrying after a short delay." -f $attempt, $exitCode)
            Start-Sleep -Seconds 5
            continue
        }

        throw "SteamCMD failed with exit code $exitCode."
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
        throw "PAL_UE4SS_URL must be set in the clean-room image defaults."
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
        if (Test-Path -LiteralPath $DefaultConfigPath) {
            Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
        } else {
            Write-Warning "DefaultPalWorldSettings.ini was not found. Creating a minimal PalWorldSettings.ini template."
            $seedContent = @(
                "[/Script/Pal.PalGameWorldSettings]",
                "OptionSettings=()"
            ) -join "`r`n"
            [IO.File]::WriteAllText($ConfigPath, $seedContent, [Text.UTF8Encoding]::new($false))
        }
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
$region = Get-EnvOrDefault -Name "PAL_REGION" -Default ""
$publicIp = Get-EnvOrDefault -Name "PAL_PUBLIC_IP" -Default ""
$gamePort = Get-EnvOrDefault -Name "PAL_GAME_PORT" -Default "7777"
$queryPort = Get-EnvOrDefault -Name "PAL_QUERY_PORT" -Default "27015"
$rconPort = Get-EnvOrDefault -Name "PAL_RCON_PORT" -Default "37015"
$restPort = Get-EnvOrDefault -Name "PAL_REST_PORT" -Default "8080"
$publicPort = Get-EnvOrDefault -Name "PAL_PUBLIC_PORT" -Default $gamePort
$slotLimit = Get-EnvOrDefault -Name "PAL_MAX_PLAYERS" -Default "32"
$crossplayPlatforms = Get-EnvOrDefault -Name "PAL_CROSSPLAY_PLATFORMS" -Default "(Steam,Xbox,PS5,Mac)"
$deathPenalty = Get-EnvOrDefault -Name "PAL_DEATH_PENALTY" -Default "All"
$expRate = Get-EnvOrDefault -Name "PAL_EXP_RATE" -Default "1.0"
$captureRate = Get-EnvOrDefault -Name "PAL_CAPTURE_RATE" -Default "1.0"
$spawnRate = Get-EnvOrDefault -Name "PAL_SPAWN_RATE" -Default "1.0"
$dayTimeSpeedRate = Get-EnvOrDefault -Name "PAL_DAY_TIME_SPEED_RATE" -Default "1.0"
$nightTimeSpeedRate = Get-EnvOrDefault -Name "PAL_NIGHT_TIME_SPEED_RATE" -Default "1.0"
$eggHatchingTime = Get-EnvOrDefault -Name "PAL_EGG_HATCHING_TIME" -Default "72.0"
$extraArgs = Get-EnvOrDefault -Name "PAL_EXTRA_ARGS" -Default ""

$gsaSteamMode = Get-BoolEnv -Name "PAL_GSA_STEAM_MODE" -Default $false
$publicLobby = Get-BoolEnv -Name "PAL_PUBLIC_LOBBY" -Default $true
$updateOnStart = Get-BoolEnv -Name "PAL_UPDATE_ON_START" -Default (-not $gsaSteamMode)
$validateOnUpdate = Get-BoolEnv -Name "PAL_VALIDATE_ON_UPDATE" -Default $false
$bridgeTrace = Get-BoolEnv -Name "PAL_BRIDGE_TRACE" -Default $false
$allowClientMod = Get-BoolEnv -Name "PAL_ALLOW_CLIENT_MOD" -Default $false
$pvpEnabled = Get-BoolEnv -Name "PAL_PVP_ENABLED" -Default $false
$invaderEnabled = Get-BoolEnv -Name "PAL_INVADER_ENABLED" -Default $true
$fastTravelEnabled = Get-BoolEnv -Name "PAL_FAST_TRAVEL_ENABLED" -Default $true

$ue4ssRelease = Get-EnvOrDefault -Name "PAL_UE4SS_RELEASE" -Default "v3.0.1"
$ue4ssUrl = Get-EnvOrDefault -Name "PAL_UE4SS_URL" -Default "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip"
$ue4ssSha256 = Get-EnvOrDefault -Name "PAL_UE4SS_SHA256" -Default ""

$steamCmdPath = Join-Path $steamCmdRoot "steamcmd.exe"
$serverLayout = $null
$serverExe = $null
$defaultConfigPath = $null
$configPath = $null
$win64Dir = $null

Ensure-Directory -Path $dataDir
Ensure-Directory -Path $logsDir
Ensure-Directory -Path $bridgeDir
Ensure-Directory -Path $serverRoot

Install-SteamCmd -SteamCmdPath $steamCmdPath -InstallRoot $steamCmdRoot

$serverLayout = Resolve-PalworldLayout -PreferredRoot $serverRoot -SearchRoot $dataDir

if ($updateOnStart -or $null -eq $serverLayout) {
    Invoke-PalworldInstall -SteamCmdPath $steamCmdPath -ServerRoot $serverRoot -SearchRoot $dataDir -Validate $validateOnUpdate
    $serverLayout = Resolve-PalworldLayout -PreferredRoot $serverRoot -SearchRoot $dataDir
}

if ($null -eq $serverLayout) {
    throw "Palworld command server executable was not found under $serverRoot or $dataDir after SteamCMD completed."
}

$serverExe = $serverLayout.ServerExe
$defaultConfigPath = $serverLayout.DefaultConfigPath
$configPath = $serverLayout.ConfigPath
$win64Dir = $serverLayout.Win64Dir

$settings = @{
    "ServerName" = '"' + (Escape-PalString $serverName) + '"'
    "ServerDescription" = '"' + (Escape-PalString $serverDescription) + '"'
    "ServerPassword" = '"' + (Escape-PalString $serverPassword) + '"'
    "AdminPassword" = '"' + (Escape-PalString $adminPassword) + '"'
    "ServerPlayerMaxNum" = $slotLimit
    "Region" = '"' + (Escape-PalString $region) + '"'
    "PublicIP" = '"' + (Escape-PalString $publicIp) + '"'
    "PublicPort" = $publicPort
    "QueryPort" = $queryPort
    "RCONEnabled" = "True"
    "RCONPort" = $rconPort
    "RESTAPIEnabled" = "True"
    "RESTAPIPort" = $restPort
    "LogFormatType" = "Text"
    "bAllowClientMod" = ConvertTo-PalBoolean $allowClientMod
    "CrossplayPlatforms" = $crossplayPlatforms
    "bIsPvP" = ConvertTo-PalBoolean $pvpEnabled
    "bEnablePlayerToPlayerDamage" = ConvertTo-PalBoolean $pvpEnabled
    "bEnableDefenseOtherGuildPlayer" = ConvertTo-PalBoolean $pvpEnabled
    "DeathPenalty" = $deathPenalty
    "bEnableInvaderEnemy" = ConvertTo-PalBoolean $invaderEnabled
    "bEnableFastTravel" = ConvertTo-PalBoolean $fastTravelEnabled
    "ExpRate" = $expRate
    "PalCaptureRate" = $captureRate
    "PalSpawnNumRate" = $spawnRate
    "DayTimeSpeedRate" = $dayTimeSpeedRate
    "NightTimeSpeedRate" = $nightTimeSpeedRate
    "PalEggDefaultHatchingTime" = $eggHatchingTime
}

Initialize-PalworldConfig -DefaultConfigPath $defaultConfigPath -ConfigPath $configPath -Settings $settings

Install-UE4SS -Win64Dir $win64Dir -Release $ue4ssRelease -DownloadUrl $ue4ssUrl -Sha256 $ue4ssSha256
$enabledMods = Copy-BuiltInMods -SourceRoot $modsSourceRoot -TargetRoot (Join-Path $win64Dir "Mods")
Write-ModManifest -ModsDir (Join-Path $win64Dir "Mods") -ModNames $enabledMods
Write-Host ("*** Installed built-in mods: " + ($(if ($enabledMods.Count -gt 0) { $enabledMods -join ", " } else { "none" })))

$launchArgs = @(
    "-port=$gamePort",
    "-players=$slotLimit",
    "-queryport=$queryPort",
    "-publicport=$publicPort",
    "-adminpassword=$adminPassword",
    "-RCONPort=$rconPort",
    "-logformat=text",
    "-useperfthreads",
    "-NoAsyncLoadingThread",
    "-UseMultithreadForDS"
)

if ($publicLobby) {
    $launchArgs += "-publiclobby"
}

if (-not [string]::IsNullOrWhiteSpace($publicIp)) {
    $launchArgs += "-publicip=$publicIp"
}

if (-not [string]::IsNullOrWhiteSpace($extraArgs)) {
    $launchArgs += $extraArgs
}

Write-Host "*** GSA-Compatible Palworld bootstrap"
Write-Host ("*** Install root: " + $serverLayout.InstallRoot)
Write-Host ("*** Executable: " + $serverExe)
Write-Host ("*** Config: " + $configPath)
Write-Host ("*** Logs directory: " + $logsDir)
Write-Host ("*** Bridge directory: " + $bridgeDir)
Write-Host ("*** GSA + Steam mode: " + $gsaSteamMode)
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
