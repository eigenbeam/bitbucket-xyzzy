#!/usr/bin/env bash
#
# bitbucket-ssh-migrate.sh
# SPDX-License-Identifier: MIT (see LICENSE). No warranty; YMMV.
#
# Finds git repos that reach Bitbucket Cloud over SSH using the old hostname
# (bitbucket.org) and switches them to the new one (ssh.bitbucket.org).
#
# Background
#   Bitbucket Cloud is moving Git-over-SSH from bitbucket.org to
#   ssh.bitbucket.org. Atlassian's schedule (check the announcement for
#   changes):
#     2026-11-12  SSH to bitbucket.org fails during scheduled "brownouts"
#                 (15 minutes at first, growing to 3 hours)
#     2026-12-10  SSH to bitbucket.org is refused for good
#   HTTPS remotes are not affected. Your SSH keys keep working, and
#   ssh.bitbucket.org presents the same host keys as bitbucket.org.
#   https://community.atlassian.com/forums/Bitbucket-articles/Upcoming-change-to-Bitbucket-Cloud-SSH-access-move-from/ba-p/3234032
#
# Before you start
#   Connect to the new host once so ssh records its host key:
#       ssh -T git@ssh.bitbucket.org
#   Accept the key only if its fingerprint matches
#   https://bitbucket.org/site/ssh. Until you do, git in IDEs, GUI clients
#   and scripts fails at the host-key prompt.
#
# Modes
#   (default)    Dry run. Scans, shows every change it would make, and
#                changes nothing.
#   --apply      Makes the changes: rewrites remote.*.url, remote.*.pushurl
#                and submodule.*.url in each repo's local git config.
#   --fix-files  Adds old-host SSH URLs inside files tracked by git
#                (Puppetfile, .gitmodules, CI config, deploy scripts...) to
#                the plan. Never commits: review with `git diff`.
#
#   With --apply, every file about to change is first copied into a backup
#   tarball. If the backup fails, nothing is changed. Every run, dry or not,
#   writes a log. Both go in --logdir DIR (default: the current directory).
#   Undo an --apply run with:  tar -xzf <backup>.tar.gz -C /
#
#   It never edits ~/.ssh/* or your global git config. It reports what to
#   change there.
#
# Not covered
#   CI servers (Jenkins, Bamboo, Bitbucket Pipelines), deploy targets,
#   servers and VMs with their own clones, and your other machines.
#
# Requires bash 3.2+ (stock macOS bash is fine), git, find, sed, grep, tar,
# and perl for --fix-files. Works on macOS and Linux.

PROG=${0##*/}
VERSION=1.1.0
ORIG_ARGS="$*"

DEFAULT_DEPTH=7
DEPTH=$DEFAULT_DEPTH
APPLY=0
FIX_FILES=0
LOG_DIR=.
LOG_DIR_SET=0
ROOTS=()

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

usage() {
  cat <<EOF
Usage: $PROG [--apply] [--fix-files] [--depth N] [--logdir DIR] [DIR ...]

Find git repos that use Bitbucket Cloud's old SSH hostname (bitbucket.org)
and switch them to ssh.bitbucket.org.

By default this is a dry run: it shows every change it would make and
changes nothing.

  --apply       Make the changes. Every file that will change is backed up
                to a tarball first; if the backup fails, nothing is changed.
  --fix-files   Also rewrite old-host SSH URLs in files tracked by git
                (Puppetfile, .gitmodules, CI config, scripts). Never commits.
  --depth N     How many directory levels to search below each DIR
                (default: $DEFAULT_DEPTH).
  --logdir DIR  Where the log and backup go (default: the current directory).
  -h, --help    Show this help.

DIR defaults to your home directory. On macOS, scanning all of it can
trigger "access your Documents/Desktop folder" prompts; pass the
directories that hold your repos to avoid that.

Before you start, if you haven't already, connect to the new host once so
ssh records its host key, and accept it only if the fingerprint matches
https://bitbucket.org/site/ssh:
  ssh -T git@ssh.bitbucket.org

Examples:
  $PROG ~/projects                       # dry run
  $PROG --apply ~/projects               # update remote URLs
  $PROG --apply --fix-files ~/projects   # ...and tracked files too

Undo an --apply run:  tar -xzf <backup>.tar.gz -C /
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --apply)     APPLY=1 ;;
    --fix-files) FIX_FILES=1 ;;
    --depth)     [ $# -ge 2 ] || die "--depth needs a number"; DEPTH=$2; shift ;;
    --depth=*)   DEPTH=${1#*=} ;;
    --logdir)    [ $# -ge 2 ] || die "--logdir needs a directory"; LOG_DIR=$2; LOG_DIR_SET=1; shift ;;
    --logdir=*)  LOG_DIR=${1#*=}; LOG_DIR_SET=1 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; while [ $# -gt 0 ]; do ROOTS+=("$1"); shift; done; break ;;
    -*)          die "unknown option: $1 (see --help)" ;;
    *)           ROOTS+=("$1") ;;
  esac
  shift
