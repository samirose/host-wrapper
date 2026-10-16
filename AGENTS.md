# AGENTS.md

Working notes for AI coding agents and contributors in this repository.

## Build and test

    make                  # build host-wrapper and host-proxy
    make test             # protocol suite (sanitized binaries) + connection suite
    make test-connect     # connection and host key pinning suite only
    make check-posix      # shell portability policy below, no compiler needed
    make fuzz             # libFuzzer target, requires clang
    make fuzz-proxy       # libFuzzer target for the response decoder

`make test-connect` stubs out `ip` and `ssh`, so it needs neither a network, a
container, nor a configured host. Building on glibc Linux needs
`make LDLIBS="-lutil"`.

### The test harness

Both suites source `test-lib.sh`, which holds `report`, the `assert_*` helpers,
`make_test_dir` and `test_summary`. Add a case by calling those rather than
printing PASS and FAIL by hand: a test written through them counts towards the
tally and towards the suite's exit status with nothing further to remember.

`make_test_dir <prefix>` publishes `$TEST_DIR` and registers the trap that
removes it. Both suites do all of their work inside it, so a run leaves nothing
behind in the repository, including a run that is interrupted half way.

`test.sh` adds runners on top: `run_test` (exit 0, matched on stdout) and
`run_test_exit <name> <code>` (an exact status, matched on stderr). They
capture the two streams separately, so state which stream a message belongs on
rather than reaching for `2>&1` — a message on the wrong stream is a defect the
suite should see.

## Shell script portability

The C is written to POSIX because the guest may be a scratch Alpine container.
The same reasoning applies to the shell, but not uniformly: how strict a script
has to be depends on where it runs. Three tiers, strictest first. Apply the tier
that covers the file you are editing.

### Tier 1 — guest runtime: strict POSIX, minimal utilities

`share/host-proxy-ssh.sh`, and the `ssh/host-wrapper.env` that
`host-connect-setup.sh` writes.

These run inside the guest, where `/bin/sh` is frequently busybox `ash` and
where bash is usually absent. They must be strict POSIX shell.

Keep the external dependencies minimal and deliberate. Today the whole surface
is `awk` (POSIX awk only, no GNU extensions) and `ip` from iproute2. Do not add
a dependency on another utility here without also adding it to the README
prerequisites — this is the one tier where a missing tool is a user's broken
connection rather than a developer's inconvenience.

Edit `share/host-proxy-ssh.sh` directly. It is installed into every guest
unchanged, which is why it carries no interpolation: everything host-specific
belongs in `ssh/host-wrapper.env`, and the two values that could have been
baked in are POSIX defaults inside the script instead. Copies of the script
under an output directory are artefacts, and the ignore rules keep that name
ignored everywhere except its one source.

`ssh/host-wrapper.env` is the other way round: it is interpolated per host, so
edit the generator that writes it.

### Tier 2 — host runtime: POSIX shell language

`setup.sh`, `host-connect-setup.sh`, `host-authorized-key.sh`,
`examples/setup-container.sh`, `examples/setup-container-machine.sh`,
`examples/wrappers/*.sh`.

Users run these on their own host: the first five to install and provision, the
wrappers whenever a guest asks for the tool they stand in front of. Keep the shell
*language* strictly POSIX so they behave identically under dash, ash and bash.
Widely available utilities may be assumed, but prefer POSIX-specified options
where choosing them costs nothing.

### Tier 3 — development and test: convenience

`test.sh`, `test-connect.sh`, `examples/run-container.sh`,
`examples/run-container-machine.sh`, `examples/spike-socket.sh`.

These only ever run on a developer's machine, so readability beats portability.
Non-POSIX utilities are fine: `test-connect.sh` deliberately uses `mktemp` and
`env -u` and `test.sh` a fractional `sleep`, none of which POSIX specifies. Bash
is fine too, when declared.

The two suites nonetheless declare `#!/bin/sh`. The tier does not ask for it;
they are POSIX because `test-lib.sh` has to be, and a harness written in one
dialect is easier to move a helper around in than one written in two. Declaring
it is what puts them under `check-posix.sh`, which is what keeps them that way.
The example runners are bash and stay bash.

`check-posix.sh` and `test-lib.sh` are the exceptions in this tier; both are
written to tier 2. `check-posix.sh` is, so that it checks itself, which keeps
the enforcement honest. `test-lib.sh` is, because `check-posix.sh` runs
`test-connect.sh` under dash, and whatever that suite sources runs under dash
with it.

