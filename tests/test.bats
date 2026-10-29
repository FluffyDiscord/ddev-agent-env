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
  export WORKTREE_ROOT="${TESTDIR}/project-agents"
  mkdir -p "${DDEV_APPROOT}/.ddev/db_snapshots"
  git -C "${DDEV_APPROOT}" init -q
  git -C "${DDEV_APPROOT}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

teardown() {
  rm -rf "${TESTDIR}"
}

library() {
  local batsTraps
  batsTraps=$(trap -p ERR EXIT)
  AGENT_ENV_LIBRARY_ONLY=1 source "${COMMAND}"
  eval "$batsTraps"
}

addAgentBranch() {
  git -C "${DDEV_APPROOT}" worktree add -q "${WORKTREE_ROOT}/$1" -b "agent/$1"
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

@test "--from without a value exits 2 naming the flag" {
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
  [ "$status" -eq 25 ]
}

@test "remove fails for an unknown slug" {
  run bash "${COMMAND}" remove nosuchslug
  [ "$status" -eq 25 ]
}

@test "remove --no-interactive with no slug exits 2 with usage" {
  run bash "${COMMAND}" remove --no-interactive
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "remove without a slug reports when there are no clones to pick" {
  run bash "${COMMAND}" remove
  [ "$status" -eq 25 ]
  [[ "$output" == *"clones"* ]]
}

@test "remove --yes needs no terminal" {
  mkdir -p "${WORKTREE_ROOT}/alpha"
  run bash "${COMMAND}" remove alpha --yes </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed alpha"* ]]
  [ ! -d "${WORKTREE_ROOT}/alpha" ]
}

@test "remove refuses to delete a branch with commits not in the base branch" {
  addAgentBranch x
  git -C "${WORKTREE_ROOT}/x" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  run bash "${COMMAND}" remove x --yes
  [ "$status" -eq 22 ]
  [[ "$output" == *"agent/x"* ]]
  git -C "${DDEV_APPROOT}" rev-parse --verify -q agent/x
  [ -d "${WORKTREE_ROOT}/x" ]
}

@test "remove refuses to delete a branch when the base branch does not exist" {
  addAgentBranch x
  AGENT_ENV_BASE_BRANCH=nosuchbase run bash "${COMMAND}" remove x --yes
  [ "$status" -eq 22 ]
  [[ "$output" == *"base branch 'nosuchbase' does not exist"* ]]
  git -C "${DDEV_APPROOT}" rev-parse --verify -q agent/x
}

@test "unknown subcommand is rejected" {
  run bash "${COMMAND}" frobnicate
  [ "$status" -eq 2 ]
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

@test "listRebasedHostnames emits nothing when the parent declares no additional_hostnames" {
  library
  printf 'name: testproj\n' >"${DDEV_APPROOT}/.ddev/config.yaml"
  run listRebasedHostnames "testproj-clone"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "listRebasedHostnames rebases the parent's hostnames merged across config files" {
  library
  printf 'name: testproj\nadditional_hostnames:\n  - testproj-admin\n  - shop\n  - shop.testproj\n' >"${DDEV_APPROOT}/.ddev/config.yaml"
  printf 'additional_hostnames: [testproj, "*.testproj", shop]\n' >"${DDEV_APPROOT}/.ddev/config.extra.yaml"
  run listRebasedHostnames "testproj-clone"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\t%s\n' \
    testproj-admin testproj-clone-admin \
    shop testproj-clone-shop \
    shop.testproj shop.testproj-clone \
    testproj testproj-clone \
    '*.testproj' '*.testproj-clone')" ]
}

@test "the clone config replaces the parent's hostnames and leaves the tracked config alone" {
  library
  printf 'name: testproj\nadditional_hostnames:\n  - testproj-admin\nadditional_fqdns:\n  - shop.example\n' >"${DDEV_APPROOT}/.ddev/config.yaml"
  printf 'additional_hostnames: ["*.testproj"]\n' >"${DDEV_APPROOT}/.ddev/config.extra.yaml"
  git -C "${DDEV_APPROOT}" add .ddev
  git -C "${DDEV_APPROOT}" -c user.email=t@t -c user.name=t commit -q -m ddev
  addAgentBranch clone
  writeCloneConfig "${WORKTREE_ROOT}/clone" testproj-clone

  run python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])))' "${WORKTREE_ROOT}/clone/.ddev/config.zz-agent-env.yaml"
  [ "$output" = "{'override_config': True, 'name': 'testproj-clone', 'fail_on_hook_fail': True, 'additional_hostnames': ['testproj-clone-admin', '*.testproj-clone'], 'additional_fqdns': []}" ]
  grep -qxF '/config.zz-agent-env.yaml' "${WORKTREE_ROOT}/clone/.ddev/.gitignore"
  cmp "${DDEV_APPROOT}/.ddev/config.yaml" "${WORKTREE_ROOT}/clone/.ddev/config.yaml"
}

@test "smoke config falls back to / and 200 and takes overrides and status lists" {
  library
  run getSmokePath '{}';                                    [ "$output" = "/" ]
  run getSmokeStatuses '{}';                                [ "$output" = "200" ]
  local json='{"smoke_path": "/api/v1/widget/config", "smoke_status": [200, 302]}'
  run validateSmokeConfig "$json";                          [ "$status" -eq 0 ]
  run getSmokePath "$json";                                 [ "$output" = "/api/v1/widget/config" ]
  run getSmokeStatuses "$json";                             [ "$output" = "200 302" ]
  run matchesSmokeStatus 302 "200 302";                     [ "$status" -eq 0 ]
  run matchesSmokeStatus 404 "200 302";                     [ "$status" -eq 1 ]
}

