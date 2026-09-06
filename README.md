# ddev-agent-env

One git worktree **and** one DDEV project per AI coding agent, cloned from your running project. Agents build and test in parallel, isolated from each other and from your main instance.

```bash
ddev agent-env create issue-42
# worktree: ~/projects/myproject-agents/issue-42
# project:  myproject-issue-42
# url:      https://myproject-issue-42.ddev.site

cd "$(ddev agent-env path issue-42)"   # start your agent here
ddev agent-env list
ddev agent-env remove issue-42
```

`ddev clone` [does not exist yet](https://github.com/ddev/ddev/issues/8187), and doing it by hand — worktree, rename, database export and import, dependency reinstall — produces a clone that does not work on a real application.

## What a clone gets

| | How |
|---|---|
| Code | `git worktree add` on a fresh `agent/<slug>` branch |
| Project identity | `name:` in `.ddev/config.local.yaml`, which DDEV already git-ignores, so your tracked `config.yaml` is untouched |
| Database | A reusable golden `ddev snapshot`, restored into the clone |
| Dependencies, media, build artifacts | `cp --reflink` from the source, so a multi-gigabyte set copies in seconds and adds no real disk until a file is modified. Without reflink support it falls back to a full copy and says so |
| Extra services | Cloned automatically, because DDEV namespaces containers and volumes by project name |
| Working `git` inside the containers | A generated compose file bind-mounting the main repo's `.git` at its host path |

## Install

```bash
ddev add-on get FluffyDiscord/ddev-agent-env
cp .ddev/agent-env.yaml.example .ddev/agent-env.yaml
```

Edit the copied `.ddev/agent-env.yaml` before the first `create`: the template is a placeholder, not a working configuration for your application.

Requires DDEV ≥ v1.24.10, git ≥ 2.31, and `python3` (with PyYAML), `curl` and `docker` on the host. Install checks all of them.

Works on Linux and macOS. It uses `flock`, `getent` and `cp --reflink` where they exist, and falls back on its own to a `mkdir` lock, `python3` socket resolution, APFS `cp -c` clonefiles, or plain full copies.

> **Installs globally** (`~/.config/ddev/commands/host/agent-env`). DDEV does not reference-count global files: `ddev add-on remove agent-env` in *any* project deletes it for *all*. Install adds `.ddev/addon-metadata/` to `.gitignore` so a clone cannot uninstall it.

## Commands

`ddev agent-env --help` prints the same reference.

| | |
|---|---|
| `create <slug>` | Clone the project into `../<project>-agents/<slug>` on a new `agent/<slug>` branch, as DDEV project `<project>-<slug>`, then restore the golden snapshot, start it and smoke-test it |
| `list [--stale]` | List clones and their status. `--stale` also shows orphans: a project with no worktree, a worktree with no project, a leftover Docker network |
| `path <slug>` | Print the clone's worktree path |
| `remove [<slug>]` | Delete the clone's DDEV project, database, worktree, branch and leftover network. With no slug, pick from a menu |
| `refresh-db` | Retake the golden snapshot from the running source project. Run it after schema or seed-data changes so new clones start current |

`create` flags:

| | |
|---|---|
| `--from <ref>` | Branch from `<ref>` instead of `HEAD` |
| `--fresh` | Skip the snapshot restore and start with an empty database |
| `--fresh-deps` | Reinstall the `derived` paths instead of copying them |
| `--with-secrets` | Keep real values instead of redacting the `env_redact` keys |
| `--no-start` | Build the worktree but do not start DDEV |
| `--force` | Override the disk-space, clone-count and DNS checks |

`remove` flags:

| | |
|---|---|
| `--yes`, `-y` | Skip the confirmation, so `remove <slug> --yes` runs unattended |
| `--no-interactive` | Fail instead of opening the menu when no slug is given |
| `--keep-branch` | Keep the `agent/<slug>` branch |
| `--force-delete-branch` | Delete the branch even when it has unmerged commits |

All optional, all environment variables: `AGENT_ENV_BASE_BRANCH` (the branch the unmerged-commit check compares against, default: the source project's current branch), `AGENT_ENV_MAX_CLONES`, `AGENT_ENV_WARN_CLONES`, `AGENT_ENV_DISK_FLOOR_GB`, `AGENT_ENV_DOCKER_FLOOR_GB`, `AGENT_ENV_LOCK_TIMEOUT`, `AGENT_ENV_SELECT_TIMEOUT`.

## Configuration

`.ddev/agent-env.yaml` declares the untracked state a fresh worktree lacks.

| Key | Meaning |
|---|---|
| `copy_paths.derived` | Paths `composer install`, `npm ci` or a build can regenerate. `--fresh-deps` replaces only these |
| `copy_paths.materialized` | Paths nothing regenerates: key files, media, fixture data |
| `env_rewrite_paths` | Files copied with the source hostname replaced by the clone's, so a `MAILER_WEB_URL="https://myproject.ddev.site:8026"` no longer points every agent at the main project's mailbox |
| `env_redact` | Keys blanked to `REDACTED-IN-CLONE` unless you pass `--with-secrets`. Without it every clone carries a live copy of your credentials |
| `migrations_path` | Default `migrations`. The filenames are recorded with the golden snapshot, and `create` warns when they have drifted from the worktree |
| `smoke_path` | Default `/`. Requested on the clone's primary URL as the last step of `create` |
| `smoke_status` | Default `200`. Takes a list too: `[200, 302]` |
| `hooks` | Host-side commands for the two stages DDEV has no event for: `post_worktree` and `pre_remove` |
| `max_clones` | The most clones `create` will let you have at once |

Migration drift matters in both directions. A database ahead of its code makes `doctrine:migrations:diff` invent duplicates, and code ahead of the database needs its migration command run before the schema can be trusted.

An API-only backend serves no page at `/`, so point the smoke check at a route that answers. A `401` is a perfectly good result: it proves PHP, routing and the restored database are alive. The leading slash on `smoke_path` is optional. A non-numeric `smoke_status`, or a `smoke_path` that is a full URL rather than a path, fails at the *start* of `create` with exit 14, before the clone is built.

When the smoke check gets the wrong status, the failure names the URL it requested and the status it expected. It adds the "restored data still points at the source project's hostname" hint only when that is the likely cause: a 5xx, or a redirect to the source project's hostname.

### Worked example

Every option, with the values a typical PHP application would use:

```yaml
copy_paths:
  # Copied from the source project; reinstalled instead when you pass --fresh-deps.
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

# Copied with the source hostname replaced by the clone's.
env_rewrite_paths:
  - .env.local

# Blanked to REDACTED-IN-CLONE, unless you pass --with-secrets.
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

# Refuse to create more than this many clones at once.
max_clones: 8
```

- **List a partially-tracked directory file by file.** `config/jwt` holds tracked files too, so the worktree checks that directory out before the copy runs, and `cp -a config/jwt <clone>/config/jwt` then nests the real keys at `config/jwt/jwt/private.pem` — the clone starts without a usable key. Listing the untracked files individually lands each one flat. The same holds for any directory that mixes tracked and git-ignored files.
- **Redact the credential, copy the key material.** `env_redact` blanks a secret *value* in `.env.local`, while a key *file* the app reads at runtime is untracked artifact like any other and belongs in `materialized`. The two are independent: a clone can hold the key file with its passphrase redacted, so that one feature needs `--with-secrets` while the rest of the clone stays scrubbed.

## Per-service hooks — use DDEV's, not ours

Anything that must run in a container belongs in DDEV's native `hooks:`, not in `agent-env.yaml`. DDEV gives you 25 lifecycle events with a `service:` per task, and they fire on *every* restore, including one an agent runs inside its own clone hours later.

The canonical case: an application that resolves its site by hostname stores that hostname in the database, so a restored clone serves 500 on every page until it is rewritten. In a tracked `.ddev/config.agent-env.yaml`:

```yaml
hooks:
  post-restore-snapshot:
    - exec: |
        for i in $(seq 1 30); do
          [ "$(psql -tAc 'select pg_is_in_recovery()')" = "f" ] && break
          sleep 1
        done
        psql -v ON_ERROR_STOP=1 -c "UPDATE app_channel SET hostname = regexp_replace(hostname, '[^.]+\.ddev\.site\$', '${DDEV_HOSTNAME%%,*}')"
      service: db
```

Three things make this work:

- Inside the container, `DDEV_HOSTNAME` already holds the clone's own hostnames as a comma-separated list with the primary one first, so `${DDEV_HOSTNAME%%,*}` picks it up with no templating and no injection surface.
- Anchoring the regex on the TLD makes the statement an identity no-op in the source project, so one committed hook is correct everywhere.
- The `pg_is_in_recovery()` loop covers the window in which DDEV's Postgres restore already reports healthy (`pg_isready`) while the server is still read-only.

A second hook can run on another service and wait on a dependency before it acts. A restored clone has the catalogue back but an empty search index, and a search container reports "running" before it accepts queries, so the reindex polls readiness first:

```yaml
    - exec: |
        for i in $(seq 1 30); do
          curl -sf -o /dev/null "http://ddev-${DDEV_SITENAME}-search:9308/" && break
          sleep 1
        done
        bin/console app:search:reindex --no-interaction
      service: web
```

`ddev-${DDEV_SITENAME}-search` resolves to *this* clone's own search container (rule 2 below), so the one committed hook reindexes each clone against its own restored data.

Clones are created with `fail_on_hook_fail: true`, so a failing hook fails the restore instead of printing a warning nobody reads.

`agent-env.yaml`'s own `hooks:` holds only the two host-side stages DDEV has no event for. Both run from the worktree directory: `post_worktree` once the clone is copied, started and restored, just before the smoke check, and `pre_remove` before a clone is deleted.

## Arbitrary extra services

Services you add to `.ddev/docker-compose.*.yaml` clone automatically, because DDEV derives the compose project from the project name. Four rules keep that true:

1. No fixed host `ports:`. Use dynamic bindings or `web_extra_exposed_ports` through the shared router.
2. No literal `container_name:`. Use `ddev-${DDEV_SITENAME}-<service>`.
3. No literal `com.ddev.approot` or `com.ddev.site-name` labels. Use `${DDEV_APPROOT}` and `${DDEV_SITENAME}` — a literal makes the clone's container claim membership in the source project, so `ddev poweroff` there tears the clone's services down.
4. No `external: true` volumes or networks. Those are shared by every clone.

A service's **config** clones; its **data** does not. If a service needs seed state, give it a `post-restore-snapshot` or `post-start` hook that rebuilds it.

## Safety

- `remove` with no slug opens an arrow-key picker of the worktree-backed clones (a `python3` curses menu, space to toggle, falling back to a numbered prompt where curses is unavailable), takes one or more, and always confirms the set before deleting. Unknown slugs or branches with unmerged commits abort the whole batch before anything is removed. `--no-interactive` keeps the scriptable behaviour of failing when no slug is given.
- `remove` refuses to delete a branch with unmerged commits unless you pass `--force-delete-branch`, and prints the tip SHA first so the work is recoverable from the reflog.
- `remove` reaps the clone's `ddev-<project>_default` Docker network after deleting the project, so the removed clone reclaims its address block. `ddev delete` frees that network only when it runs from the project directory, so orphaned clones would otherwise leave networks behind until Docker's default address pool is exhausted. `list --stale` lists any such leftovers and the `remove <slug>` that reclaims each.
- `rm -rf` is guarded to the worktrees root.
- `create` refuses to run from inside an existing clone.
- Provisioning is serialized with `flock`, or a `mkdir` lock where `flock` is absent, as on macOS. The golden snapshot is staged under a temporary name and moved into place, so a `refresh-db` racing a `create` cannot hand out a half-written file.
- Every failure mode has its own exit code, so an orchestrator can branch without parsing text. An unhandled failure exits 24 rather than masquerading as one of them.

`ddev poweroff` and `ddev delete --all` are global: they destroy your main project along with every other DDEV project on the machine. Nothing here can stop that, so deny them in your agent's tooling.

## Exit codes

| Code | Meaning |
|---|---|
| 1 | Not in a DDEV project |
| 2 | Bad slug or usage |
| 3 | Slug already in use |
| 4 | Disk space or clone cap |
| 5 | Unsafe `rm -rf` path |
| 6 | No golden snapshot |
| 7 | `git worktree add` failed |
| 8 | Snapshot copy failed |
| 9 | `ddev start` failed |
| 10 | `ddev snapshot restore` failed |
| 11 | Restore hook failed |
| 12 | Host hook failed |
| 13 | Verification failed |
| 14 | Host tooling missing, or `agent-env.yaml` unreadable or invalid |
| 15 | DNS does not resolve |
| 16 | Write failed |
| 17 | Copy failed |
| 18 | `refresh-db` failed |
| 19 | `ddev delete` failed |
| 20 | Lock timeout |
| 21 | Run from inside a clone |
| 22 | Branch has unmerged commits |
| 23 | Confirmation declined |
| 24 | Unhandled failure |

## Licence

Apache-2.0.
