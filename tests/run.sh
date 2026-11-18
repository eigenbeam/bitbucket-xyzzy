#!/usr/bin/env bash
#
# Regression tests for bitbucket-ssh-migrate.sh. Each test builds throwaway
# repos in its own temp dir, runs the real script against them, and checks
# what happened to the repos and files.
#
# Usage: tests/run.sh [TEST_NAME ...]    (default: every test_* below)

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../bitbucket-ssh-migrate.sh"
# Built from parts so this file holds no old-host URL itself: --fix-files run
# over a tree containing this repo would otherwise rewrite the fixtures.
HOST=bitbucket.org
OLD=git@$HOST
NEW=git@ssh.$HOST

# Keep your own git config (signing, hooks, url rules) out of the fixtures.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# --- helpers ------------------------------------------------------------------

# new_repo DIR [REMOTE_URL]: an empty repo, with an origin if a URL is given.
new_repo() {
  mkdir -p "$1" && git -C "$1" init -q || return 1
  [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"
}

commit_all() {
  git -C "$1" add -A &&
    git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
}

origin_of() { git -C "$1" config remote.origin.url; }

# run_script ARGS...: run the script from $T/cwd, with logs in $T/logs.
run_script() { (cd "$T/cwd" && "$SCRIPT" --logdir "$T/logs" "$@"); }

fail() { printf '      %s\n' "$*"; FAILED=1; }

# --- tests --------------------------------------------------------------------

# perl -p opens its file arguments with 2-arg open, which runs "name |" as a
# command. The file must reach perl some other way.
test_fix_files_never_runs_a_file_name_as_a_command() {
  local name='z; touch PWNED; true |'
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf 'clone %s:team/y.git\n' "$OLD" > "$T/repos/r/$name"
  commit_all "$T/repos/r"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  [ ! -e "$T/cwd/PWNED" ] || fail "the file name ran as a shell command"
  [ "$(cat "$T/repos/r/$name")" = "clone $NEW:team/y.git" ] ||
    fail "file now holds: $(cat "$T/repos/r/$name")"
}

# 2-arg open also strips trailing spaces, so perl read nothing, exited 0, and
# the script wrote that nothing over the file.
test_fix_files_keeps_the_content_of_a_name_with_a_trailing_space() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf 'deploy: %s:team/x.git\nline two\nline three\n' "$OLD" > "$T/repos/r/notes.txt "
  commit_all "$T/repos/r"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  [ "$(cat "$T/repos/r/notes.txt ")" = "deploy: $NEW:team/x.git
line two
line three" ] || fail "file now holds $(wc -c < "$T/repos/r/notes.txt ") bytes: $(cat "$T/repos/r/notes.txt ")"
}

# git grep reads the index, which runs core.fsmonitor from the scanned repo's
# own config. A dry run must not run code from the repos it looks at.
test_dry_run_never_runs_a_scanned_repos_fsmonitor() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  echo hello > "$T/repos/r/a"
  commit_all "$T/repos/r"
  git -C "$T/repos/r" config core.fsmonitor "touch '$T/FSMONITOR_RAN'; false"
  run_script "$T/repos" >/dev/null 2>&1
  [ ! -e "$T/FSMONITOR_RAN" ] || fail "core.fsmonitor from the scanned repo ran"
}

