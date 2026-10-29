# ddev-agent-env

DDEV add-on that gives each AI coding agent its own git worktree and DDEV project, cloned from your main one. Linux and macOS.

## Features

- [One-command clones](docs/commands.md#create) — code, database, dependencies and media, smoke-tested before the agent starts
- [Copy-on-write copies](docs/configuration.md#what-a-clone-gets) — `vendor`, `node_modules` and media take no extra disk until a file changes
- [Own hostnames](docs/configuration.md#hostnames) — a clone never answers your main project's URLs
- [Redacted secrets](docs/configuration.md#options) — the env keys you list reach a clone only with `--with-secrets`
- [Migration drift warning](docs/configuration.md#migration-drift) — you know when a clone's database and code disagree
- [Extra services clone too](docs/hooks-and-services.md#extra-services) — each clone gets its own search, queue and cache containers
- [Safe removal](docs/commands.md#remove) — unmerged agent work blocks the delete
- [One exit code per failure](docs/commands.md#exit-codes) — orchestrators branch without parsing text

## Install

```bash
ddev add-on get FluffyDiscord/ddev-agent-env
```

> **The command installs globally.** `ddev add-on remove agent-env` in any project removes it for every project on the machine. Install adds `.ddev/addon-metadata/` to your `.gitignore`, so a clone can't uninstall it.

Needs DDEV v1.24.10 or newer, git 2.31 or newer, and `python3` with PyYAML, `curl` and `docker` on the host. Install checks them all.

## Quick start

1. `.ddev/agent-env.yaml`: copy the template, then list what a clone needs ([Configuration](docs/configuration.md)).

   ```bash
   cp .ddev/agent-env.yaml.example .ddev/agent-env.yaml
   ```

2. Create a clone and point the agent at it:

   ```bash
   ddev agent-env create issue-42
   cd "$(ddev agent-env path issue-42)"
   ```

3. Remove it when the work is merged:

   ```bash
   ddev agent-env remove issue-42
   ```

## Docs

- [Commands](docs/commands.md) — `create`, `list`, `path`, `remove`, `refresh-db`, environment variables, exit codes
- [Configuration](docs/configuration.md) — `.ddev/agent-env.yaml`, hostnames, smoke check, migration drift
- [Hooks and services](docs/hooks-and-services.md) — DDEV hooks for clones, host-side hooks, extra services

## Licence

Apache-2.0.
