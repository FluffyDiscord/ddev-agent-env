# Commands

Run every command from the source project's directory. `ddev agent-env --help` prints a short version of this page.

## create

`ddev agent-env create <slug> [flags]` clones the source project for one agent:

| What | Value |
|---|---|
| Worktree | `../<dir>-agents/<slug>`, where `<dir>` is the source project's directory name |
| Branch | `agent/<slug>`, new, from `HEAD` |
| DDEV project | `<project>-<slug>` |
| Database | The golden snapshot, restored |

The slug takes lowercase letters, digits and inner hyphens: `issue-42` works, `Issue_42` and `-42` don't. `<project>-<slug>` must fit in 63 characters, the DNS label limit.

| Flag | Effect |
|---|---|
| `--from <ref>` | Branches from `<ref>` instead of `HEAD`. |
| `--fresh` | Skips the snapshot restore, so the clone starts with an empty database. |
| `--fresh-deps` | Skips copying `copy_paths.derived` and installs dependencies in the clone instead. |
| `--with-secrets` | Keeps the real values of the `env_redact` keys. |
| `--no-start` | Builds the worktree but doesn't start DDEV. |
| `--force` | Skips the disk-space, clone-count and DNS checks. |

**`--fresh-deps` installs only what the project has**, then runs `ddev restart`:

| When the clone has | `create` runs |
|---|---|
| `composer.json` | `ddev composer install --no-interaction` |
| `package.json` | `ddev npm ci` |
| A `build` script in `package.json` | `ddev npm run build` |

A failed install exits 26.

Before it builds anything, `create` runs these checks in order:

