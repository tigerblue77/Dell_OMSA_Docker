# tools/

Operator tools. Nothing in here runs in CI, and nothing in here is part of the image: these are
scripts a person runs by hand, on a real Dell PowerEdge, to find out something the repository cannot
find out on its own.

## `probe_container_privileges.sh`

### What it is

An instrument for [ShaneMcC/docker-omsa#33](https://github.com/ShaneMcC/docker-omsa/issues/33), *"What does
this actually need `--privileged` for?"*.

The maintainer's answer there is that he has not looked into it himself and is not going to, but is
not saying don't — he asked for findings on the issue rather than a patch, and wants to test on his
own hardware before anything reaches the README. So this produces a table, not a pull request.

It starts the Dell OMSA image under a ladder of progressively narrower Docker configurations --
from the README's `--privileged` recipe down to a container granted nothing at all -- and, for each
one, probes what still works: whether the container starts, whether systemd comes up, whether
`omreport` can reach the installation, the chassis, the sensors and the PERC, whether the web
interface answers on 1311, and which Dell kernel modules are visible inside. It prints a markdown
table of the result, ready to paste into the issue.

### Why it matters more than it looks like it should

There is no published working non-privileged configuration for Dell OMSA in a container. Anywhere.
Every community image -- `ShaneMcC/docker-omsa`, `kamermans/docker-openmanage`,
`srcshelton/docker-dell-utilities` -- runs `--privileged`, and the one documented attempt at
something narrower, in `lovoo/ipmi_exporter` (its issue #9: `--device=/dev/ipmi0` without
`--privileged`), failed and was never resolved.

So the honest state of the art on this question is *nobody knows*, and a plausible-sounding
capability list reasoned out of `capabilities(7)` would be the worst possible contribution to it: it
would read as authoritative, it would never have touched a real machine, and the next person would
build on it.

**One run of this script on a real PowerEdge is worth more than every opinion in ShaneMcC/docker-omsa#33, including
this repository's own, because it is the only measurement anybody will have taken.** Even a run
where nothing below `--privileged` works is worth posting: that is a finding, and today the issue
does not have one.

### Why it is not a CI job

The question is only answerable on hardware. A GitHub runner has no BMC, no `/dev/ipmi0` and no
PERC, so on a runner every rung of the ladder fails -- `--privileged` included -- and it fails for
lack of hardware rather than for lack of privilege. The job would print a table of dashes that looks
like a result and means nothing, and the next person would quote it. The measurement has to be taken
by somebody who owns the server, which is why this lives in `tools/` and not in `.github/`.

### Running it

Read the ladder first, on any machine:

```sh
./tools/probe_container_privileges.sh --list
```

Then, on the Docker host with the PowerEdge, see exactly what it would do without doing any of it:

```sh
./tools/probe_container_privileges.sh --dry-run
```

Then run it for real, redirecting stdout into the file you will paste:

```sh
./tools/probe_container_privileges.sh > omsa-privilege-probe.md
```

Progress narration goes to stderr, so it stays on your terminal while the report goes to the file.
Budget fifteen to thirty minutes: twelve configurations, each of which boots systemd and waits for
OMSA's daemons.

Before it starts anything it checks that there is a Docker daemon, that the image is present or
pullable, that `/dev/ipmi0` exists, and that the host really is a Dell -- and it says which one
failed rather than dying confusingly eleven rungs in. `--force` overrides the hardware checks, and a
report from a forced run carries a warning saying its results are not trustworthy, because they are
not.

`--help` lists the rest. The ones worth knowing about: `--only` re-runs a single rung after a
surprising result, `--ipmi-device` covers the older `/dev/ipmi/0` and `/dev/ipmidev/0` naming, and
`--no-sys-mount` skips every rung that bind-mounts the host's `/sys` if you would rather not grant
that even to a throwaway container.

### Reading the output

The report contains two tables. The first is the ladder: what each configuration id stands for, in
Docker flags. The second is the result: one row per configuration, one column per probe.

The probes fail independently, and **a partial row is the interesting outcome**. "Chassis works,
storage does not" is the shape of an answer to ShaneMcC/docker-omsa#33 -- it says the BMC path survives a narrower
configuration and the PERC path does not, which is a finding somebody can act on. "Everything works"
and "nothing works" are merely the two ends of that scale.

| Cell | Meaning |
| --- | --- |
| `ok` | the probe answered |
| `fail` | it ran and did not answer -- the first line of its error is in the Notes |
| `t/o` | it did not return within the probe timeout, which is not the same thing as failing |
| `-` | not attempted, because nothing was running to attempt it on |
| `skip` | the rung itself was not run; the Notes say why |
| `running` / `degraded` | systemd's own word for its state. Both are a healthy boot for this image |
| `http NNN` / `tcp` / `closed` | port 1311: a server answered, something merely listened, or nothing |
| `N/M` | N of the M interesting modules the *host* has loaded were visible inside the container |

Read every row against the two controls, one at each end of the ladder:

* **the top rung is the README's own recipe.** If a probe fails there, it fails for a reason that has
  nothing to do with privilege, and the same probe failing further down says nothing at all. Those
  cells are marked `†` and are not evidence. If the top rung cannot produce a working OMSA at all,
  the script stops after it and says so: there would be nothing to compare anything against.
* **the bottom rung grants nothing whatsoever.** Anything that passes there passes with no hardware
  access of any kind. `omreport about` is expected to be in this category -- it reports the
  installation, not the machine -- so a tick in that column higher up the ladder is not evidence
  either.

The report ends with a section headed *What this run cannot tell you*, listing the ambiguities that
particular run carries: modules the host kernel never loaded, probes the control also failed,
systemd-in-a-container as its own confound. Post it along with the tables. A table that hides its own
limits is worse than no table.

### What it does to the machine it runs on

It is meant to be run on a production server, so:

* every container it starts carries a unique name and a run label, and is removed as soon as its rung
  is done -- and on every exit path, including `Ctrl-C`, which also prints the partial table rather
  than throwing away what had already been measured;
* it refuses to start if a container name collides, rather than reusing or removing one it did not
  create;
* it never inspects, stops or removes a running `Dell_OMSA` container;
* it publishes no port, so it cannot fight the real container for 1311 -- which is also why the web
  probe runs from inside the container;
* it only ever runs `omreport`, which reads. `omconfig` and every other verb that writes to the
  hardware is refused at startup by a check over the probe table, not merely left unused;
* the only thing it writes is a directory of raw probe output under `$TMPDIR`, whose path it prints.

The one host-side effect it cannot avoid is the one the README recipe has anyway: on the privileged
rungs, OMSA may load its own kernel modules (`dcdbas`, `dell_rbu`) into the host kernel. That is what
the documented recipe does every time it starts. The script does not unload them afterwards, because
unloading a module on a production host is a far larger intervention than loading one.

Two smaller deviations from the README recipe, both stated in the report: `/lib/modules` is mounted
read-only (`--modules-rw` restores the recipe exactly, if you suspect the read-only mount is why the
control failed), and no port is published.

## Maintaining scripts in this directory

`.github/workflows/shellcheck.yml` names the files it lints one by one rather than globbing, so
**a new script here has to be added to that list by hand** or it is analysed by nothing at all. Both
of these pass before a change lands:

```sh
shellcheck -x tools/probe_container_privileges.sh
bash -n tools/probe_container_privileges.sh
```
