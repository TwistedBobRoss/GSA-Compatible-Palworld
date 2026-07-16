# GSA-Compatible Palworld

Clean-room starting point for a custom GameServerApp-compatible Palworld container.

## Goals

- Run the official Palworld dedicated server in a custom container.
- Favor official Palworld surfaces first: dedicated server binary, config, and REST API.
- Allow first-party server-side mods that we build ourselves.
- Produce GSA-friendly logs on Windows, where native server logging is insufficient.
- Keep the design Windows-first until the runtime model is proven.

## Non-Goals For Phase 1

- No PalDefender, PalGuard, or PalCon dependency.
- No attempt to revive deprecated Palworld RCON as a primary control path.
- No Linux-native Palworld runtime inside this repo until Windows behavior is validated.

## Planned Layout

- `docker/windows/ltsc2022/Dockerfile`
  - Windows Server Core image definition.
- `scripts/Start.ps1`
  - Container bootstrap and process launch entrypoint.
- `mods/`
  - First-party UE4SS mod packages built in this repo.
- `src/`
  - Helper services, wrappers, or native utilities we author for this image.
- `blueprints/`
  - GameServerApp blueprint artifacts.
- `docs/`
  - Architecture, logging, and rollout notes.

## Current Status

This is a fresh scaffold. The files in this folder are intentionally minimal and do not reuse the previous experimental implementation.

## Next Milestones

1. Define the Windows launch model for the official Palworld dedicated server.
2. Decide the minimum compatibility log we need for GSA ingestion.
3. Add a first-party server-side bridge mod package under `mods/`.
4. Add a small wrapper/service under `src/` only where the official server surfaces are not enough.
