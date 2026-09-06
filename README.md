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

`ddev clone` [does not exist yet](https://github.com/ddev/ddev/issues/8187); by hand it produces a clone that does not work.

## What a clone gets

| | How |
|---|---|
| Code | `git worktree add`, fresh `agent/<slug>` branch |
| Project identity | `name:` in `.ddev/config.local.yaml` (DDEV git-ignores it; tracked `config.yaml` untouched) |
| Database | reusable golden `ddev snapshot`, restored into the clone |
| Dependencies, media, build artifacts | `cp --reflink` from the source: seconds, no real disk until modified. No reflink support → full copy, reported |
| Extra services | automatic — DDEV namespaces containers and volumes by project name |
| `git` inside the containers | generated compose file bind-mounting the main repo's `.git` at its host path |

## Install

```bash
ddev add-on get FluffyDiscord/ddev-agent-env
cp .ddev/agent-env.yaml.example .ddev/agent-env.yaml
```

Edit `.ddev/agent-env.yaml` before the first `create` — the template is a placeholder, not a working config.

Requires DDEV ≥ v1.24.10, git ≥ 2.31, and `python3` (with PyYAML), `curl`, `docker` on the host. Install checks those. Linux and macOS: `flock`, `getent` and `cp --reflink` where available, otherwise a `mkdir` lock, `python3` socket resolution, APFS `cp -c`, or full copies.

> **Installs globally** (`~/.config/ddev/commands/host/agent-env`). DDEV does not reference-count global files: `ddev add-on remove agent-env` in *any* project deletes it for *all*. Install adds `.ddev/addon-metadata/` to `.gitignore` so a clone cannot uninstall it.

## Commands

`ddev agent-env --help` prints the same reference.

| | |
|---|---|
| `create <slug>` | Clone into `../<project>-agents/<slug>` on branch `agent/<slug>`, as DDEV project `<project>-<slug>`; restore the golden snapshot, start, smoke-test |
| `list [--stale]` | List clones and status; `--stale` adds orphans — project with no worktree, worktree with no project, leftover Docker network |
| `path <slug>` | Print the clone's worktree path |
| `remove [<slug>]` | Delete DDEV project, database, worktree, branch, leftover network. No slug → menu |
| `refresh-db` | Retake the golden snapshot from the running source project. Run after schema or seed-data changes |

`create` flags:

| | |
|---|---|
| `--from <ref>` | Branch from `<ref>` instead of `HEAD` |
| `--fresh` | Empty database, skip the snapshot restore |
| `--fresh-deps` | Reinstall the `derived` paths instead of copying them |
| `--with-secrets` | Keep real values instead of redacting `env_redact` keys |
| `--no-start` | Build the worktree, do not start DDEV |
| `--force` | Override the disk-space, clone-count and DNS checks |

`remove` flags:

| | |
|---|---|
| `--yes`, `-y` | Skip confirmation (unattended) |
| `--no-interactive` | Fail instead of opening the menu when no slug is given |
| `--keep-branch` | Keep `agent/<slug>` |
| `--force-delete-branch` | Delete it even with unmerged commits |

Optional env knobs: `AGENT_ENV_BASE_BRANCH` (unmerged-commit comparison, default: the source project's current branch), `AGENT_ENV_MAX_CLONES`, `AGENT_ENV_WARN_CLONES`, `AGENT_ENV_DISK_FLOOR_GB`, `AGENT_ENV_DOCKER_FLOOR_GB`, `AGENT_ENV_LOCK_TIMEOUT`, `AGENT_ENV_SELECT_TIMEOUT`.

## Configuration

`.ddev/agent-env.yaml` declares the untracked state a fresh worktree lacks.

| Key | Meaning |
|---|---|
| `copy_paths.derived` | Regenerable by `composer install` / `npm ci` / a build. `--fresh-deps` replaces only these |
| `copy_paths.materialized` | Nothing regenerates these — key files, media, fixture data |
| `env_rewrite_paths` | Copied with the source hostname replaced by the clone's — `MAILER_WEB_URL="https://myproject.ddev.site:8026"` no longer points every agent at the main mailbox |
| `env_redact` | Named keys blanked to `REDACTED-IN-CLONE` unless `--with-secrets`. Otherwise every clone carries live credentials |
| `migrations_path` | Default `migrations`. Filenames are recorded with the golden snapshot; `create` warns on drift |
| `smoke_path` | Default `/`. Requested on the clone's primary URL as the last step of `create` |
| `smoke_status` | Default `200`. Also a list: `[200, 302]` |
| `max_clones` | Clone cap |

Migration drift: database ahead of code → `doctrine:migrations:diff` invents duplicates. Code ahead → run migrations before trusting the schema.

No page at `/`? Point the check at a route that answers; `401` proves PHP, routing and the restored database are alive:

```yaml
smoke_path: /api/v1/widget/config
smoke_status: 401
```

- Leading slash optional.
- Non-numeric `smoke_status`, or a `smoke_path` that is a URL → exit 14 at the *start* of `create`.
- A wrong status names the URL and the expected status; the "restored data still points at the source project's hostname" hint appears only for a 5xx or a redirect to the source hostname.

### Worked example

```yaml
copy_paths:
  derived:            # composer install / npm ci / build regenerate these
    - vendor
    - node_modules
    - public/build
    - public/bundles
  materialized:       # nothing regenerates these; a fresh worktree lacks them
    - config/jwt/private.pem   # per-file, NOT the config/jwt directory
    - config/jwt/public.pem
    - public/media
    - var/storage

env_rewrite_paths:
  - .env.local

migrations_path: migrations

smoke_path: /api/v1/widget/config   # this backend serves no page at /
smoke_status: 401                   # unauthenticated, but PHP + routing + DB are alive

env_redact:           # blanked to REDACTED-IN-CLONE unless you pass --with-secrets
  - PAYMENT_GATEWAY_SECRET
  - SHIPPING_API_KEY
  - MAILER_DSN

max_clones: 8
```

- **Directories mixing tracked and ignored files: list the untracked files one by one.** The worktree checks out `config/jwt` first, so `cp -a config/jwt <clone>/config/jwt` nests the keys at `config/jwt/jwt/private.pem` and the clone starts without a usable key.
- **Redact the credential, copy the key material.** `env_redact` blanks a secret *value* in `.env.local`; a key *file* read at runtime is `materialized`. Independent: key file present + passphrase redacted means that one feature needs `--with-secrets`, the rest stays scrubbed.

## Per-service hooks — use DDEV's, not ours

Container-side work belongs in DDEV's native `hooks:`, not `agent-env.yaml`: 25 lifecycle events, a `service:` per task, and they fire on *every* restore — including one an agent runs inside its own clone hours later.

An app that resolves its site by hostname stores that hostname in the database; a restored clone serves 500 until it is rewritten. In a tracked `.ddev/config.agent-env.yaml`:

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

- `DDEV_HOSTNAME` inside the container is the clone's own comma-separated hostname list, primary first — `${DDEV_HOSTNAME%%,*}` takes that one. No templating, no injection surface.
- Anchoring the regex on the TLD makes the statement an identity no-op in the source project: one committed hook, correct everywhere.
- The `pg_is_in_recovery()` loop covers the window where DDEV's Postgres restore reports healthy (`pg_isready`) while the server is still read-only.

A hook can wait on a dependency first. A restored clone has the catalogue back but an empty search index, and the container reports "running" before it accepts queries:

```yaml
    - exec: |
        for i in $(seq 1 30); do
          curl -sf -o /dev/null "http://ddev-${DDEV_SITENAME}-search:9308/" && break
          sleep 1
        done
        bin/console app:search:reindex --no-interaction
      service: web
```

`ddev-${DDEV_SITENAME}-search` resolves to *this* clone's search container (rule 2 below), so one committed hook reindexes each clone against its own data.

Clones are created with `fail_on_hook_fail: true` — a failing hook fails the restore instead of printing a warning nobody reads.

`agent-env.yaml`'s own `hooks:` holds only the two host-side stages DDEV has no event for: `post_worktree` (after files are copied, before `ddev start`) and `pre_remove`.

## Arbitrary extra services

Services in `.ddev/docker-compose.*.yaml` clone automatically — DDEV derives the compose project from the project name. Four rules keep that true:

1. No fixed host `ports:` — dynamic bindings or `web_extra_exposed_ports` through the shared router.
2. No literal `container_name:` — use `ddev-${DDEV_SITENAME}-<service>`.
3. No literal `com.ddev.approot` / `com.ddev.site-name` labels — use `${DDEV_APPROOT}` / `${DDEV_SITENAME}`. A literal makes the clone's container claim membership in the source project, so `ddev poweroff` there tears the clone's services down.
4. No `external: true` volumes or networks — those are shared by every clone.

A service's **config** clones; its **data** does not. Seed state belongs in a `post-restore-snapshot` or `post-start` hook that rebuilds it.

## Safety

- `remove` with no slug: arrow-key picker of worktree-backed clones (`python3` curses, space toggles; numbered prompt as fallback), multi-select, always confirms. Unknown slugs or unmerged branches abort the whole batch before anything is removed. `--no-interactive` fails instead.
- `remove` refuses an unmerged branch unless `--force-delete-branch`, and prints the tip SHA for the reflog.
- `remove` reaps the clone's `ddev-<project>_default` network, reclaiming its address block. `ddev delete` frees it only from the project directory, so orphans exhaust Docker's address pool. `list --stale` lists leftovers and the `remove <slug>` that reclaims each.
- `rm -rf` guarded to the worktrees root.
- `create` refuses to run from inside an existing clone.
- Provisioning serialized with `flock` (`mkdir` lock where absent, e.g. macOS); the golden snapshot is staged under a temporary name and moved into place, so `refresh-db` racing a `create` cannot hand out a half-written file.
- Every failure mode has its own exit code; unhandled failures exit 24.

`ddev poweroff` and `ddev delete --all` are global and destroy your main project along with every other DDEV project on the machine. Nothing here can stop that — deny them in your agent's tooling.

## Exit codes

| | | | |
|---|---|---|---|
| 1 not in a DDEV project | 2 bad slug or usage | 3 slug in use | 4 disk or clone cap |
| 5 unsafe `rm -rf` path | 6 no golden snapshot | 7 `git worktree add` | 8 snapshot copy |
| 9 `ddev start` | 10 `ddev snapshot restore` | 11 restore hook | 12 host hook |
| 13 verification | 14 host tooling, or `agent-env.yaml` unreadable or invalid | 15 DNS | 16 write |
| 17 copy | 18 `refresh-db` | 19 `ddev delete` | 20 lock timeout |
| 21 run from inside a clone | 22 unmerged branch | 23 confirmation declined | 24 unhandled failure |

## Licence

Apache-2.0.
