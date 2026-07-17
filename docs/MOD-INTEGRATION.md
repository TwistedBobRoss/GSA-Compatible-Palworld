# Mod Integration

## Purpose

This repo treats first-party mods as small event adapters that live inside the Palworld server process, while the launcher owns installation, staging, and activation.

## Runtime Contract

The launcher is responsible for:

- installing the official Palworld dedicated server
- installing the pinned UE4SS bootstrap used by this image
- copying first-party mods from `mods/` into the active UE4SS mods directory
- writing a deterministic `mods.txt` manifest with built-in debugging and cheat mods disabled

The mods are responsible for:

- exposing game events that official Palworld APIs do not provide directly
- keeping output machine-readable
- avoiding Discord, GSA, database, or economy business logic

## Initial Mod Categories

### `TKGBridge`

Primary event bridge for:

- chat command detection
- player identity capture
- join and leave observation where official logging is insufficient

### Future delivery mod

Optional server-side delivery adapter for:

- item grants
- idempotent delivery acknowledgement
- compatibility with a local queue or sidecar protocol

## File Layout

Each mod should live under its own folder in `mods/`.

Expected structure:

```text
mods/
  TKGBridge/
    enabled.txt
    Scripts/
      main.lua
```

## Design Rules

- Keep each mod focused on one concern.
- Prefer emitting structured events to writing business logic in Lua.
- Never require client-side installation.
- Assume the launcher may reinstall the server and restage mods on every container start.

## Open Design Decisions

- Whether the first bridge protocol should be file-based, stdout-based, or localhost HTTP
- Whether compatibility logging should be generated fully in PowerShell, fully in Lua, or split between both
- Which player identifiers are most stable across crossplay for delivery and linking
