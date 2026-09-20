#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# What makes the container a running OMSA rather than a provisioned one. The
# entrypoint does not start OMSA itself : it writes the commands into
# /etc/rc.local, enables the unit that runs rc.local, and hands the machine over
# to systemd, which does the starting. Three links, and the chain is only worth
# anything whole -- rc.local written but not executable, or executable but with
# its unit disabled, is a container that comes up with nothing listening and
# nothing in its log to say so.

function rc_local_content() {
  sandbox_file_content /etc/rc.local
}

function test_rc_local_starts_the_omsa_services() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  local -r CONTENT="$(rc_local_content)"

  assert_not_empty "$CONTENT" "rc.local should be written" || return 1
  assert_contains "$CONTENT" "srvadmin-services.sh" \
    "rc.local should run OMSA's own service script"
  assert_matches "$CONTENT" 'srvadmin-services\.sh[[:space:]]+enable' \
    "it should enable the OMSA services"
  # "restart" rather than "start" : on a service that is not running, restart
  # starts it, and on one that is, it picks up whatever the enable just changed
  assert_matches "$CONTENT" 'srvadmin-services\.sh[[:space:]]+restart' \
    "and it should start them"
}

function test_rc_local_calls_the_service_script_where_omsa_installs_it() {
  # An absolute path on purpose : rc.local is run by systemd, whose PATH is not
  # the one the Dockerfile extends, so a bare "srvadmin-services.sh" would not
  # be found. This is also the one path of the entrypoint the test sandbox
  # deliberately does NOT rewrite -- it is text written into a file rather than
  # something the entrypoint runs, and rewriting it would have this case assert
  # against a path the test itself invented
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_contains "$(rc_local_content)" "/opt/dell/srvadmin/sbin/srvadmin-services.sh" \
    "rc.local should name the service script by the absolute path OMSA installs it at"
}

function test_rc_local_declares_a_shell() {
  # systemd's rc-local.service runs the file directly, so it needs a shebang :
  # without one, the unit fails and nothing starts OMSA
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_matches "$(rc_local_content)" '^#!/' \
    "rc.local should open with a shebang, being executed rather than sourced"
}

function test_rc_local_is_made_executable() {
  # rc-local.service is "ConditionFileIsExecutable=/etc/rc.local" : a file
  # without the bit is not an error, it is a unit that never runs and never
  # complains
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_command_succeeds "rc.local should be executable" \
    test -x "$(sandbox_path /etc/rc.local)"
  assert_not_equals "0" "$(count_calls_matching chmod 'rc\.local')" \
    "and the entrypoint should be the one that made it so"
}

function test_the_rc_local_unit_is_enabled() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_not_equals "0" "$(count_calls_matching systemctl 'enable.*rc-local')" \
    "the unit that runs rc.local should be enabled, or systemd never reads the file"
}

function test_the_entrypoint_hands_the_machine_over_to_init() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_command_succeeds "the entrypoint should end by starting init" \
    the_entrypoint_reached_init
  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "and should report what init reported"
}

function test_the_handover_replaces_the_entrypoint_rather_than_calling_it() {
  # "exec /sbin/init" is what makes systemd PID 1 in the container. Called
  # instead of exec'd, systemd would run as a child of a shell that is not
  # reaping anything, "docker stop" would signal the shell rather than systemd,
  # and the container would be killed on its timeout at every stop.
  #
  # Two observable consequences of the exec, either of which a plain call would
  # break : nothing of the entrypoint runs after it, and the status the
  # container reports is init's own
  given_the_credentials "omsauser" "hunter2"
  export MOCK_INIT_OUTPUT="the init of this machine is now running"
  export MOCK_INIT_EXIT_CODE=42

  run_entrypoint

  assert_equals "42" "$ENTRYPOINT_EXIT_CODE" \
    "the container's status should be init's own, which is what exec makes it"

  local -r LAST_LINE="$(printf '%s\n' "$ENTRYPOINT_STDOUT" | tail -1)"
  assert_equals "$MOCK_INIT_OUTPUT" "$LAST_LINE" \
    "nothing of the entrypoint should run after the handover"
}

function test_the_provisioning_is_complete_before_the_handover() {
  # init is the last line of the entrypoint, so everything this run can observe
  # was necessarily done before it. What this case is for is the reverse : a
  # rewrite that starts init early -- in the background, or from a wrapper --
  # and leaves the provisioning racing against the services that depend on it
  given_the_credentials "omsauser" "hunter2"
  export MOCK_INIT_EXIT_CODE=42

  run_entrypoint

  assert_equals "42" "$ENTRYPOINT_EXIT_CODE" "init should be what ends the run" || return 1
  assert_equals "1" "$(count_calls_matching chpasswd '.')" \
    "the password should have been set before the handover"
  assert_not_empty "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap)" \
    "the role map should have been written before the handover"
  assert_not_empty "$(rc_local_content)" \
    "and rc.local too"
}

function test_a_refused_service_enable_stops_the_container() {
  # CHANGED by the entrypoint rewrite for issues #10 and #11. systemctl runs
  # while systemd is not up yet -- it is started by the very next line -- so its
  # refusals were expected, and the entrypoint ignored them : the container
  # started, and the failure was one line in a log.
  #
  # The cost of that was the exact container this image exists to avoid. An
  # "enable" that did not take leaves a container that comes up, reports itself
  # healthy, answers nothing and has no OMSA in it, which is a far harder thing
  # to diagnose than a container that refused to start. It is fatal now, and the
  # message says what carrying on would have meant
  given_the_credentials "omsauser" "hunter2"
  export MOCK_SYSTEMCTL_EXIT_CODE=1

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a refused enable should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "rc-local.service" \
    "and should say which unit it could not enable"
  assert_command_fails "the handover should not happen on top of it" \
    the_entrypoint_reached_init
}

function test_an_rc_local_that_cannot_be_written_stops_the_container() {
  # The three links of the chain are only worth anything whole, and this is what
  # issue #10 costs at the first of them : the write was not checked, so a
  # container whose rc.local never got written came up with nothing starting
  # OMSA and nothing in the log to say why.
  #
  # Made to fail with a directory in the file's place, which is also what a
  # "-v /etc/rc.local:/etc/rc.local" typed against a path that does not exist
  # leaves behind on the host
  given_the_credentials "omsauser" "hunter2"
  command -p mkdir -p "$(sandbox_path /etc/rc.local)"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "an rc.local that could not be written should stop the container"
  assert_not_empty "$ENTRYPOINT_OUTPUT" \
    "and should say so rather than stopping silently"
  assert_equals "0" "$(count_calls_matching systemctl '.')" \
    "nothing should go on to enable the unit that would have run it"
  assert_command_fails "and the handover should not happen on top of it" \
    the_entrypoint_reached_init
}

function test_an_rc_local_that_cannot_be_made_executable_stops_the_container() {
  # rc-local.service is "ConditionFileIsExecutable=/etc/rc.local" : a file
  # without the bit is not an error, it is a unit that never runs and never
  # complains. A chmod that did not take is therefore invisible in every log the
  # container writes, which is exactly the shape of failure issue #10 is about
  given_the_credentials "omsauser" "hunter2"
  export MOCK_CHMOD_EXIT_CODE=1

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "an rc.local that could not be made executable should stop the container"
  assert_not_empty "$ENTRYPOINT_OUTPUT" \
    "and should say so rather than stopping silently"
  assert_command_fails "the handover should not happen on top of it" \
    the_entrypoint_reached_init
}