# Piping the output to something that quits early (head, less + q) used to
# kill the run partway through --apply, with no RESULT and an incomplete log.
test_apply_finishes_when_the_output_reader_quits_early() {
  local i d n=0
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
    new_repo "$T/repos/r$i" "$OLD:team/r$i.git"
  done
  run_script --apply "$T/repos" 2>&1 | head -n 1 >/dev/null
  for d in "$T"/repos/r*; do
    [ "$(origin_of "$d")" = "$NEW:team/${d##*/}.git" ] && n=$((n + 1))
  done
  [ "$n" -eq 20 ] || fail "$n of 20 remotes rewritten"
  grep -q '^RESULT' "$T"/logs/*.log || fail "the log has no RESULT section"
}

# git grep C-quotes non-ASCII names ("r\303\251sum\303\251.md") by default; the
# quoted name doesn't exist, so the backup failed and the whole run aborted.
test_fix_files_handles_a_non_ascii_file_name() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf '%s:team/x.git\n' "$OLD" > "$T/repos/r/résumé.md"
  commit_all "$T/repos/r"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  [ "$(origin_of "$T/repos/r")" = "$NEW:team/r.git" ] || fail "remote not rewritten"
  [ "$(cat "$T/repos/r/résumé.md")" = "$NEW:team/x.git" ] ||
    fail "file now holds: $(cat "$T/repos/r/résumé.md")"
}

# With CDPATH exported, "cd .git" can land in another repo's .git.
test_an_exported_cdpath_does_not_change_which_repo_is_used() {
  new_repo "$T/decoy"
  new_repo "$T/repos/a" "$OLD:team/a.git"
  new_repo "$T/repos/b" "$OLD:team/b.git"
  (export CDPATH="$T/decoy"; run_script --apply "$T/repos" >/dev/null 2>&1)
  [ "$(origin_of "$T/repos/a")" = "$NEW:team/a.git" ] || fail "a: $(origin_of "$T/repos/a")"
  [ "$(origin_of "$T/repos/b")" = "$NEW:team/b.git" ] || fail "b: $(origin_of "$T/repos/b")"
}

# GIT_DIR in the environment overrides git -C, so every call would hit one repo.
test_an_exported_git_dir_does_not_change_which_repo_is_used() {
  new_repo "$T/decoy" "$OLD:team/decoy.git"
  new_repo "$T/repos/a" "$OLD:team/a.git"
  new_repo "$T/repos/b" "$OLD:team/b.git"
  (export GIT_DIR="$T/decoy/.git"; run_script --apply "$T/repos" >/dev/null 2>&1)
  [ "$(origin_of "$T/repos/a")" = "$NEW:team/a.git" ] || fail "a: $(origin_of "$T/repos/a")"
  [ "$(origin_of "$T/repos/b")" = "$NEW:team/b.git" ] || fail "b: $(origin_of "$T/repos/b")"
  [ "$(origin_of "$T/decoy")" = "$OLD:team/decoy.git" ] || fail "decoy (outside DIR) was changed"
}

# Where a repo is hosted says nothing about what its files point at: a
# GitHub-hosted VM repo can pull Puppet modules from Bitbucket, and those
# lines break at the cutover like any other. (Limiting --fix-files to repos
# with a Bitbucket remote was tried, and missed 3 of 14 real repos.)
test_fix_files_rewrites_a_repo_hosted_elsewhere() {
  new_repo "$T/repos/vm" "git@github.com:team/vm.git"
  printf "mod 'nfs', :git => '%s:team/puppet-nfs.git'\n" "$OLD" > "$T/repos/vm/Puppetfile"
  commit_all "$T/repos/vm"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  [ "$(cat "$T/repos/vm/Puppetfile")" = "mod 'nfs', :git => '$NEW:team/puppet-nfs.git'" ] ||
    fail "file now holds: $(cat "$T/repos/vm/Puppetfile")"
}

# This tool's own repo mentions the old host on purpose (README examples).
# --fix-files must leave its files alone, but its remote still migrates.
test_fix_files_leaves_the_running_scripts_own_repo_alone() {
  local tool="$T/repos/tool"
  new_repo "$tool" "$OLD:team/tool.git"
  cp "$SCRIPT" "$tool/bitbucket-ssh-migrate.sh"
  printf 'e.g. %s:team/repo.git\n' "$OLD" > "$tool/README.md"
  commit_all "$tool"
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf 'mod: %s:team/x.git\n' "$OLD" > "$T/repos/r/Puppetfile"
  commit_all "$T/repos/r"
  (cd "$T/cwd" && "$tool/bitbucket-ssh-migrate.sh" --apply --fix-files --logdir "$T/logs" "$T/repos" >/dev/null 2>&1)
  [ "$(cat "$tool/README.md")" = "e.g. $OLD:team/repo.git" ] || fail "tool README: $(cat "$tool/README.md")"
  [ "$(origin_of "$tool")" = "$NEW:team/tool.git" ] || fail "tool remote: $(origin_of "$tool")"
  [ "$(cat "$T/repos/r/Puppetfile")" = "mod: $NEW:team/x.git" ] ||
    fail "other repo's Puppetfile: $(cat "$T/repos/r/Puppetfile")"
}

# The dry run is the review step, so it must show every line --apply will
# change, not the first 10.
test_fix_files_dry_run_lists_every_line_it_would_change() {
  local i
  new_repo "$T/repos/r" "$OLD:team/r.git"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'dep%s: %s:team/x%s.git\n' "$i" "$OLD" "$i"
  done > "$T/repos/r/deps.txt"
  commit_all "$T/repos/r"
  n=$(run_script --fix-files "$T/repos" 2>&1 | grep -c -E '^  file +deps\.txt:[0-9]+ ')
  [ "$n" -eq 12 ] || fail "dry run showed $n of 12 lines"
}

# A copy of this script kept in a Bitbucket repo (a team tools repo) must
# survive --fix-files. Its own old-host strings, rewritten, would make the
# old-host alias check always pass and the TIP's insteadOf rules do nothing.
test_fix_files_leaves_a_copy_of_this_script_unchanged() {
  new_repo "$T/repos/tools" "$OLD:team/tools.git"
  cp "$SCRIPT" "$T/repos/tools/bitbucket-ssh-migrate.sh"
  commit_all "$T/repos/tools"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  cmp -s "$SCRIPT" "$T/repos/tools/bitbucket-ssh-migrate.sh" ||
    fail "the copy was changed: $(git -C "$T/repos/tools" diff --stat | tail -n 1)"
}

# The alias check builds its probe URL from parts (see the test above); it
# must still see a global insteadOf rule that sends the old host to the new.
test_alias_check_sees_a_git_insteadof_rule() {
  local out
  printf '[url "%s:"]\n\tinsteadOf = %s:\n' "$NEW" "$OLD" > "$T/gitconfig"
  new_repo "$T/repos/r"
  out=$(GIT_CONFIG_GLOBAL="$T/gitconfig" run_script "$T/repos" 2>&1)
  printf '%s\n' "$out" | grep -q 'old-host alias.*| OK .*git rule' ||
    fail "check row: $(printf '%s\n' "$out" | grep '| old-host alias')"
}

# --- undo ---------------------------------------------------------------------
# Restoring whole files from the backup (tar -xzf ... -C /) also throws away
# everything changed in them since --apply. --undo reverts only what --apply
# changed, and only where it's still the way --apply left it.

# The backup tarball the --apply run in this test wrote.
backup_file() { set -- "$T"/logs/*-backup.tar.gz; printf '%s' "$1"; }

test_undo_reverts_a_remote_url() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  run_script --undo "$(backup_file)" --apply >/dev/null 2>&1
  [ "$(origin_of "$T/repos/r")" = "$OLD:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
}

test_undo_dry_run_changes_nothing() {
  local out
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  out=$(run_script --undo "$(backup_file)" 2>&1)
  [ "$(origin_of "$T/repos/r")" = "$NEW:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
  printf '%s\n' "$out" | grep -q -E '\] +undo +url ' || fail "the dry run doesn't list the url"
}

# Git writes to .git/config all the time (new branches, remotes, settings).
test_undo_keeps_config_changes_made_after_apply() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  git -C "$T/repos/r" config branch.main.remote origin
  git -C "$T/repos/r" remote add fork "git@github.com:me/r.git"
  run_script --undo "$(backup_file)" --apply >/dev/null 2>&1
  [ "$(origin_of "$T/repos/r")" = "$OLD:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
  [ "$(git -C "$T/repos/r" config branch.main.remote)" = origin ] || fail "branch.main.remote is gone"
  [ "$(git -C "$T/repos/r" config remote.fork.url)" = "git@github.com:me/r.git" ] ||
    fail "remote.fork.url is gone"
}

test_undo_leaves_a_url_changed_since_apply_alone() {
  local out
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  git -C "$T/repos/r" remote set-url origin "git@github.com:team/r.git"
  out=$(run_script --undo "$(backup_file)" --apply 2>&1)
  [ "$(origin_of "$T/repos/r")" = "git@github.com:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
  printf '%s\n' "$out" | grep -q 'changed since' || fail "the output doesn't say why it was skipped"
}

test_undo_reverts_every_value_of_a_multi_valued_key() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  git -C "$T/repos/r" remote set-url --add --push origin "$OLD:team/a.git"
  git -C "$T/repos/r" remote set-url --add --push origin "$OLD:team/b.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  run_script --undo "$(backup_file)" --apply >/dev/null 2>&1
  [ "$(git -C "$T/repos/r" config --get-all remote.origin.pushurl | tr '\n' ' ')" = "$OLD:team/a.git $OLD:team/b.git " ] ||
    fail "pushurl: $(git -C "$T/repos/r" config --get-all remote.origin.pushurl | tr '\n' ' ')"
}

# A submodule's config lives in the parent's .git/modules/NAME, not in a .git
# directory of its own.
test_undo_reverts_a_url_in_a_separate_git_dir() {
  new_repo "$T/repos/super"
  mkdir -p "$T/repos/super/.git/modules"
  git init -q --separate-git-dir "$T/repos/super/.git/modules/sub" "$T/repos/super/sub"
  git -C "$T/repos/super/sub" remote add origin "$OLD:team/sub.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  [ "$(origin_of "$T/repos/super/sub")" = "$NEW:team/sub.git" ] || fail "--apply didn't rewrite it"
  run_script --undo "$(backup_file)" --apply >/dev/null 2>&1
  [ "$(origin_of "$T/repos/super/sub")" = "$OLD:team/sub.git" ] ||
    fail "origin: $(origin_of "$T/repos/super/sub")"
}

test_undo_reverts_a_rewritten_file() {
  local out
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf "mod 'nfs', :git => '%s:team/nfs.git'\nmod 'stdlib'\n" "$OLD" > "$T/repos/r/Puppetfile"
  commit_all "$T/repos/r"
  cp "$T/repos/r/Puppetfile" "$T/original"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  out=$(run_script --undo "$(backup_file)" --apply 2>&1)
  cmp -s "$T/original" "$T/repos/r/Puppetfile" || fail "file now holds: $(cat "$T/repos/r/Puppetfile")"
  printf '%s\n' "$out" | grep -q -E '\] +ok +file +[^ ]*/repos/r +Puppetfile' ||
    fail "change line: $(printf '%s\n' "$out" | grep -E '\] +[a-zA-Z]+ +file ')"
  printf '%s\n' "$out" | grep -q -E 'Review +git -C [^ ]*/repos/r diff' ||
    fail "review line: $(printf '%s\n' "$out" | grep 'Review')"
}

