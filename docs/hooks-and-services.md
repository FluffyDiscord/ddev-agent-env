# Hooks and services

**Run container work from DDEV's own hooks, not from `agent-env.yaml`.** `agent-env.yaml` has just two host-side hooks, for the two moments DDEV has no event for: right after a clone is created, and just before it's deleted.

## Clone-time work

**Put anything that must run after a restore in DDEV's native `hooks:`**, in a tracked `.ddev/config.agent-env.yaml`. DDEV's hooks take a `service:` per task and fire on *every* restore, including one an agent runs inside its own clone hours later. `agent-env.yaml` hooks run once, from `create`, and never see that later restore.

## Rewrite the stored hostname

An app that resolves its site by hostname keeps that hostname in the database. A restored clone then serves 500 on every page until you rewrite it:

`.ddev/config.agent-env.yaml`

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

Why it works:

- `DDEV_HOSTNAME` is set in the db container too. It lists the clone's hostnames comma-separated, primary first, so `${DDEV_HOSTNAME%%,*}` is the clone's primary hostname. No templating, nothing to inject.
- The regex is anchored on the TLD. In the source project it replaces the hostname with itself, so one committed hook is right in every project.
- DDEV's Postgres restore reports healthy (`pg_isready`) while the server is still read-only. The `pg_is_in_recovery()` loop waits that out. <!-- UNVERIFIED: DDEV's restore window where pg_isready passes but the server is still in recovery -->

> The regex assumes the default `ddev.site` TLD. Using `project_tld`? Put yours in the pattern.

## Rebuild the search index

A restored clone has its catalogue back but an empty search index. Add a second task on `web`. The search container reports "running" before it accepts queries, so poll it first:

```yaml
hooks:
  post-restore-snapshot:
    # ...the db task above...
    - exec: |
        if [ ! -f vendor/autoload.php ]; then
          echo "vendor not installed yet; skipping reindex"
          exit 0
        fi
        for i in $(seq 1 30); do
          curl -sf -o /dev/null "http://ddev-${DDEV_SITENAME}-search:9308/" && break
          sleep 1
        done
        bin/console app:search:reindex --no-interaction
      service: web
```

- `ddev-${DDEV_SITENAME}-search` resolves to *this* clone's own search container ([rule 2](#extra-services)), so each clone reindexes against its own restored data.
- **Keep the `vendor` guard.** `create --fresh-deps` restores the snapshot before it installs dependencies, so `bin/console` doesn't exist yet when the hook fires. Without the guard the hook fails, and with it the whole `create`. Reindex by hand once deps are in, or from `post_worktree`.

## Failing hooks fail the clone

**Each clone gets `fail_on_hook_fail: true`.** A failing hook fails the restore rather than printing a warning nobody reads. Your source project keeps its own setting.

| Fails | `create` exits with | The clone |
|---|---|---|
| A `post-restore-snapshot` hook | 11 | stays, with its database restored but unfixed |
| The restore itself | 10 | stays |
| `ddev start` | 9 | stays |

`create` reports 11 when the failed restore's output mentions a hook or "task failed". Any other restore failure is 10.

## Host-side hooks

**Use `post_worktree` and `pre_remove` only for once-per-clone work.** Anything tied to a restore or start belongs in DDEV's hooks above.

`.ddev/agent-env.yaml`

```yaml
hooks:
  post_worktree:
    - ddev exec bin/console app:license:claim
    - |
      ddev exec bin/console cache:warmup
      ddev exec bin/console app:search:reindex
  pre_remove:
    - ddev exec bin/console app:license:release
```

| Hook | Runs | Skipped |
|---|---|---|
| `post_worktree` | Once per `create`, after the clone is started and restored, and after `--fresh-deps` installs; just before verification | With `--no-start` |
| `pre_remove` | Once per clone in `remove`, after you confirm, before `ddev delete` | When the clone's worktree directory is already gone |

The full order is in [create](commands.md#create) and [remove](commands.md#remove).

How each command runs:

- Each list item is one command, run with `bash -c` on the host from the clone's worktree directory. A `- |` block runs as one multi-line script.
- The list comes from the source project's `.ddev/agent-env.yaml`.
- Commands run in list order. A single string works as well as a list.
- stdin is empty, so a command that prompts reads EOF.
- `ddev exec` in a hook starts a stopped clone first.

**The first failing command stops the run with exit 12.** So does a worktree directory the hook can't enter; the hook then doesn't run.

- In `create`, the clone stays. Fix the hook, then `ddev agent-env remove <slug>` and create again.
- In `remove`, the clone isn't deleted. In a batch, clones removed before it are gone and the rest stay.

## Extra services

**Services in `.ddev/docker-compose.*.yaml` clone with no extra work**, because DDEV derives the compose project from the project name. Four rules keep that true:

1. **No fixed host `ports:`.** The second clone can't bind them. Use `expose:` with `HTTP_EXPOSE`/`HTTPS_EXPOSE` through the router, or `web_extra_exposed_ports` for a daemon in the web container.
2. **No literal `container_name:`.** Use `ddev-${DDEV_SITENAME}-<service>`.
3. **No literal `com.ddev.approot` or `com.ddev.site-name` labels.** Use `${DDEV_APPROOT}` and `${DDEV_SITENAME}`. A literal makes the clone's container claim it belongs to the source project, so stopping the source project tears the clone's service down. <!-- UNVERIFIED: which source-project command (ddev stop / ddev delete) acts on the mislabelled container -->
4. **No `external: true` volumes or networks.** Every clone shares them.

```yaml
services:
  search:
    image: manticoresearch/manticore
    container_name: ddev-${DDEV_SITENAME}-search
    labels:
      com.ddev.site-name: ${DDEV_SITENAME}
      com.ddev.approot: ${DDEV_APPROOT}
    expose:
      - "9308"
```

**A service's config clones; its data doesn't.** A clone's search index, queue or cache starts empty. Rebuild seed state from a `post-restore-snapshot` or `post-start` hook, like the [reindex](#rebuild-the-search-index) above.
