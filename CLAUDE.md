<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Working in this repository

A `Dockerfile` and a 44-line POSIX `sh` script. That is the whole program, and almost none of the
difficulty is in it : the image installs **Dell OpenManage Server Administrator**, a proprietary
agent Dell publishes as RPMs for two EL majors and one Ubuntu codename, and everything that goes
wrong here goes wrong at the seam between that package set and whatever base image is underneath
it. Read the invariants before changing either file.

OMSA itself is **end of life**. Final release 30 September 2024, sustenance until 30 September
2027, 14th to 16th generation PowerEdge only, never the 17th. That is not a reason to stop
maintaining the image — it is the reason nothing upstream is going to move under it except by
disappearing, which is a different maintenance problem from the usual one.

## Layout

| File | What it holds |
| --- | --- |
| `Dockerfile` | The base image, the Dell repository bootstrap, `srvadmin-all`, and the handover to the entrypoint |
| `configure_and_run_Dell_OMSA.sh` | The container's first process : validates the two credentials, creates the account, writes OMSA's role map, `exec`s `/sbin/init` |
| `README.md` | Written for somebody with a PowerEdge and no OMSA experience. The troubleshooting section is the half that earns the file |
| `NOTICE` | The licence chain, the upstream material this repository inherited without a licence, and the Dell packages neither licence reaches |
| `.github/workflows/` | Lint, build, smoke test, publish |
| `.hadolint.yaml` | Every ignored rule with its argument beside it, split into permanent and temporary |
| `.claude/` | The SessionStart hook and the permission list. Read the hook's own header before changing it |

## Commands

There is no build step and, in a Claude Code web session, no Docker daemon. These are what a
session can actually run :

```bash
shellcheck -x -e SC2154,SC2166,SC2006,SC2002 configure_and_run_Dell_OMSA.sh   # exactly what CI runs
hadolint Dockerfile                                                           # reads .hadolint.yaml
sh -n configure_and_run_Dell_OMSA.sh                                          # parse, do not execute
```

The `-e` codes are not a shrug : each is argued in `.github/workflows/shellcheck.yml` beside the
invocation carrying it, three of the four are real defects parked until the pull request that
fixes them, and that pull request deletes the code from the list. Same arrangement in
`.hadolint.yaml`. **An exclusion that loses its argument is the bug**, not the finding underneath
it.

```bash
docker build -t dell_omsa:dev .
```

**This does not run in a web session, and it looks like it does.** The `docker` binary is on the
`PATH`, so the command is accepted and answers `cannot connect to the Docker daemon`. Piping it
into `tail` or `head` hides even that — the pipeline's status is its last command's, so it exits
0 whatever docker did. A workflow builds the image on every pull request, so nothing is lost by
leaving it out. **Say it was not run**, rather than reporting a build that never happened.

## Conventions

**Commits.** Subject : one sentence, imperative, sentence case, no type prefix, no trailing full
stop, with the issue number in parentheses when there is one. Body : prose paragraphs explaining
*why* and what it cost to find out, not a bullet list of what changed.

**Sign off every commit.** A commit without `Signed-off-by` is not mergeable ; `CONTRIBUTING.md`
says what it certifies in a dual-licensed project. Two identities are involved and they answer
different questions : the commit is **authored** by the session, because that is who wrote it,
and the trailer names the **maintainer**, because a tool certifies nothing. `git commit -s`
derives the trailer from the author and would collapse the two, so it is passed explicitly —
`.claude/hooks/session-start.sh` sets a `git signoff` alias carrying the right address at the
start of every session, in the maintainer's own copy and nowhere else. **No `Co-Authored-By`
accompanies them** : the author field already names the agent, and a second attribution repeating
it is only another place to fall out of step. This is the sibling repositories' rule verbatim, and
it is verbatim on purpose — a rule that holds in one repository and not another is a rule nobody
can rely on.

**Open every issue and pull request assigned to `tigerblue77`, and never as a draft.** Both are
fields on the call that creates the thing, and the session that would come back to repair them
afterwards has ended by then. A draft has to be converted by hand before it can be merged, so the
state costs a click and buys nothing ; unassigned is quieter and costs the same way, the
maintainer's *Assigned* list being where the work is scheduled. This governs **the maintainer's
sessions, not everyone who clones the repository** — a contributor's pull request is theirs to
assign and theirs to open as a draft. The SessionStart hook says both at the start of every
session, and says nothing on a fork.