test_undo_keeps_a_file_edited_after_apply() {
  local out
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf "mod 'nfs', :git => '%s:team/nfs.git'\n" "$OLD" > "$T/repos/r/Puppetfile"
  commit_all "$T/repos/r"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  printf "mod 'added-later'\n" >> "$T/repos/r/Puppetfile"
  cp "$T/repos/r/Puppetfile" "$T/edited"
  out=$(run_script --undo "$(backup_file)" --apply 2>&1)
  cmp -s "$T/edited" "$T/repos/r/Puppetfile" || fail "file now holds: $(cat "$T/repos/r/Puppetfile")"
  printf '%s\n' "$out" | grep -q 'changed since' || fail "the output doesn't say why it was skipped"
}

test_undo_handles_a_non_ascii_file_name() {
  new_repo "$T/repos/r" "$OLD:team/r.git"
  printf '%s:team/x.git\n' "$OLD" > "$T/repos/r/résumé.md"
  commit_all "$T/repos/r"
  run_script --apply --fix-files "$T/repos" >/dev/null 2>&1
  run_script --undo "$(backup_file)" --apply >/dev/null 2>&1
  [ "$(cat "$T/repos/r/résumé.md")" = "$OLD:team/x.git" ] ||
    fail "file now holds: $(cat "$T/repos/r/résumé.md")"
}

