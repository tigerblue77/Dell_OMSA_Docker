#!/bin/bash
#
# The sandbox the entrypoint is run inside, the mocks it talks to, and the
# assertions the cases use.
#
# run.sh writes to absolute paths -- /opt/dell/srvadmin/etc, /sbin/init, /tmp --
# and a test run must not touch any of them on the machine it runs on. Rather
# than asking the script to carry a root prefix it would only ever need for the
# tests, the harness copies it and rewrites those paths into a temporary
# directory. That is the one compromise in here, and it is worth naming: the
# suite tests the script's logic, not the filesystem layout of the image. What
# the image lays out is the Dockerfile's business and the build's to prove.

# Written by the mocks, read by the assertions.
export SANDBOX MOCK_EXISTING_USERS MOCK_CALLS MOCK_CHPASSWD_STDIN
# Set by a case before calling run_entrypoint, read by the mocks.
export MOCK_ADDUSER_EXIT MOCK_CHPASSWD_EXIT

ENTRYPOINT_SOURCE="${ENTRYPOINT_SOURCE:-docker/run.sh}"

# One per test case. Everything a case writes lands in here and nowhere else.
function make_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/opt/dell/srvadmin/etc/srvadmin-storage" \
           "$SANDBOX/sbin" "$SANDBOX/bin" "$SANDBOX/tmp" "$SANDBOX/var/tmp"

  MOCK_EXISTING_USERS="$SANDBOX/passwd"
  MOCK_CALLS="$SANDBOX/calls"
  MOCK_CHPASSWD_STDIN="$SANDBOX/chpasswd.stdin"
  : > "$MOCK_EXISTING_USERS"
  : > "$MOCK_CALLS"
  : > "$MOCK_CHPASSWD_STDIN"
  MOCK_ADDUSER_EXIT=0
  MOCK_CHPASSWD_EXIT=0

  # The file run.sh edits with sed. A real image has it from srvadmin-storage.
  printf 'NonDellCertifiedFlag=yes\n' \
    > "$SANDBOX/opt/dell/srvadmin/etc/srvadmin-storage/stsvc.ini"

  write_mocks
  install_entrypoint
}

function destroy_sandbox() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# getent and adduser honour "--" exactly as the real ones do, because that is
# the behaviour half these cases are about. Everything they are asked is
# recorded, so a case can assert on what was called rather than only on what
# was left behind.
function write_mocks() {
  cat > "$SANDBOX/bin/getent" <<'MOCK'
#!/bin/sh
printf 'getent %s\n' "$*" >> "$MOCK_CALLS"
[ "$1" = passwd ] || exit 2
shift
case "$1" in
  --) shift ;;
  -*) echo "getent: invalid option -- '${1#-}'" >&2; exit 64 ;;
esac
grep -qx -- "$1" "$MOCK_EXISTING_USERS" 2>/dev/null || exit 2
printf '%s:x:1000:1000::/home/%s:/bin/sh\n' "$1" "$1"
MOCK

  cat > "$SANDBOX/bin/adduser" <<'MOCK'
#!/bin/sh
printf 'adduser %s\n' "$*" >> "$MOCK_CALLS"
case "$1" in
  --) shift ;;
  -*) echo "adduser: invalid option -- '${1#-}'" >&2; exit 2 ;;
esac
[ "${MOCK_ADDUSER_EXIT:-0}" = 0 ] || { echo "adduser: refused" >&2; exit "$MOCK_ADDUSER_EXIT"; }
printf '%s\n' "$1" >> "$MOCK_EXISTING_USERS"
MOCK

  cat > "$SANDBOX/bin/chpasswd" <<'MOCK'
#!/bin/sh
printf 'chpasswd\n' >> "$MOCK_CALLS"
cat >> "$MOCK_CHPASSWD_STDIN"
[ "${MOCK_CHPASSWD_EXIT:-0}" = 0 ] || { echo "chpasswd: failed" >&2; exit "$MOCK_CHPASSWD_EXIT"; }
MOCK

  # Deterministic, so a case can assert on the first line of output.
  cat > "$SANDBOX/bin/date" <<'MOCK'
#!/bin/sh
echo "MOCKED-DATE"
MOCK

  # Stands in for systemd. Reaching it is the whole question in several cases,
  # so it says so and stops rather than execing anything.
  cat > "$SANDBOX/sbin/init" <<'MOCK'
