#!/bin/sh

# Entrypoint of the Dell OpenManage Server Administrator image : it provisions
# the account OMSA authenticates against, writes the two files OMSA reads, and
# hands the machine over to systemd, which is what actually starts the services.
#
# POSIX sh, and nothing below assumes more than that. The base image's "sh"
# happens to be bash today -- which is the only reason the password this script
# used to pipe through "echo" arrived intact -- and the base image is under
# discussion (issues #5 and #9). A script that only works under one of them is a
# script that breaks on the day somebody changes the first line of the
# Dockerfile.
#
# Rewritten for issue #10 (every command was assumed to succeed, and three of
# them were asked the wrong question) and issue #11 (the password could only be
# given in the environment).

set -eu

# A single newline, so that exactly one of them can be stripped off the end of a
# secret file below. "$(printf '\n')" cannot stand in for this : a command
# substitution drops every trailing newline of what it captures, and a newline
# is all this holds
NEWLINE='
'

# Stop the container, saying what failed and what carrying on would have cost.
#
# Before this rewrite nothing here was checked : a refused "systemctl enable"
# left a container that starts, looks healthy and never runs OMSA at all, with
# one line in a log nobody had a reason to read. A failure nobody is told about
# is the expensive half of issue #10, so every step the container is useless
# without ends in a call to this
# Usage : some_command || fatal "what failed" "what it would have meant"
fatal() {
  printf '%s\n' "$@" >&2
  exit 1
}

# The value held by the file a "<variable>_FILE" names, printed with no trailing
# newline of its own.
#
# A file is how Docker Swarm and Compose hand a secret to a container, and it is
# the reason issue #11 exists : an environment variable is the copy that ends up
# in "docker inspect" output, pasted into an issue report by somebody asking why
# their container will not start.
#
# Printed rather than assigned to a variable, because the caller reads it
# through a command substitution and a variable assigned inside one of those is
# lost with the subshell it was assigned in. The "exit" that fatal() makes from
# here leaves that same subshell and nothing else, which is why every call site
# below checks the status and exits on it
# Usage : VALUE=$(credential_from_file NAME "$FILE" && printf x) || exit 1
credential_from_file() {
  CREDENTIAL_VARIABLE_NAME="$1"
  CREDENTIAL_FILE_NAME="$2"

  [ -f "$CREDENTIAL_FILE_NAME" ] ||
    fatal "${CREDENTIAL_VARIABLE_NAME} names \"${CREDENTIAL_FILE_NAME}\", which is not there" \
      "Mount the secret at that name, or give the value in ${CREDENTIAL_VARIABLE_NAME%_FILE} instead."
  [ -r "$CREDENTIAL_FILE_NAME" ] ||
    fatal "${CREDENTIAL_VARIABLE_NAME} names \"${CREDENTIAL_FILE_NAME}\", which this container cannot read" \
      "Check the mode and the owner of the secret against the user this container runs as."

  # Read with a guard character appended and taken off again : a command
  # substitution drops every trailing newline of what it captures, and a
  # password is entitled to end in one. Exactly one newline is then removed --
  # the one whoever wrote the file ended it with -- and nothing else, a password
  # being just as entitled to leading and trailing spaces
  CREDENTIAL_VALUE=$(cat -- "$CREDENTIAL_FILE_NAME" && printf x) ||
    fatal "${CREDENTIAL_VARIABLE_NAME} names \"${CREDENTIAL_FILE_NAME}\", which could not be read"
  CREDENTIAL_VALUE=${CREDENTIAL_VALUE%x}
  CREDENTIAL_VALUE=${CREDENTIAL_VALUE%"$NEWLINE"}

  [ -n "$CREDENTIAL_VALUE" ] ||
    fatal "${CREDENTIAL_VARIABLE_NAME} names \"${CREDENTIAL_FILE_NAME}\", which is empty" \
      "An empty value is refused here rather than set on the account : an OMSA login with an empty password is worse than a container that did not start."

  printf '%s' "$CREDENTIAL_VALUE"
}

# --- The credentials the container was started with --------------------------

