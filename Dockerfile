# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

FROM almalinux:latest

LABEL org.opencontainers.image.authors="tigerblue77"

# Set environment variables
ENV PATH $PATH:/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin

# Update local packages list
RUN dnf -y update

# Install Dell OpenManage Server Administrator dependancies
RUN dnf -y install wget perl passwd procps kmod

# Add Dell Linux repository
RUN wget -q -O - https://linux.dell.com/repo/hardware/dsu/bootstrap.cgi | bash

# Install all Dell OpenManage Server Administrator packages (we could select specific components instead)
RUN dnf -y install srvadmin-all

# Uninstall dependencies which are no longer required
RUN dnf -y remove wget

# Clean cache files and repository metadata
RUN dnf clean all

# Prevent daemon helper scripts from making systemd calls
ENV SYSTEMCTL_SKIP_REDIRECT=1

# Ship the licence and the notices inside the image. AGPL-3.0 section 4 asks that
# they travel with every copy conveyed, and an image is a copy. /licenses is where
# the RHEL-family container tooling expects to find them, this image being built on
# an EL base.
COPY LICENSE LICENSE-COMMERCIAL.md NOTICE /licenses/

# Copy Docker container's script to Docker image
ADD configure_and_run_Dell_OMSA.sh /configure_and_run_Dell_OMSA.sh

# Run the application
CMD /configure_and_run_Dell_OMSA.sh