#!/bin/sh
echo "INIT REACHED"
MOCK

  chmod +x "$SANDBOX"/bin/* "$SANDBOX/sbin/init"
}

# The copy under test, with its absolute paths pointed at the sandbox.
#
# A rewrite that silently matches nothing is the dangerous failure here, not a
# failing test : the copy is executed, so an unrewritten `rm -Rf /tmp/*
# /var/tmp/*` runs against the machine hosting the suite. sed reports no error
# for a pattern that matches nothing, and the third expression below matches one
# exact literal -- reorder its two arguments upstream, or write `-rf` instead of
# `-Rf`, and it quietly stops applying. So the copy is checked before anything
# runs it, and a check that fails stops the suite rather than guessing.
#
# The checks are a guard, not a sandbox. Running the entrypoint under a chroot or
# inside a container would remove the need to rewrite anything at all, and is the
# right answer if this harness ever has to cover more than one script.
function install_entrypoint() {
  sed -e "s#/opt/dell#$SANDBOX/opt/dell#g" \
      -e "s#/sbin/init#$SANDBOX/sbin/init#g" \
      -e "s#rm -Rf /tmp/\* /var/tmp/\*#rm -Rf $SANDBOX/tmp/* $SANDBOX/var/tmp/*#" \
      "$ENTRYPOINT_SOURCE" > "$SANDBOX/run.sh"
  chmod +x "$SANDBOX/run.sh"

  # Every rewrite this function is responsible for has to have landed. A check
  # that fails records a failure and takes the copy away rather than calling
  # exit : a case runs inside a command substitution, so an exit there leaves
  # only that subshell, the counts never come back, and the run reports the case
  # as ok. Refusing loudly has to go through the same bookkeeping as an
  # assertion or it is not refusing at all.
  local REPLACEMENT
  for REPLACEMENT in "$SANDBOX/opt/dell" "$SANDBOX/sbin/init" "rm -Rf $SANDBOX/tmp/"; do
    if ! grep -qF -- "$REPLACEMENT" "$SANDBOX/run.sh"; then
      rm -f "$SANDBOX/run.sh"
      printf 'harness: no rewrite produced "%s" -- refusing to run the copy.\n' "$REPLACEMENT" >&2
      ASSERTIONS=$((ASSERTIONS + 1))
      _fail "the harness produced no rewrite for \"$REPLACEMENT\" : $ENTRYPOINT_SOURCE has changed shape and install_entrypoint() no longer matches it"
      return 1
    fi
  done

  # And nothing the copy deletes may sit outside the sandbox -- which catches a
  # destructive line the rewrites above do not know about yet, not just the one
  # they were written for.
  local STRAY
  STRAY="$(grep -nE '(^|[[:space:];&|(])rm([[:space:]]|$)' "$SANDBOX/run.sh" | grep -vF -- "$SANDBOX" || true)"
  if [ -n "$STRAY" ]; then
    rm -f "$SANDBOX/run.sh"
    printf 'harness: the copy would delete outside the sandbox -- refusing to run it.\n' >&2
    ASSERTIONS=$((ASSERTIONS + 1))
    _fail "the copy would delete outside the sandbox : ${STRAY//$'\n'/ ; }"
    return 1
  fi
}

# Runs the entrypoint. Its exit status lands in ENTRYPOINT_STATUS and its
# combined output in ENTRYPOINT_OUTPUT, so a case can assert on either without
# the run itself deciding whether the case continues.
function run_entrypoint() {
  # install_entrypoint() deletes the copy when a rewrite did not land, so its
  # absence here means the guard already refused and said why.
  if [ ! -f "$SANDBOX/run.sh" ]; then
    # The case carries on against these rather than reading an unset variable :
    # under `set -u` that would kill the case's shell, and the reason recorded
    # above would die with it.
    ENTRYPOINT_OUTPUT=''
    ENTRYPOINT_STATUS=127
    export ENTRYPOINT_OUTPUT ENTRYPOINT_STATUS
    ASSERTIONS=$((ASSERTIONS + 1))
    _fail "the entrypoint was never installed, so there was nothing to run"
    return 1
  fi

  ENTRYPOINT_OUTPUT="$(PATH="$SANDBOX/bin:$PATH" sh "$SANDBOX/run.sh" 2>&1)"
  ENTRYPOINT_STATUS=$?
  export ENTRYPOINT_OUTPUT ENTRYPOINT_STATUS
}

function existing_user() { printf '%s\n' "$1" >> "$MOCK_EXISTING_USERS"; }

# Writes a credential file inside the sandbox and prints its path, so a case can
# say what is in it without caring where it lives. The content is written as
# given : a case that wants a trailing newline asks for one.
function secret_file() {
  local PATH_TO="$SANDBOX/secret-$1"
  printf '%s' "$2" > "$PATH_TO"
  chmod 600 "$PATH_TO"
  printf '%s' "$PATH_TO"
}
function role_map() { cat "$SANDBOX/opt/dell/srvadmin/etc/omarolemap" 2>/dev/null; }
function storage_ini() { cat "$SANDBOX/opt/dell/srvadmin/etc/srvadmin-storage/stsvc.ini"; }
function calls_matching() { grep -c -- "$1" "$MOCK_CALLS" 2>/dev/null || true; }

# ---------------------------------------------------------------- assertions
#
# They record and carry on rather than stopping the case, so one run reports
# every failure it found instead of only the first. Where the rest of a case
# cannot run after one, write "assert_... || return 1".

ASSERTIONS=0
FAILURES=()

function _fail() { FAILURES+=("$1"); return 1; }

function assert_equals() {
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$1" = "$2" ] && return 0
  _fail "${3:-value} : expected [$1], got [$2]"
}

function assert_contains() {
  ASSERTIONS=$((ASSERTIONS + 1))
  case "$2" in *"$1"*) return 0 ;; esac
  _fail "${3:-output} : expected to contain [$1], got [$2]"
}

function assert_not_contains() {
  ASSERTIONS=$((ASSERTIONS + 1))
  case "$2" in *"$1"*) _fail "${3:-output} : expected NOT to contain [$1]"; return 1 ;; esac
  return 0
}

function assert_file_absent() {
  ASSERTIONS=$((ASSERTIONS + 1))
  [ ! -e "$1" ] && return 0
  _fail "${2:-file} : expected [$1] not to exist"
}
