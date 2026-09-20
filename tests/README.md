<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Test suite

Automated tests for the Dell OMSA Docker image's entrypoint. Everything runs
against mocked system commands and a throwaway sandbox root, so the suite needs
**no Dell hardware, no OMSA installation, no Docker and no network** : `bash`,
`coreutils`, `findutils`, `sed` and GNU `grep` and `awk` are enough.

```bash
./tests/run_tests.sh                  # run everything
./tests/run_tests.sh --list           # list the test cases without running them
./tests/run_tests.sh -f credential    # only run the cases whose name, or whose case file, matches
./tests/run_tests.sh --tap            # emit TAP version 13 output for a CI parser
./tests/run_tests.sh --junit FILE     # write a JUnit XML report
./tests/run_tests.sh --summary FILE   # append a Markdown report
./tests/run_tests.sh --no-color       # disable colored output
```

It exits `0` when every test case passed, `1` when one failed or the run refused
to start — a test case name declared twice, a case file that ends the runner
while it is being sourced — and `2` when it was given an option it does not
take, or one without the value it takes.

## What is being tested, and why it needs a sandbox

`configure_and_run_Dell_OMSA.sh` is not a library. It is a one-shot provisioning
script : it reads two credentials — from the environment, or from the files
`OMSA_username_FILE` and `OMSA_password_FILE` name — validates them, creates an
account, sets its password, writes OMSA's role map, writes and enables
`/etc/rc.local`, removes two systemd units and then `exec`s `/sbin/init`.
Nothing in it can be sourced and called function by function, so every
behavioural case here runs the whole script as a process and reads back what it
did — from the files it wrote, and from what the mocked commands recorded.

Which is exactly the problem. Those paths are absolute, and an absolute path is
resolved without ever consulting the `PATH` : a mock first in the `PATH` cannot
intercept `> /etc/rc.local`. Run as it ships, the entrypoint would provision the
machine running the suite.

So the seam is a **sandbox root** rather than a mocked command. `setup_test_context`
builds a throwaway `$TEST_ROOT`, copies the entrypoint into it, and rewrites each
absolute path the script names to the same path underneath `$TEST_ROOT` —
`/etc/rc.local` becomes `$TEST_ROOT/etc/rc.local`, `exec /sbin/init` becomes
`exec $TEST_ROOT/sbin/init`, where a mocked init is waiting. The commands the
script calls by name (`getent`, `useradd`, `chpasswd`, `systemctl`, `chmod`,
`rm`) are mocked the usual way, first in the `PATH`.

The rewrite is driven by `ENTRYPOINT_ABSOLUTE_PATHS` in `lib/harness.sh` : one
declared entry per absolute path, each marked `sandbox` (the script reads,
writes or runs it) or `verbatim` (it is text the script writes into a file, or
its own shebang). It is written by hand rather than generated, and two things
keep it honest :

* `test_every_absolute_path_the_entrypoint_names_is_declared_in_the_sandbox_map`
  reads the real script, extracts every absolute path in it, and fails when one
  is missing from the map. An edit that adds a write to a new path turns the
  suite red instead of reaching the machine running it.
* `run_entrypoint` refuses to run the copy at all if it still names an absolute
  path that is neither under `$TEST_ROOT` nor declared `verbatim`. That check is
  an allow list on purpose : a deny list knows nothing about a path nobody
  declared, which is the one edit this seam exists to catch.

## What is covered

| File | What it checks |
| --- | --- |
| `cases/10_shell_scripts.sh` | The repository's own files : the syntax of every script under the shell it declares, the SPDX header on the files this suite ships and (once the repository states a licence) on the files the image is built from, the shellcheck workflow's hand-maintained list against the tree — and the sandbox substitution map, in both directions, against the paths the entrypoint actually names |
| `cases/12_github_workflows.sh` | The workflow that publishes the image, which no pull request ever runs : that every `.github` YAML file parses, that every action a step uses names a version, and that the shell of every `run:` block still parses — no linter here reads it |
| `cases/20_credential_validation.sh` | `OMSA_username` and `OMSA_password` : missing, empty, one of the two, both — the status the container stops with, the message it stops on, and that a refused start provisions nothing at all. Then the same two given as files, `OMSA_username_FILE` and `OMSA_password_FILE` : read from the file, refused when it is not there or is empty, refused when a value is given twice over, and a password keeping every space it holds |
| `cases/30_user_provisioning.sh` | The account : created when it is absent, left alone when it is there, its password set either way, and the password travelling on a standard input rather than on a command line — never in the log, and not in the environment `init` is handed. Then what the lookup and the two commands around it answer for an unusual name, and what a refused `useradd` or `chpasswd` stops |
| `cases/40_omarolemap.sh` | OMSA's role map, the file whose content is a permission : that it names the account the container was given and grants it `Administrator`, on every host, with one entry after any number of restarts — and that a role map which could not be written stops the container rather than leaving it to come up with no rights in it |
| `cases/50_service_handover.sh` | The three links that make the container a running OMSA : `rc.local` written with OMSA's own service commands, made executable, its unit enabled — and the handover to `/sbin/init`, asserted as an `exec` rather than as a call. Each of the three is also exercised refused, because a link that did not take is a container that comes up healthy with no OMSA in it |
| `cases/60_systemd_unit_removal.sh` | `getty@.service` and `autovt@.service`, removed when the base image ships them and not an error when it does not, with the rest of the unit directory left alone |

Six cases in `30_` and `50_` used to pin behaviour that was **wrong** rather
than behaviour that was right, each naming the defect and saying what a later
pull request was expected to change : a case-insensitive, unescaped `grep` over
`/etc/passwd` standing in for a user database lookup, a username passed to
`adduser` with no `--` in front of it, a password piped through `echo`, and a
refused `systemctl enable` the entrypoint ignored.