# A relative backup path must not be looked up through CDPATH.
test_undo_finds_a_relative_backup_despite_an_exported_cdpath() {
  local b
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  b=$(backup_file)
  mkdir -p "$T/decoy/logs"
  (cd "$T" &&
    CDPATH="$T/decoy" "$SCRIPT" --undo "logs/${b##*/}" --apply --logdir "$T/logs" >/dev/null 2>&1)
  [ "$(origin_of "$T/repos/r")" = "$OLD:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
}

# "--undo BACKUP ~/projects/one-repo" reads like a narrower undo; it isn't one.
test_undo_refuses_a_dir_argument() {
  local rc
  new_repo "$T/repos/r" "$OLD:team/r.git"
  run_script --apply "$T/repos" >/dev/null 2>&1
  run_script --undo "$(backup_file)" --apply "$T/repos" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "exit code $rc, not 2"
  [ "$(origin_of "$T/repos/r")" = "$NEW:team/r.git" ] || fail "origin: $(origin_of "$T/repos/r")"
}

# --- runner -------------------------------------------------------------------

if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  # shellcheck disable=SC2207  # function names have no spaces
  TESTS=($(declare -F | awk '$3 ~ /^test_/ { print $3 }'))
fi

passed=0; failed=0
for t in "${TESTS[@]}"; do
  if ! declare -F "$t" >/dev/null; then
    printf 'FAIL  %s (no such test)\n' "$t"; failed=$((failed + 1))
    continue
  fi
  if (
    T=$(mktemp -d "${TMPDIR:-/tmp}/bbssh-test.XXXXXX") || exit 1
    trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/cwd" "$T/logs" "$T/repos"
    FAILED=0
    "$t"
    exit "$FAILED"
  ); then
    printf 'PASS  %s\n' "$t"; passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$t"; failed=$((failed + 1))
  fi
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
