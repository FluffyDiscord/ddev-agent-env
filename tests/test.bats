#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." >/dev/null && pwd)"
  [ -n "$DIR" ]
  export DIR
  export COMMAND="${DIR}/commands/host/agent-env"
  export TESTDIR="$(mktemp -d)"
  export DDEV_APPROOT="${TESTDIR}/project"
  export DDEV_PROJECT="testproj"
  export DDEV_TLD="ddev.site"
  mkdir -p "${DDEV_APPROOT}/.ddev/db_snapshots"
  git -C "${DDEV_APPROOT}" init -q
  git -C "${DDEV_APPROOT}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

teardown() {
  rm -rf "${TESTDIR}"
}

library() {
  AGENT_ENV_LIBRARY_ONLY=1 source "${COMMAND}"
}

@test "syntax is valid" {
  run bash -n "${COMMAND}"
  [ "$status" -eq 0 ]
}

@test "refuses to run outside a DDEV project" {
  DDEV_APPROOT="" run bash "${COMMAND}" list
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside a DDEV project"* ]]
}

@test "rejects a slug with uppercase or underscore" {
  run bash "${COMMAND}" create Feature_1
  [ "$status" -eq 2 ]
}

@test "rejects a slug with a trailing hyphen" {
  run bash "${COMMAND}" create alpha-
  [ "$status" -eq 2 ]
}

@test "rejects a slug that overruns the 63-character DNS label limit" {
  run bash "${COMMAND}" create "$(printf 'a%.0s' {1..60})"
  [ "$status" -eq 2 ]
  [[ "$output" == *"63"* ]]
}

@test "rejects a second positional argument" {
  run bash "${COMMAND}" create alpha beta
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected argument"* ]]
}

@test "--from without a value is a slug error, not an unbound variable" {
  run bash "${COMMAND}" create alpha --from
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from requires a value"* ]]
}

@test "create refuses from inside a linked worktree" {
  git -C "${DDEV_APPROOT}" worktree add -q "${TESTDIR}/linked" -b linked
  mkdir -p "${TESTDIR}/linked/.ddev"
  DDEV_APPROOT="${TESTDIR}/linked" run bash "${COMMAND}" create beta
  [ "$status" -eq 21 ]
  [[ "$output" == *"already an agent clone"* ]]
}

@test "path validates the slug before touching the filesystem" {
  run bash "${COMMAND}" path ../../etc
  [ "$status" -eq 2 ]
}

@test "path fails for an unknown slug" {
  run bash "${COMMAND}" path nosuchslug
  [ "$status" -eq 3 ]
}

@test "remove fails for an unknown slug" {
  run bash "${COMMAND}" remove nosuchslug
  [ "$status" -eq 3 ]
}

