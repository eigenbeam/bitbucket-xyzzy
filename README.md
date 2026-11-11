# bitbucket-ssh-migrate

Find the git repos on your machine that still reach Bitbucket Cloud over SSH
through the old hostname, `bitbucket.org`, and switch them to the new one,
`ssh.bitbucket.org`. It's a dry run by default, takes a backup before it
changes anything, and logs every run.

## Background

Bitbucket Cloud is moving Git-over-SSH from `bitbucket.org` to
`ssh.bitbucket.org`. Atlassian's schedule, as of this writing (check the
[announcement](https://community.atlassian.com/forums/Bitbucket-articles/Upcoming-change-to-Bitbucket-Cloud-SSH-access-move-from/ba-p/3234032)
for changes):

| Date       | What happens                                                              |
|------------|---------------------------------------------------------------------------|
| 2026-11-12 | SSH to `bitbucket.org` fails during scheduled brownouts (15 min, growing to 3 h) |
| 2026-12-10 | SSH to `bitbucket.org` is refused for good                                |

What's affected:

- **SSH remotes** like `git@bitbucket.org:team/repo.git` stop working.
- **HTTPS remotes** (`https://bitbucket.org/...`) are not affected.
- **Your SSH keys** keep working; nothing to regenerate.
- **Host keys:** `ssh.bitbucket.org` presents the same host keys as
  `bitbucket.org`, but ssh still asks you to trust the new name once.

## Features

- Scans directory trees for git repos, including worktrees and submodules.
- Rewrites `remote.*.url`, `remote.*.pushurl` and `submodule.*.url` in each
  repo's local git config.
- Optionally rewrites old-host SSH URLs in files tracked by git: Puppetfiles,
  `.gitmodules`, CI config, deploy scripts, `package.json`, and so on.
- Checks your SSH and git setup for things a URL rewrite can't fix:
  - the new host key isn't in `known_hosts` yet
  - a `Host bitbucket.org` block gives the old name settings the new name won't get
  - an ssh alias uses `HostName bitbucket.org`
  - a global `url.insteadOf` rule rewrites to the old host
- Dry run by default. `--apply` writes and verifies a backup tarball first,
  and changes nothing if the backup fails.
- Logs every run, dry or not.
- Runs on the bash that ships with macOS (3.2). No dependencies to install.

## Requirements

- bash 3.2 or later
- git, find, sed, grep, tar
- perl (only for `--fix-files`)
- ssh and ssh-keygen (only for the setup checks)

Tested on macOS. It sticks to options that are the same in BSD and GNU tools,
so Linux should work, but it hasn't been tested there.

## Installation

```sh
git clone git@github.com:eigenbeam/bitbucket-xyzzy.git
cd bitbucket-xyzzy
```

Or copy `bitbucket-ssh-migrate.sh` anywhere and run `chmod +x` on it.

## Usage

### Quick start

1. **Trust the new host once.** If you haven't already, run:

   ```sh
   ssh -T git@ssh.bitbucket.org
   ```

   Accept the key only if its fingerprint matches
   <https://bitbucket.org/site/ssh>. Until you do this, git in IDEs, GUI
   clients and scripts fails at the host-key prompt.

2. **See what would change** (dry run, changes nothing):

   ```sh
   ./bitbucket-ssh-migrate.sh ~/projects
   ```

3. **Make the changes:**

   ```sh
   ./bitbucket-ssh-migrate.sh --apply ~/projects
   ```

4. **Optionally, fix tracked files too,** then review and commit them in
   each repo:

   ```sh
   ./bitbucket-ssh-migrate.sh --apply --fix-files ~/projects
   git -C ~/projects/my-service diff
   ```

Re-running is safe. Anything already on the new host is left alone.

### Options

```
./bitbucket-ssh-migrate.sh [--apply] [--fix-files] [--depth N] [--logdir DIR] [DIR ...]
```

| Option         | Default                | Meaning                                                    |
|----------------|------------------------|------------------------------------------------------------|
| `DIR ...`      | `$HOME`                | Directories to search for repos                            |
| `--apply`      | off (dry run)          | Make the changes, after a backup                           |
| `--fix-files`  | off                    | Also rewrite old-host URLs in files tracked by git; never commits |
| `--depth N`    | `7`                    | How many directory levels to search below each DIR         |
| `--logdir DIR` | `.` (current dir)      | Where the log and backup go                                |
| `-h`, `--help` |                        | Show help                                                  |