**Every new shell script carries the two SPDX lines** right after the shebang. The `Dockerfile`
and the YAML under `.github/` carry the same two as `#` comments ; Markdown carries them in an
HTML comment. Copy them from any existing file, and do not add your own copyright line.

**A new shell script must be added by hand to `.github/workflows/shellcheck.yml`.** That workflow
names its files one at a time instead of globbing, deliberately : a glob lints whatever it happens
to match, and a script that arrives in a shape it misses is analysed by nothing with nothing to
say so. Unlike the sibling repository, **nothing here enforces the list** — there is no test suite
yet, so it is guarded by review alone.

**Nothing is assumed : an ambiguity is a question, not a judgement call.** Where two readings of
an instruction would lead to materially different work, the question is put before the work starts,
even though asking costs a round trip — because guessing costs the work. The judgement being asked
for is narrow : routine calls a careful colleague makes alone stay made alone, and what gets asked
is what changes the shape of what gets delivered. A default chosen silently is a decision nobody
made, and it surfaces at review, which is the most expensive place for it to surface.

**A request to merge says what the pull request brings.** Merging is the maintainer's own act, so
the ask carries what they need in order to decide : what the change does, what it is worth, what in
it could not be verified and why, and — where it has siblings — the order it wants merging in.
"This is ready" makes them work all of that out from the diff, which is the work the session was
supposed to have already done, done twice. In this repository the unverified half is rarely empty
and is usually the same half : nothing here can be confirmed against a real PowerEdge from a
session, so say which claims rest on CI and which rest on nobody having checked yet.

Both of those are the maintainer's standing rules across all three repositories rather than this
one's own, and they are stated here verbatim for the reason the sign-off convention is : a rule that
holds in one repository and not another is a rule nobody can rely on.

**Language.** Documentation, comments, commit messages, issues and pull requests are in English.

**Issue and pull request text runs the full width GitHub gives it.** No hard line break inside a
paragraph : GitHub reflows prose to the reader's window, so a body wrapped at 100 columns is a
narrow strip down the middle of a wide screen. What Markdown makes line-structured keeps its lines.
This is deliberately the opposite of the rule for files in the repository, which stay wrapped —
nothing ever reflows a file.

**An issue's whole point lives in its description**, including the fallback options considered in
case the first choice fails. Nothing essential buried in a comment thread. One issue, one subject.

**The closing keyword is written in English**, `Closes #NN` or `Fixes #NN` : GitHub recognises no
other form.

## Invariants — things that look wrong and are not

Each of these has been paid for once. Read the issue before "fixing" one.

