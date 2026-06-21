# GSA `!getconnectcode` Contract

The purpose of this image is to let GameServerApp associate the correct platform account with the correct Palworld character before it performs a delivery.

## Identity fields

Palworld's current REST `/players` response supplies:

- `userId`: platform account identity, such as `steam_...`
- `playerId`: Palworld character identity
- `name`: current character name

`PalConHost` emits the current native Palworld join shape:

```text
[2026-06-20 12:00:00Z] [LOG] CharacterName joined the server. (User id: steam_..., Player id: AFAFD830...)
```

The packaged UE4SS mod hooks `PalPlayerState:EnterChat_Receive` and emits:

```text
[CHAT] <CharacterName> !getconnectcode
```

It also writes an identity audit line to:

```text
\serverfiles\Logs\PalBridge-chat-identities.log
```

GSA's public documentation explains the player workflow but does not publish its private Palworld log-parser expressions. A live GSA test is therefore release-blocking.

## Connect-code acceptance test

1. Start a temporary server with this blueprint and image.
2. Join with a previously unlinked game account.
3. Confirm the GSA character record contains the REST `playerId` and is attached to the REST `userId`.
4. Type `!getconnectcode` twice in Palworld, as required by GSA.
5. Confirm both commands appear in the GSA chat/activity view under the correct character.
6. Confirm GSA returns a connect code in game.
7. Enter the code on the GSA Community website under **Settings → Connect accounts**.
8. Confirm the game account is connected to the intended Community account.
9. Run a test Shop Pack using both IDs:

```text
palbridge give --delivery "{delivery.id}" --character "{character.id}" --player "{player.id}" --item "Wood" --count 1
```

10. Confirm the item reaches the linked online character exactly once.
11. Repeat the same delivery ID and confirm the bridge returns `already_delivered`.
12. Deliberately pair a valid character ID with a different platform ID and confirm the bridge rejects it.

## Safety rule

The bridge never grants by character name. Before a request reaches the mod, it queries Palworld REST and requires `{character.id}` and `{player.id}` to occur on the same online player record. The mod then grants to that character's `UPalPlayerInventoryData` on the game thread.

If the mod claims a request but the bridge cannot prove the result, the delivery becomes `uncertain` and automatic retry stops. This favors manual reconciliation over a duplicate reward.

## Official references

- [GSA Community website account connection](https://docs.gameserverapp.com/dashboard/community/website/)
- [GSA Delivery Builder actions](https://docs.gameserverapp.com/dashboard/delivery_builder/actions/)
- [GSA Delivery Builder variables](https://docs.gameserverapp.com/dashboard/delivery_builder/variables/)
- [GSA players and connected accounts](https://github.com/gameserverapp/Platform/blob/main/Documentation/docs/dashboard/admin_tools/players_and_groups.md)
- [Palworld REST player list](https://docs.palworldgame.com/api/rest-api/players/)
