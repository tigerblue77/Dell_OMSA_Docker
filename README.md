<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

<div id="top"></div>

# Dell OMSA Docker image

Dell OpenManage Server Administrator, in a container. It gives you the OMSA web interface on port 1311 and the `omreport` / `omconfig` command line, against the PowerEdge the container runs on — temperatures, fans, power supplies, the PERC and the disks behind it, the BIOS, the ESM log — without installing Dell's agent onto the host itself.

That last part is the whole point. OMSA is a sprawling install: a private JRE, a Tomcat, a dozen daemons and a set of kernel-module helpers, all of it pinned to one distribution's package set. Putting it in a container keeps it off a hypervisor whose packages you would rather not fight with, and lets you throw it away and rebuild it when Dell moves.

> [!WARNING]
> **OMSA reached the end of its life on 30 September 2024.** Dell's own [end of life page](https://www.dell.com/support/kbdoc/en-us/000224826/omsa-eol-landing-page) says it plainly: that was the final release, it is in sustenance mode — security and critical-escalation fixes only — **until 30 September 2027**, and it supports **14th, 15th and 16th generation** PowerEdge servers. It does **not** support the 17th. Dell's stated replacement is iDRAC together with the [iDRAC Service Module](https://www.dell.com/support/kbdoc/en-us/000178050/support-for-idrac-service-module-ism).
>
> This image is worth running anyway if you have a 14G to 16G server and want what OMSA gives you. It is worth knowing before you build a monitoring stack on top of it. If all you want is metrics, an agentless Redfish exporter talking to your iDRAC over the network needs no privileged container, no kernel modules and no agent on the host at all — and it will outlive OMSA.

## Table of contents
<ol>
  <li><a href="#requirements">Requirements</a></li>
  <li><a href="#supported-architectures">Supported architectures</a></li>
  <li><a href="#download-docker-image">Download Docker image</a></li>
  <li><a href="#usage">Usage</a></li>
  <li><a href="#parameters">Parameters</a></li>
  <li><a href="#the-web-interface">The web interface</a></li>
  <li><a href="#the-command-line">The command line</a></li>
  <li><a href="#stopping-the-container">Stopping the container</a></li>
  <li><a href="#troubleshooting">Troubleshooting</a></li>
  <li><a href="#contributors">Contributors</a></li>
  <li><a href="#contributing">Contributing</a></li>
  <li><a href="#license">License</a></li>
</ol>

<!-- REQUIREMENTS -->
## Requirements

### Your server

A Dell PowerEdge. Which generations actually work is decided by the OMSA release the image installs, not by the container:

| PowerEdge generation | OMSA 11.1.0.0, which this image installs |
| --- | --- |
| 14th, 15th, 16th | Supported, and what the final OMSA release targets |
| 13th and older | Not in the supported list any more. Older OMSA releases covered them, and Dell still publishes those, so an older server is a matter of installing an older OMSA rather than a lost cause |
| 17th | **Never supported.** OMSA was discontinued before it shipped — use iDRAC and iSM |

OMSA reads the hardware through the host, so the container has to run on the PowerEdge itself. It is not a remote management tool: it cannot be pointed at another machine the way an iDRAC client can.

### Your Docker host

- **x86-64.** See [Supported architectures](#supported-architectures) — this is not a preference, it is the only thing Dell ships.
- **The container runs `--privileged` today.** OMSA talks to IPMI character devices, to `sysfs`, and to the storage controller through kernel modules it loads itself. Nobody has yet published a narrower set of capabilities that gets all of that working, this project included — [issue #4](https://github.com/tigerblue77/Dell_OMSA_Docker/issues/4) tracks the attempt, and it is honest about the fact that the one documented attempt at a narrower configuration, in an adjacent project, failed and was never resolved.
- **A kernel that has the Dell modules.** See below.

### Kernel modules

The container does not ship kernel modules and cannot: a module has to match the running kernel. It loads them from the host, which is why `/lib/modules/$(uname -r)` is mounted in. The ones OMSA reaches for:

| Module | What it is for |
| --- | --- |
| `dcdbas` | Dell's systems-management base driver — the SMI / SMBIOS calling interface OMSA and `libsmbios` go through |
| `dell_rbu` | [Remote BIOS Update](https://www.kernel.org/doc/html/latest/admin-guide/dell_rbu.html) — only needed for BIOS flashing from OMSA |
| `ipmi_si`, `ipmi_devintf`, `ipmi_msghandler` | What creates and drives `/dev/ipmi0` |

A stock Debian, Ubuntu or RHEL-family kernel has all of them. A hypervisor's own kernel may not — see [the troubleshooting entry](#the-log-says-modprobe-fatal-module-dell_rbu-not-found) for what that actually costs you, which is less than the error suggests.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- SUPPORTED ARCHITECTURES -->
## Supported architectures

**`linux/amd64` only, and that is not going to change.**

This is worth stating flatly because every other container in this family is multi-architecture and this one cannot be. Dell publishes OMSA as RPMs in [its own repository](https://linux.dell.com/repo/hardware/dsu/os_dependent/RHEL9_64/), and every single one of the forty packages that make up `srvadmin-all` — the thirty components and the ten meta-packages — is `x86_64`. There is no `aarch64` build, no source to rebuild from, and OMSA is end-of-life, so there will not be one.

An arm64 image would therefore be an arm64 base with no OMSA in it.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- DOWNLOAD DOCKER IMAGE -->
## Download Docker image

The same image is published to two registries:

```bash
docker pull tigerblue77/dell_omsa:latest
```

```bash
docker pull ghcr.io/tigerblue77/dell_omsa:latest
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- USAGE -->
## Usage

### With `docker run`

```bash
docker run -d \
  --name Dell_OMSA \
  --privileged \
  --restart unless-stopped \
  -e OMSA_username="<the account name you will log into the web interface with>" \
  -e OMSA_password="<its password — read the warning in Parameters first>" \
  -v "/lib/modules/$(uname -r):/lib/modules/$(uname -r):ro" \
  -v "Dell_OMSA_logs:/opt/dell/srvadmin/var/log/:rw" \
  -p 1311:1311 \
  tigerblue77/dell_omsa:latest
```

`$(uname -r)` is evaluated by your shell, on the host, so the mount names the kernel that is actually running. Mounting `/lib/modules` whole works too and is what you want if the host reboots into a different kernel, since the path then stays valid across the change.

### With `docker compose`

```yml
services:
  dell_omsa:
    image: tigerblue77/dell_omsa:latest
    container_name: Dell_OMSA
    privileged: true
    restart: unless-stopped
    environment:
      - OMSA_username=<the account name you will log into the web interface with>
      - OMSA_password=<its password — read the warning in Parameters first>
    volumes:
      - /lib/modules:/lib/modules:ro
      - Dell_OMSA_logs:/opt/dell/srvadmin/var/log/:rw
    ports:
      - 1311:1311

volumes:
  Dell_OMSA_logs:
```

Compose has no equivalent of `$(uname -r)`, which is why this one mounts `/lib/modules` whole.

### With an `.env` file

Keeping the password out of your shell history and out of the compose file is worth the extra file:

```bash
cp .env.example .env
# edit .env
docker run -d --name Dell_OMSA --privileged --restart unless-stopped \
  --env-file .env \
  -v "/lib/modules/$(uname -r):/lib/modules/$(uname -r):ro" \
  -v "Dell_OMSA_logs:/opt/dell/srvadmin/var/log/:rw" \
  -p 1311:1311 \
  tigerblue77/dell_omsa:latest
```

or, in compose:

```yml
services:
  dell_omsa:
    image: tigerblue77/dell_omsa:latest
    env_file: .env
    # ... the rest as above
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- PARAMETERS -->
## Parameters

- `OMSA_username` is the name of the account the container creates inside itself and grants OMSA's `Administrator` role to. It is the name you log in with at `https://<host>:1311`. It has **no default**, and the container refuses to start without it. It is a local account inside the container and nothing else: it is not your host's `root`, it grants nothing on the host, and calling it `root` — as the old example did — buys you nothing but the habit.

- `OMSA_password` is that account's password. It has **no default** either, and the container refuses to start without it.

  > [!CAUTION]
  > **This password is visible to anything that can read the container's configuration.** `docker inspect Dell_OMSA` prints it, `/proc/<pid>/environ` holds it, and it lands in your shell history if you typed it on the command line. That is how the image has always worked and this README is not going to pretend otherwise. Use a password that protects nothing else, and prefer the `.env` file above to typing it inline. Reading the password from a Docker secret instead is tracked in [issue #11](https://github.com/tigerblue77/Dell_OMSA_Docker/issues/11).

Both are read once, at startup. Changing either means recreating the container.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- THE WEB INTERFACE -->
## The web interface

`https://<your host>:1311` — **`https`, not `http`**, and the port is not optional.

OMSA generates its own self-signed certificate at install time, with the container's hostname as the common name. Your browser will object, twice over: the certificate is self-signed, and the name on it is a container ID rather than the address you typed. Both are expected. If you would rather it were not, OMSA can regenerate the certificate for a name of your choosing:

```bash
docker exec Dell_OMSA omconfig preferences webserver \
  attribute=gennewcert cn=omsa.example.lan validity=365 webserverrestart=true
```

`omconfig preferences webserver` is also where the listening port, the bind address, the TLS protocol version, the cipher list and the session timeout live, and it takes a PKCS#12 bundle through `attribute=uploadcert` if you have a certificate of your own.

Log in with the `OMSA_username` and `OMSA_password` you set. The account is mapped to OMSA's `Administrator` role through `/opt/dell/srvadmin/etc/omarolemap`, which the entrypoint writes at every start.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- THE COMMAND LINE -->
## The command line

Everything the web interface shows, `omreport` prints, and it is very often the faster way to get at it:

```bash
docker exec Dell_OMSA omreport system summary       # the whole machine, at a glance
docker exec Dell_OMSA omreport chassis temps        # temperature probes and their thresholds
docker exec Dell_OMSA omreport chassis fans         # fan speeds
docker exec Dell_OMSA omreport chassis pwrsupplies  # PSU presence and state
docker exec Dell_OMSA omreport chassis bios         # BIOS version and date
docker exec Dell_OMSA omreport storage controller   # the PERC
docker exec Dell_OMSA omreport storage pdisk controller=0   # the disks behind it
docker exec Dell_OMSA omreport storage vdisk        # the virtual disks
docker exec Dell_OMSA omreport system esmlog        # the hardware event log
```

`omconfig` is the write half of the same pair — it sets thresholds, clears logs, blinks a drive's identify LED, and configures the web server as shown above. `omhelp` lists what either will take.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- STOPPING THE CONTAINER -->
## Stopping the container

```bash
docker stop Dell_OMSA
```

The container runs `systemd` as its PID 1, which handles `SIGTERM` the way you would expect: it stops the OMSA services and exits. Give it a few seconds — Docker's default ten-second grace period is enough, and cutting it shorter means `SIGKILL` lands on Tomcat mid-shutdown, which costs you nothing permanent but makes the next start slower while OMSA tidies up after itself.

Stopping the container does not change anything on the server. OMSA reports and configures; it does not hold the hardware in a state that has to be handed back.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- TROUBLESHOOTING -->
## Troubleshooting

### The log says `modprobe: FATAL: Module dell_rbu not found`

```
modprobe: FATAL: Module dell_rbu not found in directory /lib/modules/5.10.0-21-amd64
```

`dell_rbu` is the Remote BIOS Update driver. Your host's kernel was built without it, and the container cannot supply it — a module has to match the running kernel, which is exactly why `/lib/modules` is mounted in rather than shipped.

**On most hosts this is cosmetic.** `dell_rbu` is only used for flashing the BIOS from OMSA. Temperatures, fans, power supplies, storage and the web interface do not go through it, and they keep working. If you are not updating firmware from inside the container, you can leave it.

It is not universally cosmetic, though, and it is worth knowing which case you are in: on XCP-ng, whose kernel ships without the module, [OMSA's services have been reported to fail to start outright](https://xcp-ng.org/forum/topic/2499/broken-dell-management-missing-driver), taking port 1311 with them. So: if the web interface answers, ignore the line. If it does not, the missing module is a candidate rather than a red herring, and the fix is to get the module onto the host — most distributions ship it as `CONFIG_DELL_RBU=m` and it is a `modprobe dell_rbu` away, some package it separately.

`dcdbas` and the `ipmi_*` modules are a different matter — without those, OMSA sees nothing at all.

### Nothing is listening on port 1311

Check, in this order:

1. `docker logs Dell_OMSA` — if the container exited immediately with `Please specify OMSA_username and OMSA_password env vars.`, that is exactly what happened.
2. `docker exec Dell_OMSA /opt/dell/srvadmin/sbin/srvadmin-services.sh status` — this is the authoritative answer to "did OMSA actually start".
3. `docker exec Dell_OMSA lsmod | grep -iE 'dell|ipmi|dcdbas'` — if this is empty, the modules never loaded and the previous section is where to go.
4. Whether the container really is `--privileged`. Without it, OMSA starts and then fails at the first thing that touches the hardware, which is not always loud.

The container runs `systemd` as PID 1, and systemd in a container is sensitive to how the host arranges cgroups. If everything above looks right and OMSA still will not come up, `--cgroupns private` is the flag that has been reported to make the difference on cgroup v2 hosts.

### The browser refuses the certificate

Expected — see [The web interface](#the-web-interface). Self-signed, with the container's ID for a name. Regenerate it with `omconfig preferences webserver attribute=gennewcert` if the warning bothers you.

### `omreport storage` shows nothing, or shows less than you expect

OMSA reads the storage controller through `srvadmin-storage` and the vendor libraries beside it. A controller in HBA / pass-through mode has no virtual disks to report, which is not a fault. A controller OMSA does not know — a third-party HBA, an NVMe device behind no controller at all — will not appear either. `omreport storage controller` is the first thing to check: if the PERC itself is not listed, nothing behind it will be.

### The image is older than you expect

The published image is rebuilt when a release is tagged, not when Dell publishes a package. If you want the current OMSA rather than the one that was current when the image was built, rebuild it yourself:

```bash
git clone https://github.com/tigerblue77/Dell_OMSA_Docker.git
cd Dell_OMSA_Docker
docker build -t dell_omsa:local .
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTRIBUTORS -->
## Contributors

<a href="https://github.com/tigerblue77/Dell_OMSA_Docker/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=tigerblue77/Dell_OMSA_Docker" alt="contributors" />
</a>

This repository began as a fork of [ShaneMcC/docker-omsa](https://github.com/ShaneMcC/docker-omsa) by Shane Mc Cormack, which is still maintained and still worth a look. What remains of that work here, and the licensing question it raises, is set out in [`NOTICE`](./NOTICE).

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire and create. Any contribution you make is **greatly appreciated**.

1. Fork the project
2. Create your branch (`git checkout -b my-change`)
3. Commit your changes, **signed off** (`git commit -s -m 'Add some feature'`)
4. Push to the branch (`git push origin my-change`)
5. Open a pull request

[`CONTRIBUTING.md`](./CONTRIBUTING.md) covers the licensing side — what a contribution grants, why the sign-off is required rather than encouraged, and the SPDX header every file carries.

Before you open one, build the image at least once:

```bash
docker build -t dell_omsa:dev .
```

and keep [`shellcheck`](https://www.shellcheck.net/) and [`hadolint`](https://github.com/hadolint/hadolint) quiet — CI runs both on every pull request, along with a build of the image itself.

If you tested on real hardware, say which server, which generation and which OMSA version. This project talks to a decade of Dell firmware and that context is worth more than it looks.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- LICENSE -->
## License

[![License: AGPL v3][agpl-shield]][agpl] [![Commercial licence available][commercial-shield]][link-to-commercial-license-file]

Dual-licensed. [AGPL-3.0-only](./LICENSE) for everyone, at no cost and with no formality, plus a [separate commercial licence](./LICENSE-COMMERCIAL.md) for parties who cannot meet the AGPL's obligations. **The choice is the recipient's**: taking it under the AGPL requires no permission, no registration and no notice to anybody.

### What you may do

| Using it | Under AGPL-3.0-only |
| --- | --- |
| Run the container on your own servers, at home or at work, at any scale | ✅ |
| Modify it for yourself and never publish the result | ✅ |
| Publish your modifications, under the AGPL | ✅ |
| Redistribute the image or the scripts, licence and notices intact | ✅ |

| Putting it inside something you ship | What you need |
| --- | --- |
| Ship it in a product or an appliance, publishing your modified source under the AGPL | Nothing beyond the AGPL |
| Ship it while withholding that source | A [commercial licence](./LICENSE-COMMERCIAL.md) |
| A warranty, an indemnity or a support commitment | A commercial licence — the AGPL disclaims all three |

> [!IMPORTANT]
> **Neither arm of that licence reaches the Dell software inside the image.** The `srvadmin-*` packages are Dell's, under Dell's own end user licence agreement, and this project holds no right to relicense them and states none. If you redistribute the built image you are redistributing Dell's software under Dell's terms, whatever this repository says about its own scripts.
>
> [`NOTICE`](./NOTICE) sets that out in full, along with the separate question of the upstream material this repository inherited without a licence.

[agpl]: https://www.gnu.org/licenses/agpl-3.0
[agpl-shield]: https://img.shields.io/badge/License-AGPL%20v3-blue.svg
[commercial-shield]: https://img.shields.io/badge/Commercial%20licence-available-brightgreen.svg
[link-to-license-file]: ./LICENSE
[link-to-commercial-license-file]: ./LICENSE-COMMERCIAL.md
[link-to-notice-file]: ./NOTICE

<p align="right">(<a href="#top">back to top</a>)</p>