### Rules for every tier

- A script that uses bash features must declare `#!/usr/bin/env bash`. Never
  leave `#!/bin/sh` on a file that needs bash.
- Whatever the tier, a file declaring `#!/bin/sh` must parse and run under a
  strict POSIX shell.
- Use `printf` rather than `echo` for anything containing backslashes or
  starting with `-`. XSI `echo` expands escape sequences and bash's does not.
- When sourcing, keep a slash in the path (`. ./ssh/host-wrapper.env`).
  POSIX `.` searches `PATH` for a name with no slash in it.

### Verifying

Run `make check-posix`, which enforces everything above and is also part of
`make test`. It needs no compiler, container or network.

The target parses every `#!/bin/sh` script under a strict POSIX shell, greps for
bashisms, generates a bundle into a scratch directory to reach the interpolated
`ssh/host-wrapper.env` and the installed connection script, then runs the
connection suite under that shell. If
neither dash nor ash is installed it says so and skips the shell-dependent
parts rather than failing, so a bare machine can still run `make test`.

The rest of this section describes what it does, for checking something by hand
or extending the target.

macOS `/bin/sh` is bash in POSIX mode, so `sh -n` passing proves nothing about
portability. Check against a real POSIX shell; macOS ships dash at `/bin/dash`.

Both the parse and the grep are needed, and neither subsumes the other: dash
parses `[[ -n "$x" ]]` quite happily, as a command named `[[`, so `dash -n`
alone lets that through and only the grep catches it.