1. **The base image tag is load-bearing, and `latest` is the wrong one.** `almalinux:latest`,
   `almalinux:10` and `almalinux:10.2` are the same digest today, and **Dell publishes no OMSA for
   EL10** : `os_dependent/RHEL10_64/` carries `racadm` and DSU but no `srvadmin/` tree and no
   `srvadmin-all`, where `RHEL8_64/` and `RHEL9_64/` carry both. So `dnf -y install srvadmin-all`
   has nothing to resolve against and the build fails. This went unnoticed for three and a half
   years because nothing built the `Dockerfile` outside a push to `master` (#9). Check Dell's tree
   before changing the base image, not after.

2. **A `dnf clean all` in a later `RUN` shrinks nothing.** A layer is immutable once written, so
   cleaning in the sixth layer does not remove the cache baked into the first five — it only hides
   it from the final layer's view of the filesystem, and every user pulls it anyway. `dnf -y remove
   wget` is the same trick failing the same way. Clean in the same `RUN` that dirtied, or do not
   bother (#12).

3. **Whether `systemd` is PID 1 depends on which shell the base image ships.** `CMD` is in shell
   form, so it runs as `/bin/sh -c '<script>'`. Measured : `bash -c` with a single simple command
   `exec`s and leaves no process in between (the script's `ppid` is the *calling* shell) ; `dash
   -c` forks and sits between. `/bin/sh` on AlmaLinux is bash, so the entrypoint does become PID 1
   here and its `exec /sbin/init` does make `systemd` PID 1 — `docker stop` reaches it. `/bin/sh`
   on Debian and Ubuntu is dash. So the exec-form `CMD` is not tidying-up : it is what keeps the
   signal path independent of the base image, and it has to land **before** anything touches the
   base image, not after (#12, and why #5's answer matters here too).

4. **`SYSTEMCTL_SKIP_REDIRECT=1` is set and not exploited.** Its purpose is to make an
   `/etc/init.d/<script>` invocation skip the "redirect this to `systemctl`" shim and run the raw
   legacy init logic — that is, it is the mechanism that would let `srvadmin-services.sh start`
   work *without* systemd. The image sets it and then `exec`s real systemd anyway. Inherited from
   upstream ; harmless, and the wrong thing to delete without first deciding whether systemd is
   staying (#4).

5. **The image is `x86_64` only, and that is not a preference.** Every one of the forty packages
   making up `srvadmin-all` in Dell's EL9 tree is `x86_64`. No `aarch64` build, no source to
   rebuild from, and OMSA shipped its final release in 2024. A multi-architecture build would
   publish an arm64 image with no OMSA in it (#18).

6. **Dell's repository is rolling and keeps only the current release.** `RHEL9_64/srvadmin/` holds
   OMSA 11.1.0.0 and nothing else. That is why `.hadolint.yaml` treats `DL3041` (pin package
   versions) as permanently inapplicable rather than parked — though the argument is weaker than it
   was, OMSA having no next version to move out from under a pin, and the entry says so.

7. **`OMSA_password` is in the container's environment, visible to `docker inspect` and
   `/proc/<pid>/environ`.** That is how the image has always worked, the README says so plainly
   rather than pretending otherwise, and #11 is the fix. Do not "reassure" the reader about it.

8. **The parked lint exclusions are a record, not laziness.** Three `shellcheck` codes and five
   `hadolint` rules sit excluded with their arguments beside them, each marked temporary, each
   deleted by the pull request that fixes the line it names. A lint that is red the day it merges
   is a lint somebody switches off ; the jobs still block every *new* finding from day one. Adding
   an exclusion without its argument is what this arrangement exists to prevent.

9. **Dependabot's `docker` ecosystem has nothing to do while the base image is unpinned**, and has
   had nothing to do since it was added. It is not misconfigured. Pinning the base is what switches
   it on. There is no `github-actions` ecosystem at all, so nothing has ever bumped an action here.

10. **Part of this tree is not this project's to license.** It is a fork of `ShaneMcC/docker-omsa`,
    which carries no licence, so roughly thirteen lines of the `Dockerfile`, thirteen of the
    entrypoint — plus its whole shape, which no line count shows — and twenty of the old README are
    material nobody here ever had the right to relicense. `NOTICE` names it and neither arm of the
    dual licence covers it (#7). A rewrite launders the lines and not the structure.

11. **Neither arm of the licence reaches the Dell software inside the image.** The `srvadmin-*`
    packages are proprietary, under Dell's own end user licence agreement. Redistributing the built
    image means redistributing Dell's software under Dell's terms. Never write anything that
    suggests the AGPL covers them.

## Working in a Claude Code web session

`.claude/hooks/session-start.sh` installs what CI gates on — `shellcheck` from apt, `hadolint` as a
pinned static binary from its GitHub release — and sets the `git signoff` alias, in the maintainer's
own copy of the repository and nowhere else. It is synchronous, idempotent and best-effort : a
package index or a release host that cannot be reached costs the session a linter, not its start.
Its header argues every part of that, including the four things that had to be fixed before
"best-effort" was true rather than merely stated. Read it there.

`.claude/settings.json` pre-approves four commands so a session runs them without stopping to ask :
`shellcheck` and `bash -n` and `sh -n` with any arguments, and `hadolint Dockerfile` **exactly**.
The asymmetry is deliberate and worth not undoing : `shellcheck`, `bash -n` and `sh -n` have no
option that names a file to write, while `hadolint` has `-o, --output`, so a `hadolint:*` prefix
rule would pre-approve writing anywhere on disk. There is one `Dockerfile` and it is at the root,
so the exact form costs nothing. `git` and `docker build` are deliberately absent. That list is a
standing grant to every session opened here, so adding to it is a decision to argue, not a line to
append.