`--fix-files` without `--apply` adds the file edits to the dry run so you can
see them first.

Tips:

- **macOS:** scanning all of `$HOME` can trigger "would like to access your
  Documents folder" prompts. Pass the directories that hold your repos to
  avoid them.
- **Running from inside a repo:** the log and backup land in that repo's
  working tree, and the script warns you. Use `--logdir` to put them
  somewhere else. This repo's `.gitignore` already ignores them.

### Exit codes

| Code | Meaning                                             |
|------|-----------------------------------------------------|
| 0    | Success, including a dry run that found changes     |
| 1    | `--apply` hit a failure, or the backup failed (then nothing was changed) |
| 2    | Bad arguments, a missing tool, or an unusable log dir |

## Example output

A dry run, trimmed:

```
--------------------------------------------------------------------------------
RUN
  Tool              bitbucket-ssh-migrate 1.1.0
  Started           2026-11-11 11:12:03 MST on my-laptop
  Command           ./bitbucket-ssh-migrate.sh ~/projects
  Mode              DRY RUN: nothing will be changed
  Log               ~/bitbucket-ssh-migrate-20261111-111203.log
--------------------------------------------------------------------------------
SSH & GIT SETUP (checked only, never changed)
  +----------------------------+--------+--------------------------------------+
  | Check                      | Status | Detail                               |
  +----------------------------+--------+--------------------------------------+
  | host key (known_hosts)     | FIX 1  | ssh.bitbucket.org not trusted yet    |
  | ssh config (Host match)    | OK     | same settings as bitbucket.org       |
  | ssh config (aliases)       | OK     | none use HostName bitbucket.org      |
  | git url.insteadOf rules    | OK     | none point at the old host           |
  +----------------------------+--------+--------------------------------------+

  FIX 1  Run once in a terminal:  ssh -T git@ssh.bitbucket.org
         Accept the key only if its fingerprint matches
         https://bitbucket.org/site/ssh. Until you do, git in IDEs, GUI
         clients and scripts fails at the host-key prompt.
--------------------------------------------------------------------------------
REPOSITORIES
  Searched          ~/projects (depth 7)
  url               URL in the repo's git config; changed by --apply
  file              URL in a tracked file; changed by --apply --fix-files
  keep              altssh.bitbucket.org (port 443); left alone
                    Only the host changes: bitbucket.org -> ssh.bitbucket.org
--------------------------------------------------------------------------------
~/projects/my-service
  url   remote.origin.url    git@bitbucket.org:myteam/my-service.git
  file  puppet/Puppetfile:2  git@bitbucket.org:myteam/puppet-nfs.git
--------------------------------------------------------------------------------
~/projects/web-app
  url   remote.origin.url  ssh://git@bitbucket.org/myteam/web-app.git
--------------------------------------------------------------------------------
PLAN
  Repos scanned     3
  URLs to update    2 in 2 repo(s)
  Files left alone  1 file(s), 1 line(s), in 1 repo(s)
  Files to back up  2
--------------------------------------------------------------------------------
DRY RUN: nothing was changed
  To apply          ./bitbucket-ssh-migrate.sh --apply ~/projects
  With files        ./bitbucket-ssh-migrate.sh --apply --fix-files ~/projects
  Log               ~/bitbucket-ssh-migrate-20261111-111203.log
--------------------------------------------------------------------------------
NEXT STEPS
  1. Run  ssh -T git@ssh.bitbucket.org  once and check the fingerprint (FIX 1).
  2. Run the "To apply" command above.
  3. This only covers this machine. CI jobs, deploy targets, and servers or VMs
     with their own clones need the same change.
--------------------------------------------------------------------------------
```

And the end of `--apply --fix-files`:

```
--------------------------------------------------------------------------------
BACKUP
  Saved             ~/bitbucket-ssh-migrate-20261111-111250-backup.tar.gz
  Contents          3 file(s), verified
--------------------------------------------------------------------------------
CHANGES
  [1/3]  ok    url   ~/projects/my-service  remote.origin.url
  [2/3]  ok    file  ~/projects/my-service  puppet/Puppetfile  (1 line(s))
  [3/3]  ok    url   ~/projects/web-app     remote.origin.url
--------------------------------------------------------------------------------
RESULT
  URLs updated      2
  Files rewritten   1
  Backup            ~/bitbucket-ssh-migrate-20261111-111250-backup.tar.gz
  Undo              tar -xzf ~/bitbucket-ssh-migrate-20261111-111250-backup.tar.gz -C /
  Log               ~/bitbucket-ssh-migrate-20261111-111250.log
  Review, commit    git -C ~/projects/my-service diff
--------------------------------------------------------------------------------
```