@test "remove without a slug and --no-interactive fails as before" {
  run bash "${COMMAND}" remove --no-interactive
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "remove without a slug reports when there are no clones to pick" {
  run bash "${COMMAND}" remove
  [ "$status" -eq 3 ]
  [[ "$output" == *"clones"* ]]
}

@test "unknown subcommand is rejected" {
  run bash "${COMMAND}" frobnicate
  [ "$status" -eq 2 ]
}

@test "help lists every subcommand" {
  run bash "${COMMAND}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"create"* ]]
  [[ "$output" == *"refresh-db"* ]]
  [[ "$output" == *"AGENT_ENV_BASE_BRANCH"* ]]
}

@test "readConfigJson emits only JSON on stdout when the config is absent" {
  library
  run --separate-stderr readConfigJson
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  [[ "$stderr" == *"agent-env.yaml.example"* ]]
}

@test "readConfigJson parses a real config" {
  library
  printf 'max_clones: 3\ncopy_paths:\n  derived:\n    - vendor\n' >"${DDEV_APPROOT}/.ddev/agent-env.yaml"
  run readConfigJson
  [ "$status" -eq 0 ]
  [[ "$output" == *'"max_clones": 3'* ]]
}

@test "queryConfig handles absent keys, scalars and lists" {
  library
  local json='{"max_clones": 5, "copy_paths": {"derived": ["vendor", "node_modules"]}}'
  run queryConfig "$json" "max_clones";        [ "$output" = "5" ]
  run queryConfig "$json" "copy_paths.derived"; [ "$output" = "vendor
node_modules" ]
  run queryConfig "$json" "nope";               [ "$output" = "" ]
  run queryConfig "$json" "max_clones.deeper";  [ "$output" = "" ]
}

@test "queryConfig is not injectable through a config value" {
  library
  local json='{"hooks": {"post_worktree": ["echo it'"'"'s fine"]}}'
  run queryConfig "$json" "hooks.post_worktree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"it's fine"* ]]
}

@test "getFreeGb returns 0 for a path that does not exist" {
  library
  run getFreeGb /no/such/path/at/all
  [ "$output" = "0" ]
}

@test "copyEnvFiles rewrites the host and redacts declared keys" {
  library
  printf 'MAILER_WEB_URL="https://src.ddev.site:8026"\nTHIRD_PARTY_SECRET_KEY=live123\nexport THIRD_PARTY_SECRET_KEY=live456\nOTHER_THIRD_PARTY_SECRET_KEY=keepme\n' \
    >"${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_rewrite_paths":[".env.local"],"env_redact":["THIRD_PARTY_SECRET_KEY"]}' \
    "${TESTDIR}/clone" src.ddev.site clone.ddev.site no

  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" == *"https://clone.ddev.site:8026"* ]]
  [[ "$output" == *"THIRD_PARTY_SECRET_KEY=REDACTED-IN-CLONE"* ]]
  [[ "$output" == *"export THIRD_PARTY_SECRET_KEY=REDACTED-IN-CLONE"* ]]
  [[ "$output" == *"OTHER_THIRD_PARTY_SECRET_KEY=keepme"* ]]
  [[ "$output" != *"live123"* ]]
  [[ "$output" != *"live456"* ]]
}

@test "copyEnvFiles keeps secrets when --with-secrets is requested" {
  library
  printf 'THIRD_PARTY_SECRET_KEY=live123\n' >"${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_rewrite_paths":[".env.local"],"env_redact":["THIRD_PARTY_SECRET_KEY"]}' \
    "${TESTDIR}/clone" src.ddev.site clone.ddev.site yes
  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" == *"live123"* ]]
}

@test "copyEnvFiles redacts even when env_rewrite_paths is omitted" {
  library
  printf 'THIRD_PARTY_SECRET_KEY=live123\n' >"${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_redact":["THIRD_PARTY_SECRET_KEY"]}' "${TESTDIR}/clone" src.ddev.site clone.ddev.site no
  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" != *"live123"* ]]
}

@test "copyEnvFiles preserves the source file mode" {
  library
  printf 'A=1\n' >"${DDEV_APPROOT}/.env.local"
  chmod 600 "${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_rewrite_paths":[".env.local"]}' "${TESTDIR}/clone" src.ddev.site clone.ddev.site no
  run stat -c '%a' "${TESTDIR}/clone/.env.local"
  [ "$output" = "600" ]
}

@test "copyTree does not nest when the reflink fallback is taken" {
  library
  mkdir -p "${DDEV_APPROOT}/vendor/sub"
  echo hi >"${DDEV_APPROOT}/vendor/f.txt"
  copyTree "${DDEV_APPROOT}/vendor" "${TESTDIR}/clone/vendor"
  [ -f "${TESTDIR}/clone/vendor/f.txt" ]
  [ ! -e "${TESTDIR}/clone/vendor/vendor" ]
}

@test "resolveCloneSelections parses lists, dedups, and rejects bad input" {
  library
  run resolveCloneSelections "" 3;      [ "$status" -eq 0 ]; [ "$output" = "CANCEL" ]
  run resolveCloneSelections "   " 3;   [ "$output" = "CANCEL" ]
  run resolveCloneSelections abc 3;     [ "$output" = "INVALID" ]
  run resolveCloneSelections 0 3;       [ "$output" = "INVALID" ]
  run resolveCloneSelections 4 3;       [ "$output" = "INVALID" ]
  run resolveCloneSelections 2 3;       [ "$output" = "2" ]
  run resolveCloneSelections 08 8;      [ "$output" = "8" ]
  run resolveCloneSelections "1 3" 3;   [ "$output" = "1 3" ]
  run resolveCloneSelections "3,1,3" 3; [ "$output" = "3 1" ]
  run resolveCloneSelections "1 5" 5;   [ "$output" = "1 5" ]
  run resolveCloneSelections "1 6" 5;   [ "$output" = "INVALID" ]
  run resolveCloneSelections "1 x" 5;   [ "$output" = "INVALID" ]
}