# Read through a default so that "set -u" stops the run on a variable this
# script forgot rather than on one the operator never set : not setting these is
# the normal way somebody runs this image the first time, and it is answered
# below with a message instead of with a shell error
OMSA_username="${OMSA_username:-}"
OMSA_username_FILE="${OMSA_username_FILE:-}"
OMSA_password="${OMSA_password:-}"
OMSA_password_FILE="${OMSA_password_FILE:-}"

# One value, one source. Given both, there is nothing to tell which one the
# operator meant, and guessing is how a container ends up with a password that
# is not the one whoever started it believes they set
if [ -n "$OMSA_username" ] && [ -n "$OMSA_username_FILE" ]; then
  fatal "OMSA_username and OMSA_username_FILE are both set, which is two sources for one value" \
    "Give the account name in one of the two."
fi
if [ -n "$OMSA_password" ] && [ -n "$OMSA_password_FILE" ]; then
  fatal "OMSA_password and OMSA_password_FILE are both set, which is two sources for one value" \
    "Give the password in one of the two."
fi

if [ -n "$OMSA_username_FILE" ]; then
  OMSA_username=$(credential_from_file OMSA_username_FILE "$OMSA_username_FILE" && printf x) || exit 1
  OMSA_username=${OMSA_username%x}
fi
if [ -n "$OMSA_password_FILE" ]; then
  OMSA_password=$(credential_from_file OMSA_password_FILE "$OMSA_password_FILE" && printf x) || exit 1
  OMSA_password=${OMSA_password%x}
fi

# Two tests joined by "||", where this was one test with five operands. POSIX
# marks "-o" obsolescent and leaves the result of a test with more than four
# arguments unspecified, so a value shaped like an operator -- a username of
# "-o", of "=" -- was each shell's business rather than the standard's
if [ -z "$OMSA_username" ] || [ -z "$OMSA_password" ]; then
  fatal "Please specify OMSA_username and OMSA_password env vars, or OMSA_username_FILE and OMSA_password_FILE naming the files that hold them."
fi

# The account name is about to be written into three things that each read it
# their own way : useradd's argument list, the "user:password" line chpasswd
# parses, and the whitespace-separated columns of OMSA's role map. A name
# carrying a colon, a space or a newline means something different in each of
# them, and one beginning with a dash is an option rather than a name.
#
# Refused here, naming the value, rather than left to useradd : useradd's own
# refusal is one line printed after the container has already started doing
# things, in a log somebody only reads once they have noticed the container is
# useless
case "$OMSA_username" in
  -* | *[!A-Za-z0-9._-]*)
    fatal "Invalid OMSA_username \"${OMSA_username}\"" \
      "An account name may hold letters, digits, dots, underscores and dashes, and may not begin with a dash."
    ;;
esac

# --- The account OMSA authenticates against ----------------------------------

# "getent passwd", rather than a grep over /etc/passwd : that file is one source
# of the user database and not the database itself, so an account served by NSS
# -- LDAP, SSSD -- is invisible in it and was created a second time, which the
# real useradd then refuses because as far as the system is concerned the name
# is taken. getent also answers for the exact name it is given, where the grep
# it replaces was case-insensitive and read that name as a regular expression :
# an "OMSAuser" or an "omsa.ser" was taken for an existing "omsauser", and the
# account somebody asked for was never created while chpasswd was handed a name
# no account carried (issue #10).
#
# It answers with status 2 when the key is not there. That is an answer rather
# than a failure, and "|| true" is what keeps "set -e" from reading it as one
OMSA_user_database_entry=$(getent passwd -- "$OMSA_username" || true)

if [ -n "$OMSA_user_database_entry" ]; then
  printf '%s\n' "User \"${OMSA_username}\" already exists, leaving it as it is..."
else
  printf '%s\n' "Creating user \"${OMSA_username}\"..."
  # useradd rather than adduser : "adduser" is a compatibility symbolic link to
  # this one on the EL family and a different program with different options
  # everywhere else, and which base image this is built from is exactly what
  # issues #5 and #9 are about.
  #
  # "--" before the name, although the pattern above has already refused a
  # leading dash : the guard costs one token and it is what keeps the two
  # decisions independent, so that a later widening of that pattern cannot turn
  # a name back into an option
  useradd -- "$OMSA_username" ||
    fatal "Failed to create the user \"${OMSA_username}\"" \
      "OMSA authenticates against that account, so the container would come up with nobody able to log into it."
