# GSA RCON Compatibility Contract

This is the release-blocking contract for the implemented `GsaRconBridge` gateway.

## Selected GSA implementation

The blueprint uses:

```json
"command_control": {
  "type": "rcon_1"
}
```

GameServerApp publicly documents that its command/control system supports multiple RCON implementations, but it does not publish a mapping between internal names such as `rcon_1` and wire protocols. The gateway implements the established **Source RCON** protocol used by Palworld's current native RCON service. The final release must also pass a live GSA test using the selected blueprint implementation.

## Required Source RCON behavior

- TCP transport on `{gameserver.rcon_port}`.
- Signed 32-bit little-endian packet fields.
- Packet layout: length, request ID, type, UTF-8 body, NUL, NUL.
- Validate packet sizes and reject malformed or oversized packets safely.
- Accept `SERVERDATA_AUTH` (`3`).
- On successful authentication:
  - send `SERVERDATA_AUTH_RESPONSE` (`2`) with the original request ID.
- An optional conventional empty `SERVERDATA_RESPONSE_VALUE` (`0`) before the auth response is available through `PAL_BRIDGE_AUTH_EMPTY_RESPONSE`. It defaults to `false` because clients that do not drain the extra packet can misassociate it with their first command.
- On failed authentication, send auth response ID `-1` and close the connection.
- Accept `SERVERDATA_EXECCOMMAND` (`2`) only after authentication.
- Return `SERVERDATA_RESPONSE_VALUE` (`0`) with the original request ID.
- Support persistent connections and multiple commands per connection.
- Support fragmented TCP reads and multiple packets arriving in one read.
- Split long responses into valid protocol-sized response packets.
- Handle the conventional empty/sentinel request used by clients to detect the end of multi-packet responses.
- Allow concurrent GSA monitoring, admin, and delivery connections.
- Use constant-time password comparison and rate-limit failed authentication.

## GSA delivery command

Shop packs will include GSA's documented delivery ID so retries are idempotent:

```text
palbridge give --delivery "{delivery.id}" --player "{player.id}" --item "ITEM_ID" --count 1
```

The gateway must persist `{delivery.id}` before returning success. Replaying the same delivery ID must return the original result without granting the reward twice.

Responses use a single-line machine-readable prefix:

```text
OK delivery=<id> status=delivered
OK delivery=<id> status=already_delivered
ERROR delivery=<id> code=<code> message=<text>
```

## Acceptance tests

A release is not GSA-compatible until all of these pass:

1. Correct and incorrect password tests.
2. Fragmented-packet and combined-packet tests.
3. Multiple commands on one connection.
4. Parallel monitoring and delivery connections.
5. Long multi-packet response.
6. UTF-8 player names and command data.
7. Retry of the same `{delivery.id}` without duplicate items.
8. Interoperability with at least two independent Source RCON clients.
9. GSA command console test.
10. GSA RCON monitoring test.
11. GSA Shop Pack delivery test using `{player.id}` and `{delivery.id}`.
12. Container restart during a delivery followed by a safe retry.

The local automated harness passes tests 1-7 and the ledger/restart portion of test 12. Test 8 passes with two independent clients:

- `rcon 2.4.9`
- `mctools 1.3.0`

Tests 9-11 and the complete container interruption scenario require deployment on the target GSA machine.

## Sources

- [GSA blueprint command/control connections](https://docs.gameserverapp.com/dashboard/blueprints/create_and_manage_blueprints/#command--control-connections)
- [GSA Delivery Builder actions](https://docs.gameserverapp.com/dashboard/delivery_builder/actions/)
- [GSA Delivery Builder variables](https://docs.gameserverapp.com/dashboard/delivery_builder/variables/)
- [Source RCON protocol](https://developer.valvesoftware.com/wiki/Source_RCON_Protocol)
