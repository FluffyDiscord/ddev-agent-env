# Configuration

**Create `.ddev/agent-env.yaml` before the first `create`.** Without it, `create` warns and copies only `.env.local`: no dependencies, no media, no keys.

```bash
cp .ddev/agent-env.yaml.example .ddev/agent-env.yaml
```

## What a clone gets

`ddev agent-env create issue-42` in project `myapp`:

| Part | How |
|---|---|
| Code | `git worktree add` at `../myapp-agents/issue-42` on a new `agent/issue-42` branch. |
| Starting point | `HEAD`, or the ref you pass with `--from`. |
| Project identity | `.ddev/config.zz-agent-env.yaml` with `name: "myapp-issue-42"` and `fail_on_hook_fail: true`. |
| Hostnames | The source's `additional_hostnames`, renamed for the clone. See [Hostnames](#hostnames). |
| Database | The golden snapshot `agent-golden`, restored after `ddev start`. |
| Dependencies, media, build output | The `copy_paths` entries, copied copy-on-write from the source. |
| Env files | The `env_rewrite_paths` files, with the source's hostnames swapped for the clone's and `env_redact` keys redacted. |
| Extra services | Cloned with the project, because DDEV names containers and volumes after the project. |
| `git` inside the containers | `.ddev/docker-compose.agentgit.yaml` bind-mounts the main repo's `.git` into `web` at its host path. |

