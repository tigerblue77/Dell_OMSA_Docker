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

# Copy Docker container's script to Docker image
ADD configure_and_run_Dell_OMSA.sh /configure_and_run_Dell_OMSA.sh

# Run the application
CMD /configure_and_run_Dell_OMSA.sh