@test "smoke config rejects a URL as smoke_path and a non-numeric smoke_status with exit 14" {
  library
  run validateSmokeConfig '{"smoke_path": "https://elsewhere.example/health"}'
  [ "$status" -eq 14 ]
  [[ "$output" == *"smoke_path"* ]]
  run validateSmokeConfig '{"smoke_status": [200, "nope"]}'
  [ "$status" -eq 14 ]
  [[ "$output" == *"smoke_status"* ]]
}

@test "the smoke hint blames the hostname only when that is plausible" {
  library
  run describeSmokeHint 404 ""
  [[ "$output" == *"smoke_path"* ]]
  [[ "$output" != *"hostname"* ]]
  run describeSmokeHint 500 ""
  [[ "$output" == *"hostname"* ]]
  run describeSmokeHint 302 "https://testproj.ddev.site/login"
  [[ "$output" == *"hostname"* ]]
  run describeSmokeHint 302 "https://testproj-alpha.ddev.site/login"
  [[ "$output" != *"hostname"* ]]
}

@test "getSourceHost takes the primary name out of DDEV_HOSTNAME's list" {
  library
  DDEV_HOSTNAME="testproj.ddev.site,shop.ddev.site,testproj-sk.ddev.site" run getSourceHost
  [ "$output" = "testproj.ddev.site" ]
  DDEV_HOSTNAME="testproj.ddev.site" run getSourceHost
  [ "$output" = "testproj.ddev.site" ]
  DDEV_HOSTNAME="" run getSourceHost
  [ "$output" = "testproj.ddev.site" ]
}

@test "copyEnvFiles rewrites the primary and additional hostnames and redacts declared keys" {
  library
  printf 'additional_hostnames: [shop.testproj, "*.testproj"]\n' >"${DDEV_APPROOT}/.ddev/config.yaml"
  printf 'MAILER_WEB_URL="https://testproj.ddev.site:8026"\nSHOP_URL=https://shop.testproj.ddev.site\nOTHER_URL=https://foo-testproj.ddev.site\nTHIRD_PARTY_SECRET_KEY=live123\nexport THIRD_PARTY_SECRET_KEY=live456\nOTHER_THIRD_PARTY_SECRET_KEY=keepme\n' \
    >"${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_rewrite_paths":[".env.local"],"env_redact":["THIRD_PARTY_SECRET_KEY"]}' \
    "${TESTDIR}/clone" "$(listEnvHostRewrites testproj-clone)" no

  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" == *"https://testproj-clone.ddev.site:8026"* ]]
  [[ "$output" == *"SHOP_URL=https://shop.testproj-clone.ddev.site"* ]]
  [[ "$output" == *"OTHER_URL=https://foo-testproj.ddev.site"* ]]
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
    "${TESTDIR}/clone" "$(listEnvHostRewrites testproj-clone)" yes
  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" == *"live123"* ]]
}

@test "copyEnvFiles redacts even when env_rewrite_paths is omitted" {
  library
  printf 'THIRD_PARTY_SECRET_KEY=live123\n' >"${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_redact":["THIRD_PARTY_SECRET_KEY"]}' "${TESTDIR}/clone" "$(listEnvHostRewrites testproj-clone)" no
  run cat "${TESTDIR}/clone/.env.local"
  [[ "$output" != *"live123"* ]]
}

@test "copyEnvFiles preserves the source file mode" {
  library
  printf 'A=1\n' >"${DDEV_APPROOT}/.env.local"
  chmod 600 "${DDEV_APPROOT}/.env.local"
  mkdir -p "${TESTDIR}/clone"
  copyEnvFiles '{"env_rewrite_paths":[".env.local"]}' "${TESTDIR}/clone" "$(listEnvHostRewrites testproj-clone)" no
  run ls -l "${TESTDIR}/clone/.env.local"
  [[ "$output" == "-rw-------"* ]]
}

@test "copyTree does not nest when the reflink fallback is taken" {
  library
  mkdir -p "${DDEV_APPROOT}/vendor/sub"
  echo hi >"${DDEV_APPROOT}/vendor/f.txt"
  copyTree "${DDEV_APPROOT}/vendor" "${TESTDIR}/clone/vendor"
  [ -f "${TESTDIR}/clone/vendor/f.txt" ]
  [ ! -e "${TESTDIR}/clone/vendor/vendor" ]
}

@test "the remove picker's selections cancel, dedup and reject bad input" {
  library
  run resolveCloneSelections "" 3;      [ "$output" = "CANCEL" ]
  run resolveCloneSelections "3,1,3" 3; [ "$output" = "3 1" ]
  run resolveCloneSelections 4 3;       [ "$output" = "INVALID" ]
  run resolveCloneSelections "1 x" 3;   [ "$output" = "INVALID" ]
}

@test "the remove picker falls back to the numbered list when curses can't run" {
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

  mkdir -p "${WORKTREE_ROOT}/alpha" "${WORKTREE_ROOT}/beta"
  run listCloneSlugs
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
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
