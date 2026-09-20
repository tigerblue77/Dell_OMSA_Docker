#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The container runs a full systemd, and systemd started in a container tries to
# do what it does on a machine -- including opening virtual terminals it has
# not got. getty@.service and autovt@.service are removed before the handover
# for that reason : left in place they fail in a loop, and the container's log
# fills with them.
#
# The removal has to hold in both directions. The units are there in the base
# image today ; they are not part of this repository, and a base image that
# stops shipping them must not turn into a container that refuses to start.

function unit_path() {
  printf '%s' "/usr/lib/systemd/system/$1"
}

function test_the_terminal_units_are_removed_when_the_image_ships_them() {
  given_the_credentials "omsauser" "hunter2"

  # The sandbox starts with both of them, the way the base image does
  assert_command_succeeds "the sandbox should start with getty@.service" \
    sandbox_file_exists "$(unit_path 'getty@.service')" || return 1

  run_entrypoint

  assert_command_fails "getty@.service should be gone" \
    sandbox_file_exists "$(unit_path 'getty@.service')"
  assert_command_fails "autovt@.service should be gone" \
    sandbox_file_exists "$(unit_path 'autovt@.service')"
  assert_not_equals "0" "$(count_calls_matching rm 'getty@\.service')" \
    "and the entrypoint should be what removed them"
  assert_not_equals "0" "$(count_calls_matching rm 'autovt@\.service')" \
    "both of them"
}

function test_the_absence_of_the_terminal_units_is_not_an_error() {
  # A base image that does not ship them, or a container restarted on a
  # filesystem where a previous run already removed them. Neither is a mistake,
  # and the entrypoint tests for the file before removing it for exactly this
  # reason
  given_the_systemd_units_are_absent
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "units that are not there should not stop the container"
  assert_command_succeeds "and the handover should happen as usual" \
    the_entrypoint_reached_init
  assert_equals "0" "$(count_calls_matching rm '.')" \
    "nothing should be removed when there is nothing to remove"
}

function test_a_restart_removes_nothing_the_first_start_left() {
  # The restart case, read from the other end : the second run finds what the
  # first one left and has to be as quiet about it
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint
  forget_recorded_calls rm

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" "a second start should succeed too"
  assert_equals "0" "$(count_calls_matching rm '.')" \
    "and should have nothing left to remove"
}

function test_the_removal_leaves_the_other_units_alone() {
  # Two named units, not a sweep : the unit directory is the base image's and
  # holds everything systemd needs to boot. A removal widened by accident --
  # a glob, a directory instead of a file -- is the kind of change that still
  # passes every other case in this suite
  given_the_credentials "omsauser" "hunter2"

  local -r UNIT_DIRECTORY="$(sandbox_path /usr/lib/systemd/system)"
  local NEIGHBOUR
  for NEIGHBOUR in sshd.service dbus.service multi-user.target rc-local.service; do
    printf '%s\n' '[Unit]' "Description=$NEIGHBOUR" > "$UNIT_DIRECTORY/$NEIGHBOUR"
  done

  run_entrypoint

  for NEIGHBOUR in sshd.service dbus.service multi-user.target rc-local.service; do
    assert_command_succeeds "$NEIGHBOUR should still be there" \
      test -f "$UNIT_DIRECTORY/$NEIGHBOUR"
  done

  assert_command_succeeds "and the unit directory itself should still be a directory" \
    test -d "$UNIT_DIRECTORY"
}

function test_a_refused_removal_does_not_stop_the_container() {
  # Documented rather than judged, like the refused "systemctl enable" in
  # tests/cases/50_service_handover.sh : the removal's failure is ignored and
  # the container starts anyway. The consequence is a log full of getty failures
  # rather than a container that does not come up, which is arguably the right
  # trade -- but it is a choice, and nothing in the script says it was made on
  # purpose
  given_the_credentials "omsauser" "hunter2"
  export MOCK_RM_EXIT_CODE=1

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a removal that failed does not stop the container today"
  assert_command_succeeds "and the handover happens anyway" the_entrypoint_reached_init
  assert_command_succeeds "the unit is still there, which is what the refusal means" \
    sandbox_file_exists "$(unit_path 'getty@.service')"
}

function test_the_units_are_removed_before_the_handover() {
  # systemd reads its unit files when it starts, and it starts at the handover.
  # A removal happening after that point would be a removal systemd has already
  # read past
  given_the_credentials "omsauser" "hunter2"
  export MOCK_INIT_EXIT_CODE=42

  run_entrypoint

  assert_equals "42" "$ENTRYPOINT_EXIT_CODE" "init should be what ends the run" || return 1
  assert_command_fails "and the units should already be gone by then" \
    sandbox_file_exists "$(unit_path 'getty@.service')"
}