That pull request is the entrypoint rewrite for issues #10 and #11, and all six
moved with it : same case, same defect named in the comment, and an assertion
that now reads the behaviour which replaced it. Documenting them is what made
the rewrite visible instead of silent — the case failed, somebody read why, and
the expectation moved in the same commit as the fix. One case in `60_` is still
of that kind and is not a defect : a refused `rm` of the two terminal units is
deliberately not fatal, because a base image that does not ship them is
legitimate, and the entrypoint says so in the log instead of stopping.

## Reports

Beside the output it prints while it runs, the suite writes two reports for
whoever reads the run afterwards :

| Option | What it produces |
| --- | --- |
| `--junit FILE` | A JUnit XML report, the format every CI knows how to publish : a failure is shown with what was expected and what was obtained, rather than buried in the raw log |
| `--summary FILE` | A Markdown report, **appended** to the file, written for `$GITHUB_STEP_SUMMARY` so that GitHub renders it on the job page : a table per suite, every test case that ran, and each failure with the command to run it again on its own |

Both are built from the same recorded results, so they can never disagree, and
both are written whatever the outcome : a red run is the one whose report
matters most.

## Layout

```
tests/
├── run_tests.sh                    entry point : discovers, runs and reports
├── cases/                          the test cases themselves
├── lib/
│   ├── assertions.sh               assert_equals, assert_contains, fail, skip_test...
│   ├── harness.sh                  the sandbox seam, the mock call logs, run_entrypoint
│   └── reports.sh                  the JUnit XML and Markdown reports
└── mocks/                          adduser, chpasswd, systemctl, chmod, rm, getent, useradd, init
```

Each test case runs in its own subshell, starting from the environment
`setup_test_context` prepares : a fresh `$TEST_ROOT` holding a plausible
`/etc/passwd`, the two systemd units the base image ships and OMSA's own role
map ; the sandboxed copy of the entrypoint ; the mocks first in the `PATH` ; and
the variables the Dockerfile sets, with `OMSA_username` and `OMSA_password`
unset, which is what `docker run` without them gives the container.

`mocks/getent` and `mocks/useradd` were shipped before anything called them :
they are what the `/etc/passwd` grep and the `adduser` call became in the
rewrite for issues #10 and #11, and a mock is cheaper to write before a rewrite
than during it. `mocks/adduser` stays behind them, unused by the entrypoint : a
handful of cases read its call log to assert that the tool it replaced was not
reached either.

## Adding a test case

Add a function named `test_<what it checks>` to the relevant file in `cases/` :
the runner picks it up on its own, in declaration order, and turns its name into
the line it reports. Nothing else to register. Its name has to be unique across
the whole suite, every case file being sourced into the same shell : the runner
refuses to run rather than let one definition silently replace another.

```bash
function test_the_role_map_grants_the_requested_user_administrator() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE"
  assert_matches "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap)" \
    '^omsauser[[:space:]]'
  assert_equals "1" "$(count_calls_matching useradd '^useradd -- omsauser$')"
}
```

Assertions record their outcome and let the test case carry on, so a case
looping over several inputs reports every offending one in a single run. Use
`assert_... || return 1` when the rest of the test case cannot run once the
assertion failed. A test case that records **no** assertion and did not call
`skip_test` is reported as a failure : a case that verified nothing is the one
thing a green suite cannot show you.

The helpers a case is written with, all from `lib/harness.sh` :

| Helper | What it does |
| --- | --- |
| `given_the_credentials USER PASSWORD` | What the container was started with |
| `given_the_sandbox_already_has_the_user NAME` | Put the account in the sandbox's `/etc/passwd`, the restart case |
| `given_the_systemd_units_exist` / `given_the_systemd_units_are_absent` | Whether the base image ships the two terminal units |
| `run_entrypoint` | Run the sandboxed script. Always returns 0 : the entrypoint's own status is in `$ENTRYPOINT_EXIT_CODE`, its streams in `$ENTRYPOINT_STDOUT`, `$ENTRYPOINT_STDERR` and `$ENTRYPOINT_OUTPUT` (the two together, which is what `docker logs` shows) |
| `sandbox_path PATH` / `sandbox_file_content PATH` / `sandbox_file_exists PATH` | Read a file of the managed machine, by the path the machine would have |
| `recorded_calls COMMAND` / `count_calls_matching COMMAND REGEX` / `forget_recorded_calls COMMAND...` | What a mocked command was called with, one line per call : its own name, then its arguments |
| `recorded_chpasswd_input` | What chpasswd was handed on its standard input, which is where the password travels |
| `the_entrypoint_reached_init` | Whether the handover to systemd happened |

A credential mounted as a file has two more,
`given_the_password_is_in_a_file VALUE` and `given_the_username_is_in_a_file VALUE`,
which live in `cases/20_credential_validation.sh` rather than in the harness :
they are that one file's business, and a case file is sourced into the same
shell as every other, so a helper declared there is available wherever it is
needed.

What a mocked command answers is set through its own `MOCK_<COMMAND>_*`
variables, each documented at the top of the mock : an exit code, an output, and
for some of them a value that takes over after a given number of calls. Two of
them, `mocks/chmod` and `mocks/rm`, record the call and then do the real thing
inside the sandbox, so that a case can assert on the mode and on the file being
gone rather than only on the command having been issued. A third, `mocks/init`,
writes the environment it was handed to `$MOCK_INIT_ENVIRONMENT_LOG` when a case
asks for it : the entrypoint takes the password back out of the environment once
chpasswd has used it, and the environment the handover passed on is the only
place a test can read that it did.