| Check | Fails with | Skipped by `--force` |
|---|---|---|
| The slug is valid. | 2 | no |
| You're not inside a linked git worktree. Every clone is one. | 21 | no |
| `python3` with PyYAML is installed, and git is 2.31 or newer. | 27 | no |
| The worktree, the `agent/<slug>` branch and the `<project>-<slug>` DDEV project don't exist yet. | 3 | no |
| The worktrees root has at least 10 GB free, and Docker's data directory at least 5 GB. | 4 | yes |
| `.ddev/agent-env.yaml` parses, and `smoke_path` and `smoke_status` are valid. | 14 | no |
| Fewer clones are running than [`max_clones`](configuration.md#options). | 4 | yes |
| `<project>-<slug>.ddev.site` resolves. Otherwise DDEV would edit `/etc/hosts`, which needs sudo. | 15 | yes |

> Docker Desktop, OrbStack and Colima keep Docker's data inside a VM. `create` then skips the Docker free-space check and warns.

From 4 running clones on, `create` warns about RAM.

**`create` takes the golden snapshot itself when there's none yet.** That needs the source project running. A stopped one fails with exit 6; start it or pass `--fresh`.

Then `create`:

1. Warns when the source project has uncommitted changes. The clone doesn't get them.
2. Adds the worktree and branch.
3. Writes the clone's DDEV config, copies `copy_paths`, rewrites the `env_rewrite_paths` files and copies the golden snapshot in.
4. Starts the clone and restores the snapshot.
5. Warns when the migration filenames differ from the ones recorded with the snapshot.
6. Installs dependencies and restarts, with `--fresh-deps`.
7. Runs the `hooks.post_worktree` commands from the worktree directory.
8. Verifies the clone: git works in the web container, every `copy_paths` entry exists, and `smoke_path` returns a `smoke_status`.
9. Prints the worktree, project, branch and URL.

- `--no-start` stops after step 3. It checks only that git works in the worktree and that the `copy_paths` entries exist.
- `--fresh` skips the restore, the migration check and the smoke check, since there's no data to test against.
- With `--fresh-deps`, the `derived` entries aren't checked.

**A failure up to step 3 removes the half-built worktree and branch.** A later failure leaves the clone in place. Clean it up with `ddev agent-env remove <slug>`.

## list

`ddev agent-env list` prints one row per directory under the worktrees root:

```text
SLUG             STATUS       PROJECT                    BRANCH                 AHEAD/BEHIND PATH
issue-42         running      myapp-issue-42             agent/issue-42         3/0        /home/me/myapp-agents/issue-42/
```

- `STATUS` is the DDEV project's status, or `not registered`.
- `AHEAD/BEHIND` counts commits against the base branch: `3/0` = 3 ahead, 0 behind. It shows `?` when git can't count.

`--stale` adds three lists of orphans:

- DDEV projects whose directory under the worktrees root is gone.
- Worktrees with no DDEV project.
- Docker networks `ddev-<project>-*_default` with no DDEV project. Each holds one Docker address block, and each line shows the `remove <slug>` that reclaims it.

Any other argument exits 2.

## path

`ddev agent-env path <slug>` prints the clone's worktree path.

```bash
cd "$(ddev agent-env path issue-42)"
```

- No worktree for the slug exits 25.
- An invalid slug or a second argument exits 2.

## remove

`ddev agent-env remove <slug>` deletes the clone, in this order:

1. Runs the `hooks.pre_remove` commands from the worktree directory, when the worktree exists.
2. Runs `ddev delete -Oy`. The clone's database goes without a snapshot.
3. Removes the clone's `ddev-<project>-<slug>_default` Docker network.
4. Removes the worktree.
5. Deletes the `agent/<slug>` branch.
6. Prints which parts it removed: `removed issue-42: project=yes worktree=yes branch=yes network=yes`.

It works on partial leftovers too. Any one of worktree, DDEV project or network is enough. With none of them, it exits 25.

A network that won't go is left with a warning and the `docker network rm` command to run; the rest of the removal goes on.

| Flag | Effect |
|---|---|
| `--yes`, `-y` | Skips the confirmation. Ignored when you pick from the menu. |
| `--no-interactive` | Fails with exit 2 instead of opening the menu when no slug is given. |
| `--keep-branch` | Keeps the `agent/<slug>` branch. |
| `--force-delete-branch` | Deletes the branch even when it has unmerged commits. |

Without `--yes`, `remove` asks on the terminal:

```text
Remove these clones, their databases, and worktrees?
  - issue-42                 myapp-issue-42             /home/me/myapp-agents/issue-42
[y/N]
```

**Scripts must pass `--yes`.** The confirmation reads from the terminal; with none, it counts as a no and exits 23.

**Unmerged commits block the removal.** A commit counts as unmerged when it's on `agent/<slug>` but neither on the base branch nor on any remote-tracking branch, so pushed work is safe. Pass `--keep-branch` or `--force-delete-branch` to go ahead.

> A base branch that doesn't exist makes every commit count as unmerged. `remove` then exits 22 and names the missing branch. Set `AGENT_ENV_BASE_BRANCH` to the branch agent work merges into.

Before deleting the branch, `remove` prints how to get it back:

```text
deleting branch agent/issue-42 at 1a2b3c4…; until git gc prunes it, restore it with: git branch agent/issue-42 1a2b3c4…
```

## Picking from the menu

With no slug, `remove` opens a menu of the clones that have a worktree. Orphans don't show up; find them with `list --stale`.

| Key | Action |
|---|---|
| Up/Down, `k`/`j` | Move |
| Space | Toggle |
| `a` | Toggle all |
| Enter | Confirm the checked clones, or the current one when none is checked |
| `q`, Esc | Cancel |

Without curses, a numbered prompt replaces the menu. Type numbers separated by spaces or commas. Enter on its own cancels, and so does waiting past `AGENT_ENV_SELECT_TIMEOUT`.

| Situation | Exit |
|---|---|
| No clone has a worktree. | 25 |
| There's no terminal. | 2 |
| The selection is invalid. | 2 |
| You cancel, or the prompt times out. | 23 |

The picked set is always confirmed before anything is deleted.

## refresh-db

`ddev agent-env refresh-db` retakes the golden snapshot from the running source project. Run it after schema or seed-data changes, so new clones start current.

- It replaces `.ddev/db_snapshots/agent-golden-*`.
- It records the filenames in `migrations_path`, which `create` compares against. Without that directory, it drops the old record.
- A stopped source project fails with exit 18.

Existing clones keep their database.

## self-update

`ddev agent-env self-update` replaces the global command with the script from the latest GitHub release. Run it from any project; every project gets the new version.

A failed download or a script that doesn't parse leaves the installed command untouched and exits 28.

## Environment variables

All optional. Set them per call or in your shell profile:

```bash
AGENT_ENV_DISK_FLOOR_GB=5 ddev agent-env create issue-42
```

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_ENV_BASE_BRANCH` | The source project's current branch | The branch `remove` checks for unmerged commits and `list` counts against. |
| `AGENT_ENV_WARN_CLONES` | `4` | The running-clone count at which `create` warns about RAM. |
| `AGENT_ENV_DISK_FLOOR_GB` | `10` | The free GB `create` needs on the worktrees root. |
| `AGENT_ENV_DOCKER_FLOOR_GB` | `5` | The free GB `create` needs on Docker's data directory. |
| `AGENT_ENV_LOCK_TIMEOUT` | `600` | The seconds `create` and `refresh-db` wait for another run to finish. |
| `AGENT_ENV_SELECT_TIMEOUT` | `60` | The seconds the numbered `remove` prompt waits for an answer. |

> With a detached `HEAD` in the source project, the base branch is `master`. A non-numeric `AGENT_ENV_SELECT_TIMEOUT` falls back to 60.

The clone cap is the `max_clones` key in [agent-env.yaml](configuration.md#options).

## Safety

- **`create` and `refresh-db` run one at a time** per source project. A second run waits up to `AGENT_ENV_LOCK_TIMEOUT`, then exits 20.
- A new golden snapshot is written under a temporary name and moved into place, so `create` never copies a half-written file.
- `remove` deletes only paths under the worktrees root.
- `remove` checks every picked slug before deleting anything. One unknown slug or one unmerged branch aborts the whole batch.

**`ddev poweroff` and `ddev delete --all` hit every DDEV project on the machine**, your main one included. Nothing here can stop them, so deny both in your agent's tooling.

## Exit codes

| Code | Meaning |
|---|---|
| 1 | You're not in a DDEV project. |
| 2 | Bad usage: invalid slug, unknown flag or subcommand, extra argument, `--from` without a value, an invalid menu selection, or no terminal for the menu. |
| 3 | `create`: the worktree, branch or DDEV project already exists. |
| 4 | `create`: free disk is below a floor, or the running clones are at the cap. |
| 5 | `remove`: the worktree path is outside the worktrees root. |
| 6 | `create`: there's no golden snapshot and the source project isn't running. |
| 7 | `git worktree add` failed. |
| 8 | Copying the golden snapshot into the clone failed. |
| 9 | `ddev start` failed, or `ddev restart` after `--fresh-deps`. |
| 10 | `ddev snapshot restore` failed. |
| 11 | A `post-restore-snapshot` hook failed. The database is restored but not fixed up. |
| 12 | A `hooks.post_worktree` or `hooks.pre_remove` command failed, or couldn't enter the worktree. |
| 13 | Verification failed: git, a `copy_paths` entry, the clone's URL, or the smoke check. |
| 14 | `agent-env.yaml` is unreadable, or `smoke_path` or `smoke_status` is invalid. |
| 15 | `create`: the clone's hostname doesn't resolve. |
| 16 | Writing a file in the clone failed. |
| 17 | Copying a `copy_paths` entry or rewriting an `env_rewrite_paths` file failed. |
| 18 | Taking the golden snapshot failed, or the source project isn't running. |
| 19 | `remove`: `ddev delete` failed, or the worktree couldn't be deleted. |
| 20 | Another `create` or `refresh-db` held the lock past the timeout. |
| 21 | `create` ran inside a linked git worktree. |
| 22 | `remove`: a branch has unmerged commits, or the base branch doesn't exist. |
| 23 | The confirmation got no yes, or the menu was cancelled or timed out. |
| 24 | Unhandled failure. |
| 25 | `path`, `remove`: there's no such clone, or no clone to pick from. |
| 26 | `--fresh-deps`: `composer install`, `npm ci` or `npm run build` failed. |
| 27 | `python3` with PyYAML is missing, or git is older than 2.31. |
| 28 | `self-update`: the latest release couldn't be read, downloaded or parsed. |
