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
    PAL_BRIDGE_LEDGER="C:\serverfiles\PalBridge\ledger" `
    PAL_BRIDGE_LOG="C:\serverfiles\Logs\PalBridge.log" `
    PALDEFENDER_REST_URL="http://127.0.0.1:17993" `
    PALDEFENDER_TOKEN_FILE="C:\serverfiles\Pal\Binaries\Win64\PalDefender\RESTAPI\Tokens\GSA.json" `
    PAL_USE_BACKUP_SAVE_DATA="true" `
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

EXPOSE 8211/udp
EXPOSE 27015/udp
EXPOSE 25575/tcp

ENTRYPOINT ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", "C:\\Start.ps1"]