fi

printf '%s\n' "Setting Dell OMSA credentials for user \"${OMSA_username}\"..."

# printf rather than echo : what echo does with a backslash is left to the
# implementation, and under dash it turns a "\t" into a tab before chpasswd sees
# it, so an account ends up with a password nobody typed. On the standard input
# rather than in an argument, which is why chpasswd is the tool used here at all
# : an argument is readable in "ps" by every process on the machine
printf '%s:%s\n' "$OMSA_username" "$OMSA_password" | chpasswd ||
  fatal "Failed to set the password of \"${OMSA_username}\"" \
    "OMSA would refuse every login, which is a container that starts and answers nothing."

# Taken out of the environment now that it has been used, so that it is not
# inherited by init and by everything systemd starts under it.
#
# This does NOT make it a secret from anybody who can reach the Docker socket :
# the value is still part of the container's configuration and "docker inspect"
# prints it. What this removes is the copy every child process inherits, and the
# one that is read out of a running container's environment
unset OMSA_password

# --- The two files OMSA reads ------------------------------------------------

printf '%s\n' "Allowing \"${OMSA_username}\" user to access Dell OMSA..."
printf '%s    *       Administrator\n' "$OMSA_username" > /opt/dell/srvadmin/etc/omarolemap ||
  fatal "Failed to write OMSA's role map" \
    "Without an entry in it the account authenticates and then sees nothing : the web interface comes up empty and no command works."

printf '%s\n' "Setting up OMSA service..."

# One heredoc rather than three echoes appending to the same file : the three
# could half-succeed, and half an rc.local is a file systemd runs anyway
if ! cat > /etc/rc.local << 'RC_LOCAL'
#!/bin/sh
/opt/dell/srvadmin/sbin/srvadmin-services.sh enable
/opt/dell/srvadmin/sbin/srvadmin-services.sh restart
RC_LOCAL
then
  fatal "Failed to write \"/etc/rc.local\"" \
    "It is the only thing that starts OMSA in this image, so the container would come up with no OMSA running in it."
fi

chmod a+x /etc/rc.local ||
  fatal "Failed to make \"/etc/rc.local\" executable" \
    "rc-local.service is conditional on that bit : without it systemd skips the file without saying so, and OMSA never starts."

# --- What systemd must not try to do in a container --------------------------

# systemd started in a container tries to open virtual terminals it has not got,
# and fails in a loop that fills the container's log.
#
# Deliberately NOT fatal, unlike everything above : the units belong to the base
# image rather than to this repository, a base image that stops shipping them is
# legitimate -- and PR #22 moves this removal into the image -- so their absence
# is tested for rather than refused. A removal that was attempted and refused is
# another matter and says so, because it leaves the failure loop in place
for SYSTEMD_UNIT in /usr/lib/systemd/system/getty@.service /usr/lib/systemd/system/autovt@.service; do
  if [ -e "$SYSTEMD_UNIT" ]; then
    rm -f -- "$SYSTEMD_UNIT" ||
      printf '%s\n' "Failed to remove \"${SYSTEMD_UNIT}\" : systemd will keep trying to open a terminal this container has not got, and the log will fill with it." >&2
  fi
done

# --- The handover ------------------------------------------------------------

printf '%s\n' "Enabling rc.local service..."

# systemd is not up yet -- it is started by the very next line -- so this runs
# against a system manager that is not answering, and its refusals used to be
# ignored for that reason. The cost of ignoring them is the container this image
# exists to avoid : one that comes up, reports itself healthy, and never starts
# OMSA at all
systemctl enable rc-local.service ||
  fatal "Failed to enable rc-local.service" \
    "Nothing would then run \"/etc/rc.local\" at boot, so OMSA would never start and the container would come up answering nothing."

printf '%s\n' "Starting init..."
exec /sbin/init