done

case $DEPTH in ''|*[!0-9]*) die "--depth must be a number" ;; esac
[ ${#ROOTS[@]} -gt 0 ] || ROOTS=("$HOME")

for tool in git find sed grep tar; do
  command -v "$tool" >/dev/null 2>&1 || die "needs $tool on PATH"
done
if [ "$FIX_FILES" -eq 1 ]; then
  command -v perl >/dev/null 2>&1 || die "--fix-files needs perl on PATH"
fi

# The log and backup can contain repo URLs and file contents: keep them private.
umask 077
[ -n "$LOG_DIR" ] || die "--logdir needs a directory"
mkdir -p "$LOG_DIR" || die "can't create $LOG_DIR"
LOG_DIR=$(cd "$LOG_DIR" && pwd) || die "can't use $LOG_DIR"
[ -w "$LOG_DIR" ] || die "can't write to $LOG_DIR (use --logdir)"
STAMP=bitbucket-ssh-migrate-$(date +%Y%m%d-%H%M%S)
[ -e "$LOG_DIR/$STAMP.log" ] && STAMP="$STAMP-$$"
LOG="$LOG_DIR/$STAMP.log"
BACKUP="$LOG_DIR/$STAMP-backup.tar.gz"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bbssh.XXXXXX") || die "can't create a temp dir"
trap 'rm -rf "$WORK"' EXIT
PLAN="$WORK/plan"   # one tab-separated change per line: KIND, repo, path, key
: > "$PLAN"

# --- URL patterns -------------------------------------------------------------

# Rewrite one git config URL. Handles scp-like URLs (user@host:path) and
# ssh:// or git+ssh:// URLs. Everything else comes back unchanged: HTTPS URLs,
# and URLs already on ssh.bitbucket.org or altssh.bitbucket.org.
rewrite_url() {
  printf '%s\n' "$1" | sed -E \
    -e 's#^([A-Za-z0-9._-]+@)?bitbucket\.org:#\1ssh.bitbucket.org:#' \
    -e 's#^((git\+)?ssh(\+git)?://([^@/]+@)?)bitbucket\.org([:/])#\1ssh.bitbucket.org\5#'
}

# Old-host SSH URLs inside files: the git@ form, or ssh:// and git+ssh:// with
# any user. The leading character class keeps https://git@... and
# ssh.bitbucket.org from matching. GREP_RE finds the lines, URL_RE pulls the
# URLs out of them for the report, and PERL_FIX rewrites them (perl leaves the
# rest of the file byte-for-byte alone, where BSD sed would add a missing
# final newline).
GREP_RE='(^|[^/A-Za-z0-9._-])git@bitbucket\.org[:/]|ssh://([^@/[:space:]]+@)?bitbucket\.org[:/]'
URL_TAIL="[^][:space:]\"'<>,;()]*"
URL_RE="(^|[^/A-Za-z0-9._-])git@bitbucket\\.org[:/]$URL_TAIL|(git\\+)?ssh://([^@/[:space:]]+@)?bitbucket\\.org[:/]$URL_TAIL"
# shellcheck disable=SC2016  # $1/$2 are perl captures, not shell variables
PERL_FIX='s{(?<![/A-Za-z0-9._-])git\@bitbucket\.org([:/])}{git\@ssh.bitbucket.org$1}g; s{(ssh://(?:[^\@/\s]+\@)?)bitbucket\.org([:/])}{$1ssh.bitbucket.org$2}g'

# --- output helpers -----------------------------------------------------------

SEPARATOR=$(printf '%80s' '' | tr ' ' '-')

separator() { printf '%s\n' "$SEPARATOR"; }
say()       { printf '%s\n' "$*"; }
kv()        { printf '  %-16s  %s\n' "$1" "$2"; }   # aligned "key  value" line
count_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c ''; fi; }
trim()      { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "$s"; }
dashes()    { printf "%$1s" '' | tr ' ' '-'; }

# Shorten to width $2, marking the cut with "...".
fit() {
  if [ ${#1} -le "$2" ]; then printf '%s' "$1"; else printf '%s...' "${1:0:$(($2 - 3))}"; fi
}

# A path for display, with $HOME shown as ~.
tilde() {
  case $1 in
    "$HOME")   printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

# A path as you'd type it in a shell: ~/... when that's safe, else quoted.
shell_path() {
  local q
  q=$(printf '%q' "$1")
  if [ "$q" = "$1" ]; then tilde "$1"; else printf '%s' "$q"; fi
}

# The old-host URLs in one line of text.
urls_in() { printf '%s\n' "$1" | grep -o -E "$URL_RE" | sed -E 's#^[^gs]##'; }

# --- checks on this machine's SSH and git setup (report only) ----------------

CHECK_ROWS=""      # name TAB status TAB detail, one per line
FIX_TEXT=""        # numbered fixes printed under the table
FIX_N=0
FIX_REF=""
HOSTKEY_STATE=unknown   # ok | missing | unknown

add_check() { CHECK_ROWS="$CHECK_ROWS$1"$'\t'"$2"$'\t'"$3"$'\n'; }

# add_fix FIRST_LINE [MORE_LINES...]: record a fix; sets FIX_REF ("FIX n").
add_fix() {
  local line
  FIX_N=$((FIX_N + 1))
  FIX_REF="FIX $FIX_N"
  FIX_TEXT="$FIX_TEXT$(printf '  %-7s%s' "$FIX_REF" "$1")"$'\n'
  shift
  for line in "$@"; do FIX_TEXT="$FIX_TEXT         $line"$'\n'; done
}

check_known_hosts() {
  local name="host key (known_hosts)"
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    add_check "$name" "??" "ssh-keygen not found; can't tell"
    return
  fi
  if ssh-keygen -F ssh.bitbucket.org >/dev/null 2>&1; then
    HOSTKEY_STATE=ok
    add_check "$name" "OK" "ssh.bitbucket.org is known"
  else
    HOSTKEY_STATE=missing
    add_fix "Run once in a terminal:  ssh -T git@ssh.bitbucket.org" \
            "Accept the key only if its fingerprint matches" \
            "https://bitbucket.org/site/ssh. Until you do, git in IDEs, GUI" \
            "clients and scripts fails at the host-key prompt."
    add_check "$name" "$FIX_REF" "ssh.bitbucket.org not trusted yet"
  fi
}

check_ssh_host_settings() {
  local name="ssh config (Host match)"
  local keys='^(user|port|identityfile|identitiesonly|identityagent|certificatefile|proxycommand|proxyjump) '
  local old new l lines=()
  if ! command -v ssh >/dev/null 2>&1; then
    add_check "$name" "??" "ssh not found"
    return
  fi
  # Settings ssh resolves for each host name, whatever Host/Match/Include
  # rules produced them. ssh -G prints config only; it never connects.
  old=$(ssh -G bitbucket.org 2>/dev/null | grep -E "$keys" | sort)
  new=$(ssh -G ssh.bitbucket.org 2>/dev/null | grep -E "$keys" | sort)
  if [ -z "$old" ]; then
    add_check "$name" "??" "ssh -G failed; check by hand"
  elif [ "$old" != "$new" ]; then
    while IFS= read -r l; do
      lines+=("    $l")
    done < <(printf '%s\n' "$old" | grep -Fxv -f <(printf '%s\n' "$new"))
    add_fix "Give ssh.bitbucket.org what bitbucket.org gets in ~/.ssh/config:" \
            "${lines[@]}" \
            "e.g. change the Host line to:  Host bitbucket.org ssh.bitbucket.org"
    add_check "$name" "$FIX_REF" "new host misses settings"
  else
    add_check "$name" "OK" "same settings as bitbucket.org"
  fi
}

check_ssh_aliases() {
  local name="ssh config (aliases)" f l n=0 lines=()
  # Aliases (Host work-bb / HostName bitbucket.org). Remotes that use an alias
  # don't mention bitbucket.org, so only the alias needs changing.
  for f in "$HOME/.ssh/config" "$HOME"/.ssh/config.d/*; do
    [ -f "$f" ] || continue
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      lines+=("    $(tilde "$f") line ${l%%:*}")
      n=$((n + 1))
    done < <(grep -n -i -E '^[[:space:]]*hostname[[:space:]=]+bitbucket\.org([[:space:]]|$)' "$f" 2>/dev/null)
  done
  if [ "$n" -eq 0 ]; then
    add_check "$name" "OK" "none use HostName bitbucket.org"
  else
    add_fix "Change HostName bitbucket.org to HostName ssh.bitbucket.org at:" \
            "${lines[@]}" \
            "Remotes that use those aliases then work unchanged."
    add_check "$name" "$FIX_REF" "$n alias(es) on the old host"
  fi
}

check_git_url_rules() {
  local name="git url.insteadOf rules" scope out line origin rest key base newbase n=0 lines=()
  for scope in --global --system; do
    out=$(git config "$scope" --includes --show-origin --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null) || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      origin=${line%%$'\t'*}
      rest=${line#*$'\t'}
      key=${rest%% *}
      base=${key#url.}
      base=${base%.*}
      newbase=$(rewrite_url "$base")
      [ "$newbase" != "$base" ] || continue
      n=$((n + 1))
      lines+=("git config --file $(shell_path "${origin#file:}") --rename-section 'url.$base' 'url.$newbase'")
    done <<< "$out"
  done
  if [ "$n" -eq 0 ]; then
    add_check "$name" "OK" "none point at the old host"
  else
    add_fix "Point these git url rules at the new host:" "${lines[@]}"
    add_check "$name" "$FIX_REF" "$n rule(s) on the old host"
  fi
}

# Table columns: check name, status, detail. 2 + 26 + 3 + 6 + 3 + 36 + 2 = 78
# wide, indented 2, so 80 in all.
W1=26; W2=6; W3=36
table_rule() { printf '  +-%s-+-%s-+-%s-+\n' "$(dashes $W1)" "$(dashes $W2)" "$(dashes $W3)"; }
table_row()  { printf '  | %-*s | %-*s | %-*s |\n' "$W1" "$(fit "$1" $W1)" "$W2" "$(fit "$2" $W2)" "$W3" "$(fit "$3" $W3)"; }

print_checks() {
  local name status detail
  table_rule
  table_row "Check" "Status" "Detail"
  table_rule
  while IFS=$'\t' read -r name status detail; do
    [ -n "$name" ] && table_row "$name" "$status" "$detail"
  done <<< "$CHECK_ROWS"
  table_rule
  if [ "$FIX_N" -gt 0 ]; then
    say ""
    printf '%s' "$FIX_TEXT"
  fi
}

# --- scan ---------------------------------------------------------------------

N_REPOS=0; N_SKIPPED=0; N_BLOCKS=0
N_URL_REPOS=0; N_URLS=0
N_FILE_REPOS=0; N_FILES=0; N_FILE_LINES=0
N_ALTSSH=0
SEEN_WT=$'\n'    # work trees already scanned
SEEN_CFG=$'\n'   # git config files already scanned (worktrees share one)
MAX_SHOW=10      # file lines to show per repo

# repo_block DIR ITEMS [EXTRA]: print one repo's findings, aligned.
# ITEMS has one "kind TAB where TAB value" per line.
repo_block() {
  local dir=$1 items=$2 extra=$3 kind where value w=0
  while IFS=$'\t' read -r kind where value; do
    [ ${#where} -gt "$w" ] && [ ${#where} -le 32 ] && w=${#where}
  done <<< "$items"
  separator
  say "$(tilde "$dir")"
  while IFS=$'\t' read -r kind where value; do
    [ -n "$kind" ] || continue
    if [ -n "$value" ]; then
      printf '  %-4s  %-*s  %s\n' "$kind" "$w" "$where" "$value"
    else
      printf '  %-4s  %s\n' "$kind" "$where"
    fi
  done <<< "$items"
  [ -n "$extra" ] && say "$extra"
  N_BLOCKS=$((N_BLOCKS + 1))
}

scan_repo() {
  local dir g gitdir cfgfile cfg line key val new items="" hits files nlines nfiles
  local rel rest ln text u found shown=0 err extra="" has_url=0 has_alt=0

  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  case $SEEN_WT in *$'\n'"$dir"$'\n'*) return 0 ;; esac
  SEEN_WT="$SEEN_WT$dir"$'\n'

  if ! g=$(git -C "$dir" rev-parse --git-common-dir 2>"$WORK/err") || [ -z "$g" ]; then
    err=$(head -n 1 "$WORK/err" | sed "s#$HOME#~#g")
    N_SKIPPED=$((N_SKIPPED + 1))
    repo_block "$dir" "SKIP"$'\t'"${err:-not a git repository}"$'\t'
    return 0
  fi
  gitdir=$(cd "$dir" && cd "$g" && pwd -P) || return 0
  cfgfile="$gitdir/config"
  N_REPOS=$((N_REPOS + 1))

  case $SEEN_CFG in
    *$'\n'"$cfgfile"$'\n'*) ;;
    *)
      SEEN_CFG="$SEEN_CFG$cfgfile"$'\n'
      cfg=$(git -C "$dir" config --local --get-regexp '^(remote\..+\.(url|pushurl)|submodule\..+\.url)$' 2>/dev/null)
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=${line%% *}
        val=${line#* }
        new=$(rewrite_url "$val")
        if [ "$new" != "$val" ]; then
          items="${items}url"$'\t'"$key"$'\t'"$val"$'\n'
          N_URLS=$((N_URLS + 1))
          has_url=1
        elif [[ $val == *altssh.bitbucket.org* ]]; then
          items="${items}keep"$'\t'"$key"$'\t'"$val"$'\n'
          has_alt=1
        fi
      done <<< "$cfg"
      ;;
  esac

  hits=$(git -C "$dir" grep -n -I -E -e "$GREP_RE" 2>/dev/null)
  if [ -n "$hits" ]; then
    files=$(git -C "$dir" grep -l -I -E -e "$GREP_RE" 2>/dev/null)
    nlines=$(count_lines "$hits")
    nfiles=$(count_lines "$files")
    N_FILE_REPOS=$((N_FILE_REPOS + 1))
    N_FILES=$((N_FILES + nfiles))
    N_FILE_LINES=$((N_FILE_LINES + nlines))
    while IFS= read -r line; do
      [ "$shown" -lt "$MAX_SHOW" ] || break
      rel=${line%%:*}
      rest=${line#*:}
      ln=${rest%%:*}
      text=${rest#*:}
      found=0
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        items="${items}file"$'\t'"$rel:$ln"$'\t'"$u"$'\n'
        found=1
      done < <(urls_in "$text")
      [ "$found" -eq 1 ] || items="${items}file"$'\t'"$rel:$ln"$'\t'"$(fit "$(trim "$text")" 60)"$'\n'
      shown=$((shown + 1))
    done <<< "$hits"
    if [ "$nlines" -gt "$MAX_SHOW" ]; then
      extra="  ...   $((nlines - MAX_SHOW)) more line(s): git -C $(shell_path "$dir") grep -n bitbucket.org"
    fi
  fi

  [ -n "$items" ] || return 0
  if [ "$has_url" -eq 1 ]; then
    N_URL_REPOS=$((N_URL_REPOS + 1))
    printf '%s' "$items" | awk -F'\t' '$1 == "url" { print $2 }' | sort -u |
      while IFS= read -r key; do
        printf 'URL\t%s\t%s\t%s\n' "$dir" "$cfgfile" "$key"
      done >> "$PLAN"
  fi
  if [ -n "$hits" ] && [ "$FIX_FILES" -eq 1 ]; then
    while IFS= read -r rel; do
      printf 'FILE\t%s\t%s\t%s\n' "$dir" "$dir/$rel" "$rel" >> "$PLAN"
    done <<< "$files"
  fi
  [ "$has_alt" -eq 1 ] && N_ALTSSH=$((N_ALTSSH + 1))
  repo_block "$dir" "$items" "$extra"
}

scan_root() {
  local abs top g
  if ! abs=$(cd "$1" 2>/dev/null && pwd); then
    N_SKIPPED=$((N_SKIPPED + 1))
    repo_block "$1" "SKIP"$'\t'"not a directory"$'\t'
    return 0
  fi
  # DIR may itself be inside a repo.
  top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null) && scan_repo "$top"
  while IFS= read -r g; do
    scan_repo "$g"
  done < <(find "$abs" -maxdepth "$DEPTH" \
             \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -name node_modules \
                -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup \
                -o -name .venv -o -name .tox \) -prune \
             -o -name .git -print -prune 2>/dev/null | sed 's#/\.git$##' | LC_ALL=C sort)
}

# --- apply --------------------------------------------------------------------

N_URL_DONE=0; N_FILE_DONE=0; N_SKIP=0; N_FAIL=0
EDITED_REPOS=$'\n'
ACT_STATUS=""; ACT_NOTE=""
TOTAL=0; RW=0

# apply_url REPO KEY: rewrite every value of KEY. Sets ACT_STATUS, ACT_NOTE.
apply_url() {
  local repo=$1 key=$2 vals count changed=0 v expected now
  vals=$(git -C "$repo" config --local --get-all "$key" 2>/dev/null)
  count=$(count_lines "$vals")
  expected=$(while IFS= read -r v; do rewrite_url "$v"; done <<< "$vals")
  while IFS= read -r v; do
    [ "$(rewrite_url "$v")" = "$v" ] || changed=$((changed + 1))
  done <<< "$vals"
  ACT_NOTE=""
  if [ "$count" -eq 0 ]; then
    ACT_STATUS=skip; ACT_NOTE="no longer set"; N_SKIP=$((N_SKIP + 1)); return
  fi
  if [ "$changed" -eq 0 ]; then
    ACT_STATUS=skip; ACT_NOTE="already updated"; N_SKIP=$((N_SKIP + 1)); return
  fi
  if [ "$count" -eq 1 ]; then
    git -C "$repo" config --local "$key" "$expected"
  else
    # Several values (e.g. push to more than one URL): rewrite all, keep order.
    git -C "$repo" config --local --unset-all "$key" &&
      while IFS= read -r v; do
        git -C "$repo" config --local --add "$key" "$v" || break
      done <<< "$expected"
    ACT_NOTE="$changed of $count values"
  fi
  now=$(git -C "$repo" config --local --get-all "$key" 2>/dev/null)
  if [ "$now" = "$expected" ]; then
    ACT_STATUS=ok
    N_URL_DONE=$((N_URL_DONE + changed))
  else
    ACT_STATUS=FAIL
    ACT_NOTE="now: $(printf '%s' "$now" | tr '\n' ' ')"
    N_FAIL=$((N_FAIL + 1))
  fi
}

# apply_file REPO PATH: rewrite old-host URLs in one file. Sets ACT_STATUS, ACT_NOTE.
apply_file() {
  local repo=$1 abs=$2 before after
  ACT_NOTE=""
  if [ ! -f "$abs" ]; then
    ACT_STATUS=skip; ACT_NOTE="file is gone"; N_SKIP=$((N_SKIP + 1)); return
  fi
  before=$(grep -c -E "$GREP_RE" "$abs" 2>/dev/null); before=${before:-0}
  if [ "$before" -eq 0 ]; then
    ACT_STATUS=skip; ACT_NOTE="already updated"; N_SKIP=$((N_SKIP + 1)); return
  fi
  # Write through the original file so its permissions and inode stay put.
  if perl -pe "$PERL_FIX" "$abs" > "$WORK/fix.tmp" && cat "$WORK/fix.tmp" > "$abs"; then
    after=$(grep -c -E "$GREP_RE" "$abs" 2>/dev/null); after=${after:-0}
    case $EDITED_REPOS in *$'\n'"$repo"$'\n'*) ;; *) EDITED_REPOS="$EDITED_REPOS$repo"$'\n' ;; esac
    if [ "$after" -eq 0 ]; then
      ACT_STATUS=ok; ACT_NOTE="$before line(s)"
      N_FILE_DONE=$((N_FILE_DONE + 1))
    else
      ACT_STATUS=FAIL; ACT_NOTE="$after of $before line(s) left; edit by hand"
      N_FAIL=$((N_FAIL + 1))
    fi
  else
    ACT_STATUS=FAIL; ACT_NOTE="couldn't write the file"
    N_FAIL=$((N_FAIL + 1))
  fi
}

# action_line STEP KIND REPO WHAT: one aligned line per change made.
action_line() {
  printf '  [%*d/%d]  %-4s  %-4s  %-*s  %s%s\n' "${#TOTAL}" "$1" "$TOTAL" \
    "$ACT_STATUS" "$2" "$RW" "$(tilde "$3")" "$4" "${ACT_NOTE:+  ($ACT_NOTE)}"
}

backup_and_apply() {
  local n_backup n_in i=0 kind repo path key r
  cut -f3 "$PLAN" | sort -u | sed 's#^/##' > "$WORK/backup.list"
  n_backup=$(grep -c '' "$WORK/backup.list")

  separator
  say "BACKUP"
  if ! tar -czf "$BACKUP" -C / -T "$WORK/backup.list" 2>"$WORK/tar.err"; then
    kv "FAILED" "$(head -n 1 "$WORK/tar.err")"
    kv "Changes" "none; nothing was changed"
    return 1
  fi
  n_in=$(tar -tzf "$BACKUP" 2>/dev/null | grep -c '')
  if [ "$n_in" -ne "$n_backup" ]; then
    kv "FAILED" "backup holds $n_in of $n_backup files"
    kv "Changes" "none; nothing was changed"
    return 1
  fi
  kv "Saved" "$(tilde "$BACKUP")"
  kv "Contents" "$n_in file(s), verified"

  separator
  say "CHANGES"
  TOTAL=$(grep -c '' "$PLAN")
  while IFS=$'\t' read -r kind repo path key; do
    r=$(tilde "$repo")
    [ ${#r} -gt "$RW" ] && RW=${#r}
  done < "$PLAN"
  while IFS=$'\t' read -r kind repo path key <&3; do
    i=$((i + 1))
    case $kind in
      URL)  apply_url "$repo" "$key";   action_line "$i" url  "$repo" "$key" ;;
      FILE) apply_file "$repo" "$path"; action_line "$i" file "$repo" "$key" ;;
    esac
  done 3< "$PLAN"
}

# --- main ---------------------------------------------------------------------

rerun_command() {
  local cmd r
  cmd="$(shell_path "$0") --apply"
  { [ "$FIX_FILES" -eq 1 ] || [ "$1" = fix ]; } && cmd="$cmd --fix-files"
  [ "$DEPTH" != "$DEFAULT_DEPTH" ] && cmd="$cmd --depth $DEPTH"
  [ "$LOG_DIR_SET" -eq 1 ] && cmd="$cmd --logdir $(shell_path "$LOG_DIR")"
  for r in "${ROOTS[@]}"; do cmd="$cmd $(shell_path "$r")"; done
  printf '%s' "$cmd"
}

main() {
  local r roots="" n_planned n_backup step=1 repo first=1

  separator
  say "RUN"
  kv "Tool" "bitbucket-ssh-migrate $VERSION"
  kv "Started" "$(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname 2>/dev/null)"
  kv "Command" "$(tilde "$0") $(printf '%s' "$ORIG_ARGS" | sed "s#$HOME#~#g")"
  if [ "$APPLY" -eq 1 ]; then
    kv "Mode" "APPLY: changes will be made, after a backup"
  else
    kv "Mode" "DRY RUN: nothing will be changed"
  fi
  kv "Log" "$(tilde "$LOG")"
  if r=$(git -C "$LOG_DIR" rev-parse --show-toplevel 2>/dev/null); then
    kv "Note" "the log dir is inside the repo $(tilde "$r");"
    kv "" "don't commit the log or backup (or pass --logdir)"
  fi

  separator
  say "SSH & GIT SETUP (checked only, never changed)"
  check_known_hosts
  check_ssh_host_settings
  check_ssh_aliases
  check_git_url_rules
  print_checks

  for r in "${ROOTS[@]}"; do roots="$roots${roots:+, }$(tilde "$r")"; done
  separator
  say "REPOSITORIES"
  kv "Searched" "$roots (depth $DEPTH)"
  kv "url" "URL in the repo's git config; changed by --apply"
  kv "file" "URL in a tracked file; changed by --apply --fix-files"
  kv "keep" "altssh.bitbucket.org (port 443); left alone"
  kv "" "Only the host changes: bitbucket.org -> ssh.bitbucket.org"
  for r in "${ROOTS[@]}"; do scan_root "$r"; done
  if [ "$N_BLOCKS" -eq 0 ]; then
    separator
    say "  No repositories use the old SSH host."
  fi

  n_planned=$(grep -c '' "$PLAN")
  n_backup=$(cut -f3 "$PLAN" | sort -u | grep -c '')

  separator
  say "PLAN"
  if [ "$N_SKIPPED" -gt 0 ]; then
    kv "Repos scanned" "$N_REPOS ($N_SKIPPED skipped, marked SKIP above)"
  else
    kv "Repos scanned" "$N_REPOS"
  fi
  kv "URLs to update" "$N_URLS in $N_URL_REPOS repo(s)"
  if [ "$FIX_FILES" -eq 1 ]; then
    kv "Files to rewrite" "$N_FILES file(s), $N_FILE_LINES line(s), in $N_FILE_REPOS repo(s)"
  else
    kv "Files left alone" "$N_FILES file(s), $N_FILE_LINES line(s), in $N_FILE_REPOS repo(s)"
  fi
  [ "$N_ALTSSH" -gt 0 ] && kv "Left alone" "$N_ALTSSH repo(s) on altssh.bitbucket.org"
  kv "Files to back up" "$n_backup"

  if [ "$APPLY" -eq 1 ] && [ "$n_planned" -gt 0 ]; then
    if ! backup_and_apply; then
      separator
      return 1
    fi
    separator
    say "RESULT"
    kv "URLs updated" "$N_URL_DONE"
    kv "Files rewritten" "$N_FILE_DONE"
    [ "$N_SKIP" -gt 0 ] && kv "Skipped" "$N_SKIP (already updated or gone)"
    [ "$N_FAIL" -gt 0 ] && kv "FAILED" "$N_FAIL (marked FAIL above)"
    kv "Backup" "$(tilde "$BACKUP")"
    kv "Undo" "tar -xzf $(shell_path "$BACKUP") -C /"
    kv "Log" "$(tilde "$LOG")"
    if [ "$EDITED_REPOS" != $'\n' ]; then
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        if [ "$first" -eq 1 ]; then kv "Review, commit" "git -C $(shell_path "$repo") diff"; first=0
        else kv "" "git -C $(shell_path "$repo") diff"; fi
      done <<< "$EDITED_REPOS"
    fi
  elif [ "$APPLY" -eq 1 ]; then
    separator
    say "RESULT"
    kv "Changes" "none needed"
    kv "Log" "$(tilde "$LOG")"
  else
    separator
    say "DRY RUN: nothing was changed"
    if [ "$n_planned" -gt 0 ]; then
      kv "To apply" "$(rerun_command)"
    fi
    if [ "$FIX_FILES" -eq 0 ] && [ "$N_FILES" -gt 0 ]; then
      kv "With files" "$(rerun_command fix)"
    fi
    kv "Log" "$(tilde "$LOG")"
  fi

  separator
  say "NEXT STEPS"
  case $HOSTKEY_STATE in
    missing)
      say "  $step. Run  ssh -T git@ssh.bitbucket.org  once and check the fingerprint (FIX 1)."
      step=$((step + 1)) ;;
    unknown)
      say "  $step. If you haven't yet, run  ssh -T git@ssh.bitbucket.org  once and check the"
      say "     fingerprint against https://bitbucket.org/site/ssh."
      step=$((step + 1)) ;;
  esac
  # FIX 1 is the host key when it's missing; it has its own step above.
  local from=1
  [ "$HOSTKEY_STATE" = missing ] && from=2
  if [ "$FIX_N" -ge "$from" ]; then
    if [ "$FIX_N" -eq "$from" ]; then r="FIX $from"; else r="FIX $from-$FIX_N"; fi
    say "  $step. Do the fixes under SSH & GIT SETUP ($r)."
    step=$((step + 1))
  fi
  if [ "$APPLY" -eq 0 ] && [ "$n_planned" -gt 0 ]; then
    say "  $step. Run the \"To apply\" command above."
    step=$((step + 1))
  fi
  if [ "$EDITED_REPOS" != $'\n' ]; then
    say "  $step. Review and commit the file edits (see RESULT)."
    step=$((step + 1))
  fi
  say "  $step. This only covers this machine. CI jobs, deploy targets, and servers or VMs"
  say "     with their own clones need the same change."
  separator

  [ "$N_FAIL" -eq 0 ]
}

main 2>&1 | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
