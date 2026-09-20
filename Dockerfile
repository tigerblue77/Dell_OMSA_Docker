# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# EL9, pinned, and this is the line that quietly broke the image for three and a half years.
#
# "almalinux:latest", "almalinux:10" and "almalinux:10.2" are the same digest today, and Dell
# publishes no OMSA for EL10 : os_dependent/RHEL10_64/ carries racadm and DSU but no srvadmin/
# tree and no srvadmin-all, where RHEL8_64/ and RHEL9_64/ carry both. So "dnf install
# srvadmin-all" had nothing to resolve against and the build failed -- and nothing noticed,
# because nothing built this file outside a push to master (#9).
#
# EL9 rather than EL8 because it is the newer of the two Dell still publishes for, and because
# EL8 reaches end of life first. There is no EL10 to move to later : OMSA shipped its final
# release on 2024-09-30 and is in sustenance until 2027-09-30, so this tag is where the image
# stays.
#
# Declared as an ARG rather than written into the FROM line so that the publishing workflow can
# pass the exact digest it resolved, and the image's base.digest label can describe the bytes
# that were actually built rather than whatever "almalinux:9" re-resolved to a minute later. A
# bare "docker build ." still works, which is what keeps a contributor's local build honest.
ARG BASE_IMAGE=almalinux:9
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.authors="tigerblue77"

ENV PATH="$PATH:/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin"

# Prevent daemon helper scripts from making systemd calls
ENV SYSTEMCTL_SKIP_REDIRECT=1

# pipefail, for the one pipeline below. Without it a pipeline's status is its last command's
# alone, so a download cut off mid-stream feeds the next command a fragment, that command exits
# 0 on the fragment, and the layer is committed as good. The build then fails several
# instructions later, pointing at the wrong line.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Everything in one RUN, and that is not tidiness.
#
# A layer is immutable once written, so a "dnf clean all" in a later RUN removes nothing from an
# earlier one -- it only hides the cache from the final layer's view of the filesystem, and every
# user pulls it anyway. The previous Dockerfile cleaned in its sixth layer and removed wget in its
# fifth, and shipped both regardless (#12). Cleaning in the same RUN that dirtied is the only
# arrangement where the bytes actually go away.
#
# Taken in order, and each line here is a requirement EL9 imposes that EL8 did not :
#
#   crb          srvadmin-tomcat needs openwsman-client, and on AlmaLinux 9 that package exists
#                ONLY in CRB -- verified against the repository listings rather than assumed:
#                CRB carries openwsman-client, AppStream carries openwsman-server and
#                openwsman-python3, BaseOS carries none of them. Enabled through config-manager
#                rather than by editing a .repo file by hand, so it keeps working if AlmaLinux
#                renames or splits the file again.
#
#   SHA1         Dell signs its repository metadata with SHA1, and EL9's DEFAULT crypto policy
#                refuses SHA1 in signatures outright. Without this the Dell repository is
#                unusable and dnf says so in terms that do not obviously name the cause.
#                update-crypto-policies lives in crypto-policies-scripts, which the base image
#                does not carry.
#
#   the GPG      bootstrap.cgi sets IMPORT_GPG_CONFIRMATION="na" and then asks "Do you want to
#   prompt      import Dell GPG keys (y/n)?" with a bare "read". Piped straight into bash -- which
#                is what this file used to do -- that read consumes the REST OF THE SCRIPT as its
#                answer, and the keys are silently not imported. Downloading to a file and setting
#                the variable is deterministic instead. The grep afterwards is the point of doing
#                it that way : if Dell ever renames the variable the sed becomes a no-op, and
#                without the grep that would fail much later and somewhere else.
#
#   tar, which   the Dell tooling shells out to both and neither is in the base image.
#
# --setopt=install_weak_deps=False and tsflags=nodocs keep the recommended-but-unwanted packages
# and the documentation out. srvadmin-all is around 140 MB of RPM downloads on its own
# (srvadmin-jre 39 MB, srvadmin-tomcat 36 MB, srvadmin-smweb 26 MB), so this is where the image's
# size is decided, not in the choice of base distribution (#5).
RUN set -eux; \
    dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs install dnf-plugins-core; \
    dnf config-manager --set-enabled crb; \
    dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs update; \
    dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs install \
        crypto-policies-scripts \
        kmod \
        passwd \
        perl \
        procps-ng \
        tar \
        which; \
    update-crypto-policies --set DEFAULT:SHA1; \
    curl -fsS -o /tmp/dell-bootstrap.sh https://linux.dell.com/repo/hardware/dsu/bootstrap.cgi; \
    sed -i 's/^IMPORT_GPG_CONFIRMATION="na"$/IMPORT_GPG_CONFIRMATION="yes"/' /tmp/dell-bootstrap.sh; \
    grep -q '^IMPORT_GPG_CONFIRMATION="yes"$' /tmp/dell-bootstrap.sh; \
    bash /tmp/dell-bootstrap.sh; \
    rm -f /tmp/dell-bootstrap.sh; \
    dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs install srvadmin-all; \
    rm -f /usr/lib/systemd/system/getty@.service /usr/lib/systemd/system/autovt@.service; \
    dnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

# COPY rather than ADD. ADD also auto-extracts a local archive and, historically, fetched remote
# URLs ; COPY does the one thing meant here, and hadolint rates the difference an error (DL3020).
COPY configure_and_run_Dell_OMSA.sh /configure_and_run_Dell_OMSA.sh

# Exec form, and this one is not a style point.
#
# Shell form runs as "/bin/sh -c '<the script>'". Measured : bash optimises -c with a single
# simple command into a bare exec and leaves no process in between, while dash forks and sits
# between. /bin/sh on AlmaLinux is bash, so the entrypoint really does become PID 1 here and its
# "exec /sbin/init" really does make systemd PID 1 -- docker stop reaches it. /bin/sh on Debian
# and Ubuntu is dash. So the shell form was correct here by accident of which shell the base
# image happens to ship, and would have stopped being correct the moment the base moved, with
# nothing to announce it : SIGTERM would land on the intervening shell and the container would
# start being killed on the ten-second timeout instead of shut down.
#
# The exec form takes the shell out of the path entirely, so the answer no longer depends on the
# base image at all.
CMD ["/configure_and_run_Dell_OMSA.sh"]