Parse every `sh` script, and the generated guest script too. Select by shebang
here as well, so the set does not go stale as scripts are added:

    for f in *.sh examples/*.sh examples/wrappers/*.sh share/*.sh; do
        [ "$(head -n 1 "$f")" = "#!/bin/sh" ] || continue
        dash -n "$f" || echo "FAIL $f"
    done

Run the connection suite end to end under dash. The shim matters: without it the
suite's inner `sh host-proxy-ssh.sh` calls would run under bash and the guest
script would never be exercised by a POSIX shell at all.

    mkdir -p "$TMPDIR/shim" && ln -sf /bin/dash "$TMPDIR/shim/sh"
    PATH="$TMPDIR/shim:$PATH" dash ./test-connect.sh

Grep for the bashisms that parse cleanly but behave differently. Select the
files by shebang rather than by name, so the check picks up new scripts on its
own and stays quiet about the tier 3 files that are legitimately bash. The
parameter expansion pattern deliberately excludes `:-` and `:=`, both POSIX.
`local` and `source` are matched in command position rather than anywhere, so
that a path such as `~/.local/state` is not a violation, and `[[` is matched
only where a character class does not follow, so that `[[:space:]]` is not one
either:

    for f in *.sh examples/*.sh examples/wrappers/*.sh share/*.sh; do
        [ "$(head -n 1 "$f")" = "#!/bin/sh" ] || continue
        grep -nE '\[\[[^:]|(^|[;&|(])[[:space:]]*(local|source)[[:space:]]|<<<|\becho +-[neE]|\+=|pipefail|\bfunction +[A-Za-z_]+ *\(|\$\{[A-Za-z_][A-Za-z0-9_]*(:[0-9]|/|\^|,)' "$f"
    done

Test the first line rather than using `grep -l`, which would match the
`#!/bin/sh` heredocs embedded inside the test scripts and drown the result in
expected hits.

A clean tree produces no output. Both globs reach into `share`, which is where
the tier 1 connection script lives; leave it out and the file that matters most
drops silently out of coverage. They reach into `examples/wrappers` for the same
reason: those run on a user's host, in front of a tool the allowlist does not
name.

## Documentation

`README.md` and `examples/README.md` describe how the project behaves now. A
reader arriving today should not have to parse what it used to do.

- **A change to behaviour checks what describes it.** Before committing, read
  what documents the code you changed: the README sections, `PROTOCOL.md`,
  `docs/`, the usage text and the comments on and around it. Fix what no
  longer holds in the same commit, so no commit leaves a description false.
- **Nothing outside this file refers to it.** Code, comments, scripts' output
  and the documentation stand on their own. Where one of them needs a fact
  this file records, write the fact there as well.
- **Do not justify a design by contrasting it with what it replaced.** Write
  "fails with a diagnostic naming the override", not "fails rather than falling
  back to a default that produced a timeout somewhere else". The reason
  something changed belongs in the commit message, which is where anyone asking
  why will look.
- **Counterfactuals about a mechanism are not history.** Saying what a feature
  prevents, or what would go wrong without it, explains the feature and belongs
  in the documentation. The test is whether the sentence would still read
  sensibly to someone who had never seen the previous version.
- **Word the same fact the same way everywhere.** Where two files explain the
  same thing, they should not drift into two descriptions a reader has to
  reconcile.
- **Say it once and stop.** Cut what the reader already knows, and leave failure
  modes to the test that reports them.

### Comments

The rules above hold for comments in code as well, and more with them:

- **Default to no comment.** Names, structure and error messages carry the
  meaning. Comment only code that is unusual, or complex for a reason the code
  cannot show. A comment saying what an error message beside it already says
  is the one to cut.
- **Do not explain the tooling.** Whoever reads this repository knows what a
  lock file pins, what `set -e` does, what `(void)arg;` is for, and what a Nix
  devShell is. Comment what they cannot derive: why this list, why this order,
  what breaks without it.
- **Two accurate lines beat six.** If a comment restates the code beneath it,
  the restating half is what to cut.
- **A function comment describes its interface.** What it does, what it returns
  and what each return means, including every way it can fail. Leave out what
  callers do with the result and how the body gets there; a reason that
  belongs to one caller goes beside that call.
- **A comment sits directly above what it describes.** Moving or deleting code
  moves or deletes its comment. Two comment blocks stacked over one declaration
  mean one of them belongs elsewhere.

## Commits

Prefer several small commits to one large one. A reviewer should be able to hold
a whole commit in their head, and a bisect should be able to land on one.

- **One logical change per commit.** A new mechanism, the call sites migrated
  onto it, and the documentation describing it are three changes, not one.
- **Make them one at a time.** Write one commit, then stop for review before
  starting the next. Feedback on one commit shapes the next, so do not
  prepare a series ahead of it.
- **Every commit stands on its own.** It builds, its tests pass, and the tree it
  leaves behind works. A commit that only makes sense once a later one lands is
  not a commit, it is half of one.
- **A mechanism arrives with its tests.** Tests are part of introducing it, not
  a follow-up. Migrating existing callers is the separate work, usually one
  commit per caller or per area.
- **Order so nothing dangles.** If a document refers to a make target, the
  commit adding the target comes first or they land together. No intermediate
  commit should point at something that does not exist yet.
- **Say how to check it.** Name the target or the steps in the message, so a
  reviewer can verify that commit alone: `make test-connect`, `make check-posix`.
- Subject in the imperative mood. The body explains why; the diff already says
  what.
- **Keep the body short.** Bulleted main points by default. Prose only where
  something is complex or non-obvious enough to need it.
- **The message stands on its own.** It names neither this file nor anything
  kept outside the repository, such as a plan or its steps. Where the reason
  lives there, spell the reason out.

### Splitting a commit that grew too large

Unpushed history is fair game, and a commit that is hard to review is worth
rewriting. Never rewrite history that has been pushed.

    git tag pre-split-backup HEAD   # safety net, delete once satisfied
    git reset HEAD~1                # keep the changes, drop the commit

Stage per file where the files map cleanly onto the logical changes; that is the
common case and needs no hunk surgery. Where one file carries two changes, build
the intermediate versions by hand, or use `git add -p`.

A split has to preserve the result exactly. This must print nothing:

    git diff pre-split-backup HEAD

Then confirm each new commit stands alone, rather than assuming it does. Check
out each in isolation and run the whole suite there, not one check from it:

    for c in $(git log --format=%h <base>..HEAD); do
        d=$(mktemp -d "${TMPDIR:-/tmp}/split.XXXXXX")
        git archive "$c" | tar -x -C "$d"
        (cd "$d" && make test >/dev/null 2>&1) || echo "BROKEN: $c"
        rm -rf "$d"
    done

`make test` builds both binaries from source, runs the protocol and connection
suites and applies the portability policy, so it answers the question the loop
is asking. A narrower check would pass on a commit that leaves the tree unable
to build. Where a commit predates a target it would otherwise need, run what
that commit actually has.
