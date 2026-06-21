# GSA-Compatible Palworld

Experimental Windows Server 2022 container and GameServerApp blueprint for running the official Palworld Windows dedicated server with usable console, event, and chat logs.

## What This Changes

The stock Windows flow commonly launches:

```text
PalServer.exe
```

This project launches the command-oriented server binary directly:

```text
Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe
```

`PalConHost.exe` captures that process, copies its output to Docker stdout for the GSA container log, and writes persistent files under:

```text
\serverfiles\Logs\PalServer-console.log
\serverfiles\Logs\PalServer-chat.log
\serverfiles\Logs\PalServer-events.log
```

The blueprint also registers both `\serverfiles\Logs` and `\serverfiles\Pal\Saved\Logs` as GSA `Logs` directories.

## GSA Documentation Verification

The implementation follows the public GameServerApp blueprint documentation:

- The custom-container flow follows GSA's documented **Import Custom Docker Container** process.
- Persistent files are mounted from `{container.home_root}/serverfiles`; GSA documents `{container.home_root}` as the game server container folder.
- Docker stdout appears in the game server's Docker container logs.
- The blueprint registers directories with type `logs`, which GSA automatically scans for its Logs page.
- RCON is configured as command/control.
- Container monitoring with recovery is enabled.

GSA does **not** publicly document a custom chat/player event tag grammar for blueprint authors. Because of that, this wrapper does not replace native Palworld output with invented tags.

It preserves raw output and writes normalized fallback lines using the native formats commonly emitted by Palworld:

```text
[2026-06-20 12:00:00Z] [CHAT] <PlayerName> message
[2026-06-20 12:00:00Z] [LOG] PlayerName joined the server. (User id: steam_..., Player id: AFAFD830...)
[2026-06-20 12:00:00Z] [LOG] PlayerName left the server. (User id: steam_...)
```

For the best chance of GSA dashboard chat/player indexing, create or import this as a **Palworld** blueprint rather than as an unrelated custom game. The separate log files remain available even if GSA's private Palworld parser does not ingest a particular line.

## Player Event Recovery

Palworld's REST API is enabled only on the container-internal port `8212`. It is deliberately **not** published to the host because Pocketpair warns that the REST API is not designed for direct Internet exposure. Every ten seconds, `PalConHost` checks `/v1/api/players` over `127.0.0.1`.

If the Windows console omits a join or leave line, the wrapper synthesizes the corresponding native-style `[LOG]` line. The current REST response includes both the platform `userId` and Palworld `playerId`, so the synthesized join contains the character identity GSA needs.

GSA command/control remains on the mapped RCON port. Pocketpair currently marks RCON as deprecated, so the wrapper independently uses the internal REST API for save and shutdown handling.

## Packaged Chat and Delivery Mod

The image packages our `PalBridge` Lua mod and installs a checksum-pinned official UE4SS build into Palworld's `Win64` directory on first start. The mod:

- hooks `PalPlayerState:EnterChat_Receive`
- emits native-style `[CHAT]` lines to Docker stdout
- writes chat/character identity audit lines under `\serverfiles\Logs`
- consumes item requests from `\serverfiles\PalBridge\queue`
- grants through Palworld's server-side `AddItem_ServerInternal` function

No PalGuard or PalDefender installation is required. UE4SS's optional debugging and cheat mods are disabled; only `PalBridge` is enabled.

The exact GSA account-linking validation is in [`GSA-CONNECT-CODE.md`](GSA-CONNECT-CODE.md). GSA does not publish its Palworld parser expressions, so a live `!getconnectcode` test remains required before production cutover.

## Beginner-Friendly GSA Configuration

The included blueprint is populated with vanilla-style defaults and exposes normal server administration as individual GSA fields instead of requiring operators to edit Palworld's single-line `OptionSettings` tuple.

The fields are grouped into:

- **Server**: description, public listing, public IP, and save backups
- **Access**: password, allowed platforms, modded clients, and chat rate limit
- **Gameplay**: PvP, Hardcore, death penalty, raids, fast travel, and starting-location selection
- **Rates**: experience, capture, spawns, drops, day/night speed, and egg incubation
- **Combat**: player and Pal damage multipliers
- **Survival**: hunger and stamina multipliers
- **World Limits**: guild size, bases, workers, and structures
- **Install**: SteamCMD update and validation behavior
- **Advanced**: pinned UE4SS package information and extra launch arguments

The GSA game-server name and slot limit remain the source of truth for `ServerName` and `ServerPlayerMaxNum`. The generated `PalWorldSettings.ini` is read-only in the Config Template because the container rebuilds its managed values from these fields whenever it starts.

## Capture Modes

The default is:

```text
PAL_CAPTURE_MODE=pipe
```

This mode is tested to capture, split, and persist console/chat/player lines. A `conpty` mode is included for investigation, but it is not the recommended default until it is validated inside the target GSA Windows container.

## Future-Proof GSA Command Gateway

