# ddev-agent-env

Give every AI coding agent its own git worktree **and** its own DDEV project, cloned from your running one, so
several agents can build and test in parallel without breaking each other or your main instance.

```bash
ddev agent-env create issue-42
# worktree: ~/projects/myproject-agents/issue-42
# project:  myproject-issue-42
# url:      https://myproject-issue-42.ddev.site

cd "$(ddev agent-env path issue-42)"   # start your agent here
ddev agent-env list
ddev agent-env remove issue-42
```

## Why this exists

`ddev clone` [does not exist yet](https://github.com/ddev/ddev/issues/8187). Doing it by hand — worktree,
rename, export/import the database, re-install dependencies — is slow and, on a real application, produces a
clone that does not work. This packages the parts that actually matter.

## What a clone gets

| | How |
|---|---|
| Code | `git worktree add`, on a fresh `agent/<slug>` branch |
| Project identity | `name:` in `.ddev/config.local.yaml`, which DDEV already git-ignores — your tracked `config.yaml` is untouched |
| Database | a reusable golden `ddev snapshot`, restored into the clone |
| Dependencies, media, build artifacts | `cp --reflink` from the source — near-instant and near-zero disk on a copy-on-write filesystem |
| Extra services | automatically — DDEV namespaces containers and volumes by project name |
| Working `git` inside the containers | a generated compose file bind-mounting the main repo's `.git` at its host path |

On a copy-on-write filesystem the dependency, media and build copies are reflinked: a multi-gigabyte set copies
in seconds and adds no real disk until a file is modified. Without reflink support the tool falls back to a full
copy and says so.

## Install

```bash
ddev add-on get FluffyDiscord/ddev-agent-env
cp .ddev/agent-env.yaml.example .ddev/agent-env.yaml
```

Edit the copied `.ddev/agent-env.yaml` before the first `create` — the template is a placeholder, not a
working configuration for your application.

Requires DDEV ≥ v1.24.10, git ≥ 2.31, and `python3` (with PyYAML), `flock`, `curl`, `getent` and `docker` on
the host. Install checks all of them. `getent` and `cp --reflink` are GNU tools, so the host is expected to be
Linux; on a host without `getent` the install check fails, and without reflink support the copies fall back to
full copies.

> **The command installs globally** (`~/.config/ddev/commands/host/agent-env`), so it works in every project.
> DDEV does not reference-count global files: `ddev add-on remove agent-env` in *any* project deletes it for
> *all* of them. Install adds `.ddev/addon-metadata/` to your `.gitignore` so a clone cannot uninstall it.

## Commands

`ddev agent-env --help` prints the same reference.

| | |
|---|---|
| `create <slug>` | Clone into `../<project>-agents/<slug>` on a new `agent/<slug>` branch, as DDEV project `<project>-<slug>`; restore the golden snapshot, start, smoke-test |
| `list [--stale]` | List clones and their status; `--stale` also shows orphans — a DDEV project with no worktree, a worktree with no DDEV project, a leftover Docker network |
| `path <slug>` | Print the clone's worktree path |
| `remove [<slug>]` | Delete the clone: DDEV project, database, worktree, branch, leftover network. With no slug, pick from a menu |
| `refresh-db` | Retake the golden snapshot from the running source project. Run it after schema or seed-data changes so new clones start current |

`create` flags: `--from <ref>` branches from `<ref>` instead of `HEAD`; `--fresh` skips the snapshot restore and
starts with an empty database; `--fresh-deps` reinstalls the `derived` paths instead of copying them;
`--with-secrets` keeps real values instead of redacting `env_redact` keys; `--no-start` builds the worktree
without starting DDEV; `--force` overrides the disk-space, clone-count and DNS checks.

`remove` flags: `--yes` skips the confirmation; `--no-interactive` fails instead of opening the menu when no slug
is given; `--keep-branch` keeps `agent/<slug>`; `--force-delete-branch` deletes it even with unmerged commits.

Environment knobs, all optional: `AGENT_ENV_BASE_BRANCH` (branch the unmerged-commit check compares against —
default: the source project's current branch), `AGENT_ENV_MAX_CLONES`, `AGENT_ENV_WARN_CLONES`,
`AGENT_ENV_DISK_FLOOR_GB`, `AGENT_ENV_DOCKER_FLOOR_GB`, `AGENT_ENV_LOCK_TIMEOUT`, `AGENT_ENV_SELECT_TIMEOUT`.

## Configuration

`.ddev/agent-env.yaml` declares the untracked state a fresh worktree lacks. `copy_paths` splits in two because
`--fresh-deps` replaces only the first:

- **`derived`** — regenerable by `composer install` / `npm ci` / a build (`vendor`, `node_modules`, `public/build`)
- **`materialized`** — nothing regenerates these (`config/jwt/private.pem`, `public/media`, fixture data)

`env_rewrite_paths` files are copied with the source hostname replaced by the clone's, so a
`MAILER_WEB_URL="https://myproject.ddev.site:8026"` does not point every agent at the main project's mailbox.
`env_redact` blanks named keys (`REDACTED-IN-CLONE`) unless you pass `--with-secrets` — every clone otherwise
carries a live copy of your credentials.

`migrations_path` (default `migrations`) names the directory whose filenames are recorded alongside the golden
snapshot. `create` compares that record against the new worktree and warns when the two have drifted — a clone
whose database is ahead of its code makes `doctrine:migrations:diff` invent duplicates, and one whose code is
ahead needs its migration command run before the schema can be trusted. Point it at your migrations directory,
or ignore it if the project has none.

### A worked example

A fuller `.ddev/agent-env.yaml` for a typical PHP application, and the two rules behind it:

```yaml
copy_paths:
  derived:            # composer install / npm ci / build regenerate these
    - vendor
    - node_modules
    - public/build
    - public/bundles
  materialized:       # nothing regenerates these; a fresh worktree lacks them
    - config/jwt/private.pem   # per-file, NOT the config/jwt directory — see below
    - config/jwt/public.pem
    - public/media
    - var/storage

env_rewrite_paths:
  - .env.local

migrations_path: migrations

env_redact:           # blanked to REDACTED-IN-CLONE unless you pass --with-secrets
  - PAYMENT_GATEWAY_SECRET
  - SHIPPING_API_KEY
  - MAILER_DSN

max_clones: 8
```

- **Enumerate a partially-tracked directory file by file.** `config/jwt` already holds tracked files (a
  `.gitkeep`, a `*-test.pem`), so the worktree checks that directory out *before* the copy runs. `cp -a
  config/jwt <clone>/config/jwt` into an existing directory nests the real keys at `config/jwt/jwt/private.pem`,
  and the clone silently starts without a usable key. List the untracked files individually — their targets do
  not pre-exist, so each lands flat. The same holds for any directory that mixes tracked and git-ignored files.
- **Redact the credential, copy the key material.** A secret *value* in `.env.local` is blanked by `env_redact`;
  a key *file* the app reads at runtime (`config/jwt/private.pem`) is untracked artifact like any other and is
  `materialized`. The two are independent — a clone can have the key file present and the passphrase redacted,
  in which case that one feature needs `--with-secrets` while the rest of the clone stays scrubbed.

## Per-service hooks — use DDEV's, not ours

Anything that must run **in a container** belongs in DDEV's native `hooks:`, not in `agent-env.yaml`. DDEV
already gives you 25 lifecycle events with a `service:` per task, and — critically — they fire on *every*
restore, including one an agent runs inside its own clone hours later.

The canonical case: an application that resolves its site by hostname stores that hostname in the database, so
a restored clone serves 500 on every page until it is rewritten. In a tracked `.ddev/config.agent-env.yaml`:

```yaml
hooks:
  post-restore-snapshot:
    - exec: |
        for i in $(seq 1 30); do
          [ "$(psql -tAc 'select pg_is_in_recovery()')" = "f" ] && break
          sleep 1
        done
        psql -v ON_ERROR_STOP=1 -c "UPDATE app_channel SET hostname = regexp_replace(hostname, '[^.]+\.ddev\.site\$', '$DDEV_HOSTNAME')"
      service: db
```

Three things make this work: `DDEV_HOSTNAME` is already the clone's own value inside the container, so there is
no templating and no injection surface; anchoring the regex on the TLD makes the statement an identity no-op in
the source project, so one committed hook is correct everywhere; and the `pg_is_in_recovery()` loop covers the
window where DDEV's Postgres restore reports healthy (`pg_isready`) while the server is still read-only.

A second hook can run on another service and **wait on a dependency before it acts**. A restored clone has the
catalogue back but an empty search index, and a search container reports "running" before the search service
accepts queries — so the reindex polls readiness first, on the `web` service:

```yaml
    - exec: |
        for i in $(seq 1 30); do
          curl -sf -o /dev/null "http://ddev-${DDEV_SITENAME}-search:9308/" && break
          sleep 1
        done
        bin/console app:search:reindex --no-interaction
      service: web
```

`ddev-${DDEV_SITENAME}-search` resolves to *this* clone's own search container (rule 2 under "Arbitrary extra
services"), so the one committed hook reindexes each clone against its own restored data.

Clones are created with `fail_on_hook_fail: true`, so a failing hook fails the restore instead of printing a
warning nobody reads.

`agent-env.yaml`'s own `hooks:` holds only the two host-side stages DDEV has no event for: `post_worktree`
(after files are copied, before `ddev start`) and `pre_remove`.

## Arbitrary extra services

Services you add to `.ddev/docker-compose.*.yaml` clone automatically, because DDEV derives the compose project
from the project name. Four rules keep that true:

1. No fixed host `ports:` — use dynamic bindings or `web_extra_exposed_ports` through the shared router.
2. No literal `container_name:` — use `ddev-${DDEV_SITENAME}-<service>`.
3. No literal `com.ddev.approot` / `com.ddev.site-name` labels — use `${DDEV_APPROOT}` / `${DDEV_SITENAME}`.
   A literal makes the clone's container claim membership in the source project, so `ddev poweroff` there tears
   the clone's services down.
4. No `external: true` volumes or networks — those are shared by every clone.

A service's **config** clones; its **data** does not. If a service needs seed state, give it a
`post-restore-snapshot` or `post-start` hook that rebuilds it — usually cheaper and more correct than copying
bytes.

## Safety

- `remove` with no slug opens an arrow-key picker of the worktree-backed clones (a `python3` curses menu,
  space to toggle, falling back to a numbered prompt where curses is unavailable), lets you select one or
  more, and always confirms the set before deleting; unknown slugs or branches with unmerged commits abort
  the whole batch before anything is removed. `--no-interactive` keeps the scriptable behaviour of failing
  when no slug is given.
- `remove` refuses to delete a branch with unmerged commits unless `--force-delete-branch`, and prints the tip
  SHA first so the work is recoverable from the reflog.
- `remove` reaps the clone's `ddev-<project>_default` Docker network after deleting the project, so the removed
  clone reclaims its address block. `ddev delete` only frees that network when it runs from the project
  directory, so an orphaned clone (worktree gone) would otherwise leave the network behind, and enough of them
  exhaust Docker's default address pool. `list --stale` lists any such leftover networks and the `remove <slug>`
  that reclaims each.
- `rm -rf` is guarded to the worktrees root.
- `create` refuses to run from inside an existing clone.
- Provisioning is serialized with `flock`; the golden snapshot is staged under a temporary name and moved into place, so a `refresh-db` racing a `create` cannot hand out a half-written file.
- Every failure mode has its own exit code, so an orchestrator can branch without parsing text. An unhandled failure exits 24 rather than masquerading as one of them.

`ddev poweroff` and `ddev delete --all` are global and will destroy your main project along with every other
DDEV project on the machine. Nothing here can stop that — deny them in your agent's tooling.

## Exit codes

| | | | |
|---|---|---|---|
| 1 not in a DDEV project | 2 bad slug or usage | 3 slug in use | 4 disk or clone cap |
| 5 unsafe `rm -rf` path | 6 no golden snapshot | 7 `git worktree add` | 8 snapshot copy |
| 9 `ddev start` | 10 `ddev snapshot restore` | 11 restore hook | 12 host hook |
| 13 verification | 14 host tooling or unreadable `agent-env.yaml` | 15 DNS | 16 write |
| 17 copy | 18 `refresh-db` | 19 `ddev delete` | 20 lock timeout |
| 21 run from inside a clone | 22 unmerged branch | 23 confirmation declined | 24 unhandled failure |

## Licence

Apache-2.0.
