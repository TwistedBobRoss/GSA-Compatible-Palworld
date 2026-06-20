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
        [Parameter(Mandatory = $true)][string]$Default
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

function Set-PalSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escapedName = [Regex]::Escape($Name)
    $pattern = "(?<=\(|,)$escapedName=(?:`"(?:\\.|[^`"])*`"|[^,\)]*)"
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
$UpdateOnStart = Get-BoolEnv -Name "PAL_UPDATE_ON_START" -Default $true
$ValidateOnUpdate = Get-BoolEnv -Name "PAL_VALIDATE_ON_UPDATE" -Default $false
$PublicLobby = Get-BoolEnv -Name "PAL_PUBLIC_LOBBY" -Default $true
$UseBackupSaveData = Get-BoolEnv -Name "PAL_USE_BACKUP_SAVE_DATA" -Default $true

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
$config = Set-PalSetting -Content $config -Name "bIsUseBackupSaveData" -Value $(if ($UseBackupSaveData) { "True" } else { "False" })
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