## What it changes

| What                                                    | Dry run | `--apply` | `--apply --fix-files` |
|---------------------------------------------------------|---------|-----------|-----------------------|
| `remote.*.url`, `remote.*.pushurl`, `submodule.*.url` in `.git/config` | shown | changed | changed |
| Old-host SSH URLs in files tracked by git               | shown   | -         | changed, not committed |
| `~/.ssh/config`, `known_hosts`, `~/.gitconfig`          | checked | checked   | checked               |

It never edits your SSH config or global git config. When something there
needs attention, it prints the exact fix.

Only the host changes. URL forms it handles:

| Before                                    | After                                         |
|-------------------------------------------|-----------------------------------------------|
| `git@bitbucket.org:team/repo.git`         | `git@ssh.bitbucket.org:team/repo.git`         |
| `ssh://git@bitbucket.org/team/repo.git`   | `ssh://git@ssh.bitbucket.org/team/repo.git`   |
| `ssh://git@bitbucket.org:22/team/repo.git`| `ssh://git@ssh.bitbucket.org:22/team/repo.git`|
| `git+ssh://git@bitbucket.org/team/repo.git` | `git+ssh://git@ssh.bitbucket.org/team/repo.git` |

Left alone:

- **HTTPS URLs**
- **URLs already on `ssh.bitbucket.org`**
- **`altssh.bitbucket.org`** (port 443): reported as `keep`, because the
  announcement doesn't say whether it changes.

## Backups, logs and undo

- **What's backed up:** with `--apply`, every file about to change goes into
  `bitbucket-ssh-migrate-<timestamp>-backup.tar.gz` in the log dir. The
  script checks the tarball holds every file before changing anything.
- **Logs:** every run writes `bitbucket-ssh-migrate-<timestamp>.log`, a copy
  of what it printed.
- **Privacy:** the log and backup are readable only by you. The backup holds
  copies of `.git/config` files, so don't commit it or share it.
- **Undo a run:** restore every file it changed to its state just before that
  run:

  ```sh
  tar -xzf bitbucket-ssh-migrate-<timestamp>-backup.tar.gz -C /
  ```

## Limitations

- **This machine only.** CI servers (Jenkins, Bamboo, Bitbucket Pipelines),
  deploy targets, and servers or VMs with their own clones need the same
  change made there.
- **Tracked files only.** `--fix-files` looks at files tracked by git, not
  untracked or ignored files.
- **Skipped directories:** the search skips `~/Library`, `~/.Trash`,
  `node_modules`, `.cache`, `.npm`, `.cargo`, `.rustup`, `.venv` and `.tox`.
- **Bare repos** aren't searched.
- **Shared repos:** file edits from `--fix-files` go in repos other people
  use. Commit them the way your team normally would.

## Troubleshooting

- **`Host key verification failed`, or git hangs in an IDE:** you haven't
  trusted the new host yet. Run `ssh -T git@ssh.bitbucket.org` once in a
  terminal.
- **`Permission denied (publickey)` after switching:** a `Host bitbucket.org`
  block in `~/.ssh/config` probably sets your key, and it doesn't match the
  new name. The "ssh config (Host match)" check flags this. Add the new name
  to that line: `Host bitbucket.org ssh.bitbucket.org`.
- **A repo is marked `SKIP`:** git couldn't read it. Common causes are a
  worktree whose main repo was deleted, or a repo owned by another user. The
  line shows git's error.
- **Something went wrong after `--apply`:** restore from the backup (see
  above), then run the dry run again to see the plan.

## Disclaimer

YMMV. This script is provided as is, with no warranty of any kind, express or
implied, including fitness for any particular purpose (see [LICENSE](LICENSE)
for the formal version). It edits git config and, if you ask, files in your
repos. Run the dry run first, read the plan, and keep the backup. If something
goes wrong anyway, take it up with the Jedi Council.

## License

[MIT](LICENSE)
