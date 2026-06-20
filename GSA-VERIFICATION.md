# GSA Documentation Verification

Verified against the public GameServerApp documentation on June 19, 2026.

| Implementation | Documentation result |
| --- | --- |
| Import as a Windows custom Docker container | Supported. GSA documents this workflow using Path of Titans as its example. |
| Persist files from `{container.home_root}/serverfiles` | Supported. `{container.home_root}` is a documented blueprint variable, and custom-container mounts are supported. |
| Register `\serverfiles\Logs` and Palworld's native log directory as type `logs` | Supported. GSA states that `Logs` directories are automatically scanned and listed on the server Logs page. |
| Mirror Palworld output to Docker stdout | Supported for visibility. GSA directs blueprint testing through Docker container logs and also offers Executable Log Output for games without file logging. |
| Use `{gameserver.game_port}`, `{gameserver.query_port}`, `{gameserver.rcon_port}`, `{gameserver.rcon_password}`, `{gameserver.slot_limit}`, and `{gameserver.list_name}` | Supported documented variables. |
| Use `{dynamic-os-tag}` for the image tag | Supported and recommended by GSA for Windows Server 2019/2022 compatibility. Both corresponding image tags must be published. |
| Use RCON for GSA command/control | Supported by GSA, but Pocketpair marks Palworld RCON as deprecated. |
| Provide our own Source RCON gateway on GSA's allocated RCON port | Supported in principle: GSA accepts RCON command/control connections and offers multiple implementations. Local Source RCON protocol tests pass; the selected `rcon_1` implementation still requires a live GSA acceptance test. |
| Poll Palworld REST on `127.0.0.1:8212` | Supported by Pocketpair. The port is intentionally not published because Pocketpair warns against direct Internet exposure. |
| Custom `[GSA]` chat or player tags | Not documented. The wrapper therefore preserves Palworld's native `[CHAT]` and `[LOG]` forms instead of inventing a GSA-specific grammar. |

## What Still Requires a Live GSA Test

Public GSA documentation does not describe its internal Palworld chat/player parser. The files and Docker output are guaranteed by the documented logging mechanisms, but dashboard chat/player indexing must be confirmed on a temporary GSA server.

## Sources

- [Create and manage blueprints](https://docs.gameserverapp.com/dashboard/blueprints/create_and_manage_blueprints/)
- [Create Docker blueprint](https://docs.gameserverapp.com/dashboard/blueprints/how-to/create_custom_blueprint/)
- [Blueprint variables](https://docs.gameserverapp.com/dashboard/blueprints/variables/)
- [Palworld configuration parameters](https://docs.palworldgame.com/settings-and-operation/configuration/)
- [Palworld REST API](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Palworld RCON](https://docs.palworldgame.com/api/rcon/)