`GsaRconBridge.exe` provides its own Source RCON-compatible endpoint on GSA's allocated RCON port. This endpoint is independent of Pocketpair's deprecated native RCON implementation.

While native Palworld RCON is available, it is moved to the container-internal port `25576`. Commands that the gateway does not handle can be proxied there. If Pocketpair removes native RCON, the GSA gateway, Palworld REST control commands, and mod-backed delivery commands continue to work.

Implemented gateway routes:

```text
palbridge ping
palbridge version
palbridge give --delivery "{delivery.id}" --character "{character.id}" --player "{player.id}" --item "ITEM_ID" --count 1
Save
Broadcast message
Shutdown 5 message
Info
ShowPlayers
```

The `give` route first checks Palworld REST and requires `{character.id}` and `{player.id}` to identify the same online player. It then queues the operation to the packaged mod. Character names are never used as delivery targets.

Every delivery is persisted under:

```text
\serverfiles\PalBridge\ledger
```

Completed deliveries are returned as `already_delivered` when GSA retries the same `{delivery.id}`. If the gateway loses contact during an uncertain backend operation, it stops automatic retries and records the delivery for reconciliation rather than risking duplicate items.

The required wire behavior and release tests are defined in [`RCON-COMPATIBILITY.md`](RCON-COMPATIBILITY.md).

Local interoperability has been verified with two independent Source RCON clients (`rcon 2.4.9` and `mctools 1.3.0`). GSA's selected `rcon_1` implementation still requires the temporary-server acceptance test.

## Existing Server Migration

Before switching the running server:

1. Stop it and create/download a GSA backup.
2. Confirm its files are under the normal `serverfiles` mount.
3. Activate the new blueprint while preserving that same mount.
4. Delete/recreate only the container if GSA requires it. Do not wipe `serverfiles`.
5. Start and watch the Docker log.
6. Join, send a chat message, and leave.
7. Check all three files under `\serverfiles\Logs`.

The wrapper preserves the existing `PalWorldSettings.ini` and patches only:

- server name and description
- server/admin passwords
- slot count
- public IP/port
- RCON and REST enablement/ports
- text log format
- join/leave messages
- built-in save backups

## Build

Build and publish the Windows Server 2022 image used by the included blueprint:

```powershell
docker build --build-arg WINDOWS_VERSION=ltsc2022 -t ghcr.io/twistedbobross/gsa-compatible-palworld:ltsc2022 .
```

Publish that image, then import:

```text
blueprints\palworld-gsa-windows-logging.json
```

or use:

```text
docker-run.gsa-import.txt
```

The JSON blueprint is the preferred import. The Docker command is a standards-compliant seed for GSA's **Import Custom Docker Container** wizard; after importing it, apply the paths, variables, directories, and config parameters from the JSON blueprint.

## Test Acceptance Criteria

Do not replace the existing production server until a temporary copy passes:

- GSA Docker log shows live Palworld output.
- `PalServer-console.log` receives the same output.
- A player chat message appears in `PalServer-chat.log`.
- Join and leave activity appears in `PalServer-events.log`.
- GSA can query the server.
- GSA save and shutdown complete without save corruption.
- The server remains stable through an extended test using pipe capture.
- GSA authenticates to `GsaRconBridge` using the blueprint's `rcon_1` implementation.
- `palbridge ping` works from GSA's command console.
- A player can type `!getconnectcode` twice and GSA attributes both messages to the correct character.
- GSA returns a connect code and the Community website links the intended account.
- A Shop Pack command containing `{delivery.id}`, `{character.id}`, and `{player.id}` delivers once.
- A mismatched character/platform pair is rejected.
- Retrying the same delivery returns `already_delivered` without granting it again.

## Documentation References

- [GameServerApp: Create and manage blueprints](https://docs.gameserverapp.com/dashboard/blueprints/create_and_manage_blueprints/)
- [GameServerApp: Create Docker blueprint](https://docs.gameserverapp.com/dashboard/blueprints/how-to/create_custom_blueprint/)
- [GameServerApp: Blueprint variables](https://docs.gameserverapp.com/dashboard/blueprints/variables/)
- [GameServerApp: Connect game accounts](https://docs.gameserverapp.com/dashboard/community/website/)
- [GameServerApp: Delivery Builder variables](https://docs.gameserverapp.com/dashboard/delivery_builder/variables/)
- [Pocketpair: Palworld launch arguments](https://docs.palworldgame.com/settings-and-operation/arguments/)
- [Pocketpair: Palworld configuration parameters](https://docs.palworldgame.com/settings-and-operation/configuration/)
- [Pocketpair: Palworld REST player list](https://docs.palworldgame.com/api/rest-api/players/)
- [Pocketpair: Palworld RCON deprecation](https://docs.palworldgame.com/api/rcon/)
- [UE4SS project](https://github.com/UE4SS-RE/RE-UE4SS)
- [Microsoft: Windows Pseudoconsole](https://learn.microsoft.com/windows/console/creating-a-pseudoconsole-session)
