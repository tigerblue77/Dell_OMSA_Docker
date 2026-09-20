#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The container takes two parameters and refuses to start without them. That
# refusal is the only configuration check the entrypoint makes, and it is worth
# holding to its contract rather than to its wording : a user who gave neither
# has to be told which variables to set, and the container must not provision
# half an account on the way out.
#
# These cases assert the CONTRACT -- a non-zero status, a message naming the
# variables, nothing written -- rather than the shape of the test that produces
# it. The entrypoint is expected to be rewritten, and a rewrite that reports the
# same refusal through a different mechanism should keep this file green.

# A refused start leaves the machine as it found it. Half a provisioning is
# worse than none : an account created without a password, or a role map naming
# a user that was never created, is a state nobody asked for and nothing cleans
# up
function assert_nothing_was_provisioned() {
  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "a refused start should create no account"
  assert_equals "0" "$(count_calls_matching chpasswd '.')" \
    "a refused start should set no password"
  assert_equals "0" "$(count_calls_matching systemctl '.')" \
    "a refused start should enable no service"
  # The entries of the role map, its own comments dropped : the file is shipped
  # by srvadmin-all and is not empty to start with, so what says nothing was
  # granted is that it holds no entry, not that it holds nothing
  assert_empty "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap | grep -vE '^[[:space:]]*(#|$)')" \
    "a refused start should grant nobody anything in the OMSA role map"
  assert_command_fails "a refused start should not have written rc.local" \
    sandbox_file_exists /etc/rc.local
  assert_command_fails "a refused start should never reach the handover to init" \
    the_entrypoint_reached_init
}

function test_the_container_refuses_to_start_without_a_username() {
  export OMSA_password="hunter2"

  run_entrypoint

  # Non-zero rather than 1 : the contract is that the container stops, and
  # "docker run" reports whatever status it stopped with. It is 1 today
  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a container with no OMSA_username should stop rather than start"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_username" \
    "the refusal should name the variable that was not set"
  assert_nothing_was_provisioned
}

function test_the_container_refuses_to_start_without_a_password() {
  export OMSA_username="omsauser"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a container with no OMSA_password should stop rather than start"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password" \
    "the refusal should name the variable that was not set"
  assert_nothing_was_provisioned
}

function test_the_container_refuses_to_start_without_either_credential() {
  # "docker run" with no "-e" at all, which is how somebody runs this image the
  # first time
  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a container with neither credential should stop rather than start"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_username" \
    "the refusal should name the username variable"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password" \
    "the refusal should name the password variable"
  assert_nothing_was_provisioned
}

function test_an_empty_credential_is_refused_the_way_a_missing_one_is() {
  # 'docker run -e OMSA_username="" -e OMSA_password=""' : the variables are set
  # and carry nothing, which is a different state from unset and the same
  # mistake. A check written on "is it defined" rather than "is it empty" would
  # let this one through and create an account with an empty name
  given_the_credentials "" ""

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "credentials set to the empty string should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_username" \
    "the refusal should name the variables, whether they were unset or emptied"
  assert_nothing_was_provisioned
}

function test_an_empty_password_alone_is_refused() {
  # The half of the previous case that a "both or neither" check would miss
  given_the_credentials "omsauser" ""

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "an empty OMSA_password should stop the container"
  assert_nothing_was_provisioned
}

function test_both_credentials_given_start_the_provisioning() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a container given both credentials should start"
  assert_command_succeeds "and should reach its handover to init" the_entrypoint_reached_init
  assert_not_contains "$ENTRYPOINT_OUTPUT" "Please specify" \
    "a container given both credentials should not be told to specify them"
}

function test_the_refusal_is_a_message_rather_than_a_silent_exit() {
  # A container that stops with an empty log is a container whose user goes
  # reading the image's source. Whatever the refusal ends up saying, it has to
  # say something, and it has to be visible in "docker logs" -- which shows both
  # streams, so this case does not care which one it goes to
  run_entrypoint

  assert_not_empty "$ENTRYPOINT_OUTPUT" \
    "a container refusing to start should say why"
  assert_matches "$ENTRYPOINT_OUTPUT" 'OMSA_username.*OMSA_password|OMSA_password.*OMSA_username' \
    "the refusal should name both variables, a user who set neither having no way to guess"
}

function test_only_an_empty_credential_is_refused() {
  # The refusal is written as "[ "" = "$a" -o "" = "$b" ]", a single test with
  # five operands. POSIX marks -o obsolescent and leaves the result of a test
  # with more than four arguments unspecified : what a value shaped like an
  # operator does there is the implementation's business, not the standard's, so
  # a username of "=" or "-o" is a question each shell answers for itself.
  #
  # Measured here rather than assumed. On the shells this suite can reach, all
  # of these start the container, which is the correct answer -- they are
  # unusual usernames, not missing ones. The case pins that contract so that the
  # rewrite to "[ -z "$a" ] || [ -z "$b" ]" a later pull request will make is
  # held to the same answer instead of being taken on trust
  local CREDENTIAL
  for CREDENTIAL in "=" "-o" "!" "(" ")" "-n" "-z"; do
    setup_test_context
    given_the_credentials "$CREDENTIAL" "hunter2"

    run_entrypoint

    assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
      "a username of \"$CREDENTIAL\" is unusual, not missing : the container should start"

    setup_test_context
    given_the_credentials "omsauser" "$CREDENTIAL"

    run_entrypoint

    assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
      "a password of \"$CREDENTIAL\" is unusual, not missing : the container should start"
  done
}
