# GSABridge Hooks

## Purpose

`TKGBridge` is the first-party server-side event adapter for GameServerApp integration.

Its job is to surface Palworld events that are either unavailable or unreliable through the Windows dedicated server alone.

## Phase 1 Responsibilities

- detect player chat
- detect player joins
- detect player leaves
- capture stable identifiers for those events
- write bridge event logs under `C:\serverfiles\TKGBridge`
- write a synthetic compatibility log line under `C:\serverfiles\Logs`

## Event Files

### `C:\serverfiles\TKGBridge\events.log`

JSON lines event stream for machine consumption.

Example:

```json
{"type":"chat","timestamp":"2026-07-16T03:15:00Z","mod":"TKGBridge","version":"0.2.0","name":"TwistedBobRoss","userId":"gdk_2535436212649450","playerId":"76AEB3AA000000000000000000000000","message":"!getconnectcode"}
```

### `C:\serverfiles\TKGBridge\audit.log`

Human-readable bridge diagnostics.

### `C:\serverfiles\TKGBridge\trace.log`

Optional deep property traces for live field discovery when `PAL_BRIDGE_TRACE=true`.

### `C:\serverfiles\TKGBridge\identities.log`

Observed identifier mappings for troubleshooting crossplay identity issues.

### `C:\serverfiles\Logs\PalServer-compat.log`

Synthetic Palworld-compatible log lines intended for GSA ingestion.

## Event Types

- `bridge_ready`
- `chat`
- `connect_code_requested`
- `player_join`
- `player_leave`

## Integration Direction

The bridge intentionally does not call GSA directly.

Instead:

1. the mod emits events
2. a future sidecar or wrapper reads those events
3. the sidecar talks to GSA APIs or writes compatibility responses

## Next Hook Pass

The current `main.lua` now uses a hybrid hook strategy:

- direct `RegisterHook` for Palworld chat
- `NotifyOnNewObject` for player-state discovery
- `LoopAsync` snapshot diffing for join and leave detection

## Current Hook Strategy

### Chat

The bridge attempts to register:

```text
/Script/Pal.PalPlayerState:EnterChat_Receive
```

That is currently the strongest known chat hook candidate in our Palworld work.

### Join and leave

The bridge currently detects joins and leaves by:

1. watching new `/Script/Pal.PalPlayerState` objects
2. polling `FindAllOf("PalPlayerState")`
3. diffing the observed player-state set every 3000ms

This gives us a real event path now, even before every dedicated-server login/logout UFunction is fully mapped.

## Remaining Validation Work

- confirm which `PalPlayerState` properties are stable for `name` and `userId`
- replace diff-based leave detection with direct logout hooks if a reliable server UFunction is identified
- verify the compatibility lines against a live GSA Palworld test server

## Trace Mode

Set:

```text
PAL_BRIDGE_TRACE=true
```

to make the bridge dump selected `PalPlayerState` properties to `trace.log` whenever it sees a player state in snapshots, new-object notifications, or chat callbacks.
