# escape=`
ARG WINDOWS_VERSION=ltsc2022
FROM mcr.microsoft.com/windows/servercore:${WINDOWS_VERSION}

SHELL ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-Command"]

WORKDIR C:\

ENV PAL_DATA_DIR="C:\serverfiles" `
    PAL_GAME_PORT="8211" `
    PAL_QUERY_PORT="27015" `
    PAL_RCON_PORT="25575" `
    PAL_NATIVE_RCON_PORT="25576" `
    PAL_REST_PORT="8212" `
    PAL_MAX_PLAYERS="32" `
    PAL_SERVER_NAME="Palworld Server" `
    PAL_SERVER_DESCRIPTION="Palworld server hosted with GameServerApp" `
    PAL_SERVER_PASSWORD="" `
    PAL_ADMIN_PASSWORD="" `
    PAL_PUBLIC_IP="" `
    PAL_PUBLIC_PORT="8211" `
    PAL_PUBLIC_LOBBY="true" `
    PAL_LOG_FORMAT="Text" `
    PAL_CAPTURE_MODE="pipe" `
    PAL_BRIDGE_ENABLED="true" `
    PAL_BRIDGE_LISTEN_ADDRESS="0.0.0.0" `
    PAL_BRIDGE_PROXY_NATIVE="true" `
    PAL_BRIDGE_AUTH_EMPTY_RESPONSE="false" `
    PAL_BRIDGE_QUEUE="C:\serverfiles\PalBridge\queue" `
    PAL_BRIDGE_DELIVERY_TIMEOUT="10" `
    PAL_BRIDGE_LEDGER="C:\serverfiles\PalBridge\ledger" `
    PAL_BRIDGE_LOG="C:\serverfiles\Logs\PalBridge.log" `
    PAL_MOD_ENABLED="true" `
    PAL_UE4SS_RELEASE="experimental-latest" `
    PAL_UE4SS_URL="https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/UE4SS_v3.0.1-971-g9ec5ece7.zip" `
    PAL_UE4SS_SHA256="476D6D38627B0905723288D95AB7ACB5FCD2834879455684B9DEF47A6007B8D5" `
    PAL_UE4SS_FORCE_INSTALL="false" `
    PAL_LOGS_DIR="C:\serverfiles\Logs" `
    PAL_USE_BACKUP_SAVE_DATA="true" `
    PAL_ALLOW_CLIENT_MOD="false" `
    PAL_CROSSPLAY_PLATFORMS="(Steam,Xbox,PS5,Mac)" `
    PAL_CHAT_POST_LIMIT="10" `
    PAL_PVP_ENABLED="false" `
    PAL_HARDCORE_ENABLED="false" `
    PAL_DEATH_PENALTY="All" `
    PAL_INVADER_ENABLED="true" `
    PAL_FAST_TRAVEL_ENABLED="true" `
    PAL_START_LOCATION_SELECT="true" `
    PAL_EXP_RATE="1.0" `
    PAL_CAPTURE_RATE="1.0" `
    PAL_SPAWN_RATE="1.0" `
    PAL_ENEMY_DROP_RATE="1.0" `
    PAL_COLLECTION_DROP_RATE="1.0" `
    PAL_DAY_TIME_SPEED_RATE="1.0" `
    PAL_NIGHT_TIME_SPEED_RATE="1.0" `
    PAL_EGG_HATCHING_TIME="72.0" `
    PAL_PLAYER_DAMAGE_ATTACK="1.0" `
    PAL_PLAYER_DAMAGE_DEFENSE="1.0" `
    PAL_PAL_DAMAGE_ATTACK="1.0" `
    PAL_PAL_DAMAGE_DEFENSE="1.0" `
    PAL_PLAYER_HUNGER_RATE="1.0" `
    PAL_PLAYER_STAMINA_RATE="1.0" `
    PAL_PAL_HUNGER_RATE="1.0" `
    PAL_PAL_STAMINA_RATE="1.0" `
    PAL_GUILD_PLAYER_MAX="20" `
    PAL_BASE_CAMP_MAX_IN_GUILD="4" `
    PAL_BASE_CAMP_WORKER_MAX="15" `
    PAL_MAX_BUILDING_LIMIT="0" `
    PAL_UPDATE_ON_START="true" `
    PAL_VALIDATE_ON_UPDATE="false" `
    PAL_EXTRA_ARGS=""

COPY src\PalConHost.cs C:\build\PalConHost.cs
COPY src\GsaRconBridge.cs C:\build\GsaRconBridge.cs
RUN & 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' `
        /nologo `
        /optimize+ `
        /target:exe `
        /reference:System.Web.Extensions.dll `
        /out:C:\PalConHost.exe `
        C:\build\PalConHost.cs; `
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; `
    & 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' `
        /nologo `
        /optimize+ `
        /target:exe `
        /reference:System.Web.Extensions.dll `
        /out:C:\GsaRconBridge.exe `
        C:\build\GsaRconBridge.cs; `
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; `
    Remove-Item -Recurse -Force C:\build

COPY scripts\Start.ps1 C:\Start.ps1
COPY mods\PalBridge C:\PalBridgeMod

EXPOSE 8211/udp
EXPOSE 27015/udp
EXPOSE 25575/tcp

ENTRYPOINT ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", "C:\\Start.ps1"]