- Your tracked `.ddev/config.yaml` stays untouched, so the clone's branch starts clean.
- `config.zz-agent-env.yaml` and `docker-compose.agentgit.yaml` are git-ignored in the clone. `create` doesn't write a `config.local.yaml`, so that file is yours.
- Copies try `cp --reflink=always`, then APFS `cp -c`. Both add no real disk until a file changes. Without either, `create` makes a full copy and warns.
- `create` sets `extensions.worktreeConfig = true` in the main repo and turns off automatic `git gc` and maintenance for the clone's worktree.
- An extra service's config clones; its data doesn't. See [Extra services](hooks-and-services.md#extra-services).

## Hostnames

**Nothing to do.** The router serves every project's hostnames machine-wide, so a clone that kept the source's `additional_hostnames` would answer the source's URLs. `create` gives the clone its own.

1. `create` reads `additional_hostnames` from the source's `.ddev/config.yaml` and every `.ddev/config.*.yaml`, inline or block lists. Lists add up across files, and a file with `override_config: true` replaces the list so far, as DDEV does.
2. It renames each hostname with the rules below.
3. It writes the renamed list to the clone's `.ddev/config.zz-agent-env.yaml`, with `override_config: true` so the clone ends up with only those names.

The generated file:

```yaml
override_config: true
name: "myapp-issue-42"
fail_on_hook_fail: true
additional_hostnames: ["shop.myapp-issue-42", "myapp-issue-42-admin", "*.myapp-issue-42"]
additional_fqdns: []
```

| Source name | Rule | Clone name |
|---|---|---|
| `myapp` | It equals the project name, so it's replaced. | `myapp-issue-42` |
| `shop.myapp` | The project name is one label, so that label is replaced. | `shop.myapp-issue-42` |
| `*.myapp` | The project name is one label, so that label is replaced. | `*.myapp-issue-42` |
| `myapp-admin` | It starts with `myapp-`, so the prefix is replaced. | `myapp-issue-42-admin` |
| `shop` | Anything else gets the clone name as a prefix. | `myapp-issue-42-shop` |
| `api.example` | Anything else gets the clone name as a prefix. | `myapp-issue-42-api.example` |

> Not covered:
> - `additional_fqdns` is emptied. A clone has none.
> - A tracked config file that sorts after `config.zz-agent-env.yaml`, such as `config.zzz.yaml`, can add hostnames back.

## Options

Every key is optional. These are the defaults when a key is absent:

```yaml
copy_paths:
  derived: []
  materialized: []
env_rewrite_paths:
  - .env.local
env_redact: []
migrations_path: migrations
smoke_path: /
smoke_status: 200
hooks:
  post_worktree: []
  pre_remove: []
max_clones: 8
```

| Option | Default | Meaning |
|---|---|---|
| `copy_paths.derived` | none | Paths a dependency install or build regenerates: `vendor`, `node_modules`, build output. |
| `copy_paths.materialized` | none | Paths nothing regenerates: key files, media, fixture data. |
| `env_rewrite_paths` | `.env.local` | Files copied with the source's hostnames replaced by the clone's. |
| `env_redact` | none | Keys whose values become `REDACTED-IN-CLONE` in the `env_rewrite_paths` files. |
| `migrations_path` | `migrations` | Directory whose filenames are checked for [migration drift](#migration-drift). |
| `smoke_path` | `/` | Path requested on the clone's primary URL as the last step of `create`. |
| `smoke_status` | `200` | Status the [smoke check](#smoke-check) expects. Takes a list: `[200, 302]`. |
| `hooks.post_worktree` | none | Host-side commands run once the clone is started and restored. See [Host-side hooks](hooks-and-services.md#host-side-hooks). |
| `hooks.pre_remove` | none | Host-side commands run before `remove` deletes the clone. |
| `max_clones` | `8` | Most clones that may run at once. |

- A `copy_paths` or `env_rewrite_paths` entry missing in the source is skipped with a warning.
- A copy path that exists in the source but not in the clone fails `create` with exit 13.
- `--fresh-deps` skips `derived` and installs dependencies in the clone instead. See [create](commands.md#create).
- An empty `env_rewrite_paths` falls back to `.env.local` too, when that file exists.
- `env_redact` matches `KEY=value` and `export KEY=value` lines. `--with-secrets` keeps the real values.
- `max_clones` counts running DDEV projects whose directory is under `../myapp-agents/`. Stopped clones don't count.

## Env rewrite

**The rewrite swaps whole hostnames only.** It replaces the source's primary hostname and every non-wildcard `additional_hostnames` entry with the clone's, using the [hostname rules](#hostnames):

| In the source's `.env.local` | In the clone's |
|---|---|
| `myapp.ddev.site` | `myapp-issue-42.ddev.site` |
| `shop.myapp.ddev.site` | `shop.myapp-issue-42.ddev.site` |
| `myapp-admin.ddev.site`, with `myapp-admin` declared | `myapp-issue-42-admin.ddev.site` |
| `myapp-admin.ddev.site`, not declared | `myapp-admin.ddev.site` |
| `foo-myapp.ddev.site` | `foo-myapp.ddev.site` |

## Smoke check

**`create` ends by requesting `smoke_path` on the clone's primary URL and comparing the status with `smoke_status`.**

- Redirects aren't followed, so a redirect answers `301` or `302`. List it if that's fine: `[200, 302]`.
- The leading slash on `smoke_path` is optional.
- `--fresh` and `--no-start` skip the check; `create` prints `verification skipped`.

An API-only backend serves no page at `/`. Point the check at a route that answers. A `401` is a good result: it proves PHP, routing and the restored database are alive.

`create` checks both keys before it builds anything, and fails with exit 14 on:

- a `smoke_path` with `://` or whitespace in it, such as a full URL;
- a `smoke_status` entry that isn't a three-digit number.

A wrong status fails with exit 13: `<url> returned <status>, expected <statuses>`, plus a hint:

| Response | Hint |
|---|---|
| Redirect to the source project's hostname | The restored data still carries the source hostname. |
| Any 5xx | Usually restored data still pointing at the source hostname. |
| Anything else, including no answer (`000`) | Set `smoke_path` and `smoke_status` if the check is wrong for this project. |

For the hostname fix, see [Rewrite the stored hostname](hooks-and-services.md#rewrite-the-stored-hostname).

## Migration drift

**`create` only warns; it doesn't stop.**

Taking the golden snapshot (`refresh-db`, or the first `create`) records the filenames in the source's `migrations_path`. After the restore, `create` compares them with the clone's:

| Drift | What to do |
|---|---|
| The snapshot has files the branch lacks: the database is ahead of the code. | Don't trust `doctrine:migrations:diff`; it would invent duplicates. |
| The branch has files the snapshot lacks: the code is ahead of the database. | Run your migration command in the clone before relying on the schema. |

- Only filenames are compared.
- `--fresh` skips the check. So does a clone without a `migrations_path` directory, or a snapshot taken while the source had none.

## Worked example

Every option, with values a typical PHP application would use:

```yaml
copy_paths:
  # Copied from the source project; skipped when you pass --fresh-deps.
  derived:
    - vendor
    - node_modules
    - public/build
    - public/bundles

  # Copied from the source project; nothing can regenerate these.
  materialized:
    - config/jwt/private.pem   # per-file, NOT the config/jwt directory
    - config/jwt/public.pem
    - public/media
    - var/storage

# Copied with the source hostnames replaced by the clone's.
env_rewrite_paths:
  - .env.local

# Set to REDACTED-IN-CLONE, unless you pass --with-secrets.
env_redact:
  - PAYMENT_GATEWAY_SECRET
  - SHIPPING_API_KEY
  - MAILER_DSN

# Filenames recorded with the golden snapshot; create warns when they drift.
migrations_path: migrations

# Requested on the clone's URL as the last step of create.
smoke_path: /api/v1/widget/config   # this backend serves no page at /
smoke_status: 401                   # unauthenticated, but PHP + routing + DB are alive

# Host-side stages DDEV has no event for. Run from the worktree directory.
hooks:
  post_worktree:                                  # clone is started and restored
    - ddev exec bin/console app:search:reindex
  pre_remove:                                     # before the clone is deleted
    - ddev exec bin/console app:license:release

# Refuse to create a clone while this many are running.
max_clones: 8
```

- **List a partly tracked directory file by file.** `config/jwt` also holds tracked files, so the worktree already has the directory, and copying it in nests the keys at `config/jwt/jwt/private.pem`. Same for any directory that mixes tracked and git-ignored files.
- **Copy the key file, redact its passphrase.** A key file the app reads belongs in `materialized`; its passphrase can still go in `env_redact`. Then only that one feature needs `--with-secrets`.