@test "the curses selector reports unavailable when given no rows" {
  library
  run pythonCursesSelect
  [ "$status" -eq 4 ]
}

@test "runCursesPicker maps an unavailable curses helper to a fallback signal" {
  library
  run runCursesPicker
  [ "$status" -eq 0 ]
  [ "$output" = "UNAVAILABLE" ]
}

@test "listCloneSlugs lists worktree directories and nothing when the root is absent" {
  library
  run listCloneSlugs
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local root="$(dirname "$DDEV_APPROOT")/$(basename "$DDEV_APPROOT")-agents"
  mkdir -p "${root}/alpha" "${root}/beta"
  run listCloneSlugs
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "getCloneNetworkName maps a project to its DDEV network name" {
  library
  run getCloneNetworkName testproj-issue-42
  [ "$output" = "ddev-testproj-issue-42_default" ]
}

@test "filterLeakedCloneNetworks reports only clone networks with no registered project" {
  library
  local prefix="ddev-testproj-"
  local networks="ddev-testproj-alpha_default
ddev-testproj-beta_default
ddev-testproj_default
ddev-otherproj-gamma_default
bridge"
  local registered="testproj-beta
testproj
otherproj-gamma"
  run filterLeakedCloneNetworks "$networks" "$registered" "$prefix"
  [ "$status" -eq 0 ]
  [ "$output" = "ddev-testproj-alpha_default" ]
}

@test "filterLeakedCloneNetworks never flags the source project's own network" {
  library
  run filterLeakedCloneNetworks "ddev-testproj_default" "" "ddev-testproj-"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "getBaseBranch prefers the override then the current branch" {
  library
  run getBaseBranch
  [ "$output" = "master" ] || [ "$output" = "main" ]
  AGENT_ENV_BASE_BRANCH=release run getBaseBranch
  [ "$output" = "release" ]
}

@test "reportMigrationSkew warns when the snapshot is ahead of the branch" {
  library
  local dir="${DDEV_APPROOT}/.ddev/db_snapshots"
  printf 'Version1.php\nVersion2.php\n' >"${dir}/agent-golden.migrations"
  mkdir -p "${TESTDIR}/clone/migrations"
  touch "${TESTDIR}/clone/migrations/Version1.php"
  run --separate-stderr reportMigrationSkew "${TESTDIR}/clone" migrations
  [[ "$stderr" == *"AHEAD of its code"* ]]
}

@test "reportMigrationSkew is silent when the sets match" {
  library
  local dir="${DDEV_APPROOT}/.ddev/db_snapshots"
  printf 'Version1.php\n' >"${dir}/agent-golden.migrations"
  mkdir -p "${TESTDIR}/clone/migrations"
  touch "${TESTDIR}/clone/migrations/Version1.php"
  run --separate-stderr reportMigrationSkew "${TESTDIR}/clone" migrations
  [ -z "$stderr" ]
}

@test "the command carries no SQL and no template tokens" {
  run grep -c 'app_channel\|{{SOURCE_HOST}}\|{{CLONE_HOST}}' "${COMMAND}"
  [ "$output" -eq 0 ]
}

@test "every declared exit code is actually used" {
  local code
  for code in $(grep -oE '^readonly (EXIT_[A-Z_]+)=' "${COMMAND}" | sed 's/readonly //;s/=//'); do
    run grep -c "\$${code}\b" "${COMMAND}"
    [ "$output" -ge 1 ] || { echo "unused: $code"; false; }
  done
}

@test "install.yaml ships the command globally and the config as an example" {
  run grep -A2 '^global_files:' "${DIR}/install.yaml"
  [[ "$output" == *"commands/host/agent-env"* ]]
  run grep -A2 '^project_files:' "${DIR}/install.yaml"
  [[ "$output" == *"agent-env.yaml.example"* ]]
}

@test "the shipped command and the example config carry the ddev-generated marker" {
  run grep -c '#ddev-generated' "${COMMAND}"
  [ "$output" -ge 1 ]
  run grep -c '#ddev-generated' "${DIR}/agent-env.yaml.example"
  [ "$output" -ge 1 ]
}
