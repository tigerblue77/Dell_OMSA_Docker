#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# omarolemap is the file OMSA reads to decide what a logged-in user may do.
# Without an entry in it, the account the entrypoint just created authenticates
# and then sees nothing : the web interface comes up empty and no command works.
# It is the one file in this image whose content is a permission.

# The role map's own line format : a user, the hosts it applies to, and the
# right granted. Read tolerantly on purpose -- the separator is whitespace and
# how much of it there is carries no meaning
readonly ROLE_MAP_LINE_PATTERN='^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$'

# The role map's entries, blank lines and comments dropped
function role_map_entries() {
  sandbox_file_content /opt/dell/srvadmin/etc/omarolemap | grep -vE '^[[:space:]]*(#|$)' || true
}

function test_the_role_map_grants_the_requested_user_administrator() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  local -r ENTRIES="$(role_map_entries)"

  assert_not_empty "$ENTRIES" "the role map should hold an entry once the container has started" || return 1
  assert_matches "$ENTRIES" "$ROLE_MAP_LINE_PATTERN" \
    "the entry should be a user, a host scope and a right"
  assert_matches "$ENTRIES" '^omsauser[[:space:]]' \
    "the entry should name the account the container was given"
  assert_matches "$ENTRIES" '[[:space:]]Administrator[[:space:]]*$' \
    "and should grant it Administrator, which is what makes the image usable at all"
}

function test_the_role_map_grants_the_right_on_every_host() {
  # The middle field is the host the entry applies to. A container manages the
  # one machine it is privileged on, and it does not know that machine's name
  # until it runs, so the entry is written for every host rather than for a name
  # the image would have to guess
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  local -r ENTRY="$(role_map_entries)"
  local -r HOST_SCOPE="$(printf '%s' "$ENTRY" | awk '{ print $2 }')"

  assert_equals "*" "$HOST_SCOPE" \
    "the entry should apply to every host, the container not knowing its own name"
}

function test_the_role_map_names_the_account_that_was_asked_for() {
  # The account and the role map are written from the same variable, and an
  # entry naming a user that does not exist grants nothing at all. This is the
  # pair that has to agree, whatever the username looks like
  given_the_credentials "an.unusual-user_1" "hunter2"

  run_entrypoint

  assert_matches "$(role_map_entries)" '^an\.unusual-user_1[[:space:]]' \
    "the role map should name the account the container was given, verbatim"
  assert_equals "1" "$(count_calls_matching adduser '^adduser an\.unusual-user_1$')" \
    "and that same name should be the one the account was created under"
}

function test_the_role_map_holds_one_entry_after_a_restart() {
  # The container is restarted far more often than it is created, and the role
  # map is written with ">" rather than ">>" for exactly this reason : appending
  # would add a line per start, and the file would grow for as long as the
  # container is used
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint
  run_entrypoint
  run_entrypoint

  assert_equals "1" "$(role_map_entries | wc -l | tr -d ' ')" \
    "three starts should leave one entry, not three"
}

function test_a_restart_under_another_username_leaves_only_that_user() {
  # Changing OMSA_username and restarting is how somebody renames the account
  # they log in with. The old entry has to go with it : left behind, it keeps
  # granting Administrator to an account nobody is watching any more
  given_the_credentials "firstuser" "hunter2"
  run_entrypoint

  given_the_credentials "seconduser" "hunter2"
  run_entrypoint

  local -r ENTRIES="$(role_map_entries)"

  assert_matches "$ENTRIES" '^seconduser[[:space:]]' \
    "the role map should name the account the container was last started with"
  assert_not_contains "$ENTRIES" "firstuser" \
    "and should no longer grant anything to the previous one"
}

function test_the_role_map_shipped_with_omsa_is_replaced_rather_than_amended() {
  # Documented rather than judged : srvadmin-all installs its own omarolemap,
  # and the entrypoint overwrites it whole. Anything that file held -- the
  # comments describing the format, and any entry an operator added by hand
  # inside a running container -- is gone at the next start.
  #
  # For a container whose user database is created from scratch on every start
  # that is defensible, and it is what makes the case above hold. It is written
  # down here because it is the kind of behaviour a rewrite changes by accident,
  # by moving from ">" to ">>" to "fix" something else
  given_the_credentials "omsauser" "hunter2"

  # The file as srvadmin-all ships it, with a comment and an entry of its own
  printf '%s\n' '# Dell OpenManage Server Administrator role map' 'someoneelse * Administrator' \
    > "$(sandbox_path /opt/dell/srvadmin/etc/omarolemap)"

  run_entrypoint

  assert_not_contains "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap)" "someoneelse" \
    "the entries the file already held are replaced, not kept"
  assert_not_contains "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap)" "Dell OpenManage Server Administrator role map" \
    "and so is the comment the package shipped"
  assert_matches "$(role_map_entries)" '^omsauser[[:space:]]' \
    "what remains is the entry this container was started for"
}

function test_the_role_map_is_written_before_the_handover_to_init() {
  # OMSA's services are started by rc.local, which systemd runs after the
  # entrypoint has handed the machine over. A role map written after that point
  # would be read too late by whatever started first
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_not_empty "$(role_map_entries)" "the role map should be written"
  assert_command_succeeds "and the entrypoint should have reached init afterwards" \
    the_entrypoint_reached_init
}
