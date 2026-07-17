# Architecture

## Principles

- Official Palworld interfaces come first.
- Anything non-official must be first-party and server-side only.
- Logging is a compatibility layer, not a source of gameplay truth.
- Business logic belongs outside the game process whenever possible.

## Phase 1 Target

The initial target is a Windows-first image with four layers:

1. Palworld dedicated server
2. UE4SS loader
3. First-party TKG mods
4. First-party wrapper/bootstrap

## Responsibilities

### Palworld dedicated server

- Hosts the actual game world
- Exposes official REST where available
- Owns server state and saves

### UE4SS

- Provides the minimum runtime hook surface for our own mods
- Is the only intended third-party framework dependency
- Is installed automatically by the clean-room bootstrap rather than selected per server

### First-party mods

- Detect in-game events we cannot get from official APIs alone
- Stay small and focused
- Avoid embedding Discord, GSA, or economy business logic

### First-party wrapper

- Starts the server process
- Manages config materialization
- Produces compatibility logs for GSA when native Windows logging is insufficient
- Hosts any small helper process that should live beside the server

## Logging Direction

The repo will target a synthetic compatibility log if Windows does not produce the necessary native file output.

The compatibility log should eventually answer:

- Who joined
- Who left
- What chat message was sent
- What player identifiers were associated with those events

## Open Questions

- Which exact Palworld event lines does GSA successfully ingest for Palworld?
- Which player identity fields are exposed consistently on Windows through REST versus mod hooks?
- Which actions can be handled entirely through official REST after Palworld `1.0.0`?
