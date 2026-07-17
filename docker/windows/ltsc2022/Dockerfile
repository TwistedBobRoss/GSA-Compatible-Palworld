# escape=`
ARG WINDOWS_VERSION=ltsc2022
FROM mcr.microsoft.com/windows/servercore:${WINDOWS_VERSION}

SHELL ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-Command"]

WORKDIR C:\

ENV PAL_DATA_DIR="C:\serverfiles" `
    PAL_STEAMCMD_DIR="C:\serverfiles\_steamcmd" `
    PAL_SERVER_ROOT="C:\serverfiles\PalServer" `
    PAL_SERVER_NAME="Palworld Server" `
    PAL_SERVER_DESCRIPTION="Palworld server hosted with GameServerApp" `
    PAL_SERVER_PASSWORD="" `
    PAL_ADMIN_PASSWORD="" `
    PAL_GAME_PORT="8211" `
    PAL_QUERY_PORT="27015" `
    PAL_REST_PORT="8212" `
    PAL_PUBLIC_PORT="8211" `
    PAL_PUBLIC_IP="" `
    PAL_PUBLIC_LOBBY="true" `
    PAL_MAX_PLAYERS="32" `
    PAL_UPDATE_ON_START="true" `
    PAL_VALIDATE_ON_UPDATE="false" `
    PAL_LOG_DIR="C:\serverfiles\Logs" `
    PAL_BRIDGE_DIR="C:\serverfiles\TKGBridge" `
    PAL_BRIDGE_TRACE="false" `
    PAL_MODS_DIR="C:\image-mods" `
    PAL_UE4SS_RELEASE="v3.0.1" `
    PAL_UE4SS_URL="https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip" `
    PAL_UE4SS_SHA256="" `
    PAL_ALLOW_CLIENT_MOD="false" `
    PAL_USE_BACKUP_SAVE_DATA="true" `
    PAL_SHOW_JOIN_LEAVE="true" `
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
    PAL_EXTRA_ARGS=""

COPY scripts\Start.ps1 C:\Start.ps1
COPY mods C:\image-mods

EXPOSE 8211/udp
EXPOSE 27015/udp

ENTRYPOINT ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", "C:\\Start.ps1"]
