#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The container takes two parameters and refuses to start without them. That
# refusal is worth holding to its contract rather than to its wording : a user
# who gave neither has to be told which variables to set, and the container must
# not provision half an account on the way out.
#
# These cases assert the CONTRACT -- a non-zero status, a message naming the
# variables, nothing written -- rather than the shape of the test that produces
# it. The entrypoint was rewritten for issues #10 and #11 after this file was
# written, and reporting the same refusals through an entirely different
# mechanism is what it did : all but one of these cases carried across unchanged.
#
# Since that rewrite each value may also arrive in a file rather than in the
# environment -- OMSA_username_FILE, OMSA_password_FILE -- which is how Docker
# Swarm and Compose hand a secret to a container, and what issue #11 asked for.
# A file brings refusals of its own, and they are here too : a file that is not
# there, one that is empty, and a value given twice over.

# A refused start leaves the machine as it found it. Half a provisioning is
# worse than none : an account created without a password, or a role map naming
# a user that was never created, is a state nobody asked for and nothing cleans
# up
function assert_nothing_was_provisioned() {
  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "a refused start should create no account"
  # useradd is what the entrypoint calls since the rewrite for issues #10 and
  # #11, and adduser stays asserted beside it rather than being replaced by it :
  # the two are the same account on the machine, so a refused start has to have
  # reached neither
  assert_equals "0" "$(count_calls_matching useradd '.')" \
    "whichever of the two account tools it calls"
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

function test_a_credential_shaped_like_a_test_operator_is_never_taken_for_a_missing_one() {
  # The refusal used to be written as "[ "" = "$a" -o "" = "$b" ]", a single
  # test with five operands. POSIX marks -o obsolescent and leaves the result of
  # a test with more than four arguments unspecified : what a value shaped like
  # an operator does there is the implementation's business, not the standard's,
  # so a username of "=" or "-o" was a question each shell answered for itself.
  #
  # The rewrite for issues #10 and #11 made it two tests joined by "||", and
  # this case moved with it rather than being deleted, because the two halves of
  # it now answer differently and neither answer is "the variable was not set" :
  #
  #   as a password, such a value is merely unusual and the container starts ;
  #   as a username it is refused by the pattern an account name has to match
  #   before it reaches useradd -- with a message naming the value, which is
  #   exactly what tells that refusal apart from the refusal of a credential
  #   that is missing.
  #
  # Both are pinned, because a five-operand test made them the same question and
  # the point of this case is that they are not
  local CREDENTIAL
  for CREDENTIAL in "=" "-o" "!" "(" ")" "-n" "-z"; do
    setup_test_context
    given_the_credentials "$CREDENTIAL" "hunter2"

    run_entrypoint

    assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
      "a username of \"$CREDENTIAL\" is not a name this image will create an account under"
    assert_contains "$ENTRYPOINT_OUTPUT" "$CREDENTIAL" \
      "and the refusal should name the value it refused"
    assert_not_contains "$ENTRYPOINT_OUTPUT" "Please specify" \
      "a username of \"$CREDENTIAL\" is invalid, never missing : it was given"

    setup_test_context
    given_the_credentials "omsauser" "$CREDENTIAL"

    run_entrypoint

    assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
      "a password of \"$CREDENTIAL\" is unusual, not missing : the container should start"
  done
}

# A credential mounted as a file, the way Docker Swarm and Compose hand a secret
# to a container : the value is written into a file under the sandbox root, and
# the variable the entrypoint reads holds that file's name rather than the value
# itself. Written with one trailing newline, which is what every editor and
# every "echo > file" leaves behind and what the entrypoint is expected to strip
# Usage : given_the_password_is_in_a_file "hunter2"
function given_the_password_is_in_a_file() {
  local -r SECRET_FILE="$TEST_ROOT/run/omsa_password"

  printf '%s\n' "$1" > "$SECRET_FILE"
  export OMSA_password_FILE="$SECRET_FILE"
}

# Usage : given_the_username_is_in_a_file "omsauser"
function given_the_username_is_in_a_file() {
  local -r SECRET_FILE="$TEST_ROOT/run/omsa_username"

  printf '%s\n' "$1" > "$SECRET_FILE"
  export OMSA_username_FILE="$SECRET_FILE"
}

function test_a_password_given_in_a_file_is_read_from_it() {
  # The whole of issue #11 : a password given in the environment is in the
  # container's configuration, which "docker inspect" prints and which anybody
  # debugging a container pastes into an issue. Given in a file, it is a file
  export OMSA_username="omsauser"
  given_the_password_is_in_a_file "hunter2"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password mounted as a file should start the container"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:hunter2" \
    "and should reach chpasswd, with the trailing newline the file was written with stripped"
  assert_not_contains "$ENTRYPOINT_OUTPUT" "hunter2" \
    "without being printed on the way"
}

function test_a_username_given_in_a_file_is_read_from_it() {
  # The username has no secret to keep and takes a file for symmetry : a
  # deployment that mounts one of the two and exports the other is a deployment
  # describing the same account in two different ways
  given_the_username_is_in_a_file "omsauser"
  export OMSA_password="hunter2"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a username mounted as a file should start the container"
  assert_equals "1" "$(count_calls_matching useradd '^useradd -- omsauser$')" \
    "the account should be created under the name the file holds"
  assert_matches "$(sandbox_file_content /opt/dell/srvadmin/etc/omarolemap)" '^omsauser[[:space:]]' \
    "and the role map should name it too"
}

function test_a_password_file_that_is_not_there_stops_the_container() {
  # The secret that was not mounted, which is what a typo in a Compose file
  # produces. Refused rather than read as an empty password : an OMSA account
  # whose password is the empty string is worse than a container that did not
  # start, and only one of the two is noticed
  export OMSA_username="omsauser"
  export OMSA_password_FILE="$TEST_ROOT/run/a_secret_nobody_mounted"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password file that is not there should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password_FILE" \
    "the refusal should name the variable"
  assert_contains "$ENTRYPOINT_OUTPUT" "a_secret_nobody_mounted" \
    "and the file it was pointed at, which is where the typo is"
  assert_nothing_was_provisioned
}

function test_an_empty_password_file_stops_the_container() {
  # Both shapes of empty, because they are two different files : one holding
  # nothing at all, and one holding the newline an editor adds. The second is
  # the one a script produces, and stripping that newline is what makes it empty
  export OMSA_username="omsauser"
  given_the_password_is_in_a_file ""

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password file holding a single newline should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password_FILE" \
    "and the refusal should name the variable"
  # The file, not only the variable : an empty value would be refused further
  # down anyway, by the check that answers a credential nobody gave, and that
  # one has nothing to say about which file it came out of. Naming it is what
  # tells somebody where to look, and it is what says the refusal came from the
  # check written for this
  assert_contains "$ENTRYPOINT_OUTPUT" "omsa_password" \
    "and the file it read, which is the thing that has to be fixed"
  assert_nothing_was_provisioned

  setup_test_context
  export OMSA_username="omsauser"
  export OMSA_password_FILE="$TEST_ROOT/run/omsa_password"
  : > "$OMSA_password_FILE"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password file holding nothing at all should stop it too"
  assert_contains "$ENTRYPOINT_OUTPUT" "omsa_password" \
    "naming the file the same way"
  assert_nothing_was_provisioned
}

function test_a_password_given_both_ways_stops_the_container() {
  # Two sources for one value, and no way to tell which one was meant. Guessing
  # is how a container ends up with a password that is not the one whoever
  # started it believes they set -- and nothing about that fails loudly : the
  # login simply does not work, months later, for somebody else
  given_the_credentials "omsauser" "hunter2"
  given_the_password_is_in_a_file "hunter2-but-from-the-file"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password given in both places should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password" \
    "the refusal should name the variable"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password_FILE" \
    "and the file variable beside it, the point being that both are set"
  assert_not_contains "$ENTRYPOINT_OUTPUT" "hunter2" \
    "while printing neither of the two values"
  assert_nothing_was_provisioned
}

function test_a_username_given_both_ways_stops_the_container() {
  given_the_credentials "omsauser" "hunter2"
  given_the_username_is_in_a_file "someoneelse"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a username given in both places should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_username_FILE" \
    "and the refusal should name the two variables it found set"
  assert_nothing_was_provisioned
}

function test_a_password_file_keeps_every_space_it_holds() {
  # A password is entitled to spaces, at both ends included, and a file is the
  # one way of giving this container one that holds them. Trimming would be the
  # obvious convenience and it is the wrong one : it silently sets a password
  # that is not the one in the file, and the account it belongs to then refuses
  # the only value anybody has written down
  export OMSA_username="omsauser"
  given_the_password_is_in_a_file "  two words  "

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password holding spaces should start the container"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:  two words  " \
    "and should reach chpasswd with its spaces, the trailing newline alone removed"
}

function test_a_password_file_written_without_a_trailing_newline_is_read_the_same_way() {
  # The other half of "strip a single trailing newline" : a file that has none
  # is not missing anything, and a read that assumed one would take a character
  # off the password. "printf" rather than "echo" here for that exact reason
  export OMSA_username="omsauser"
  export OMSA_password_FILE="$TEST_ROOT/run/omsa_password"
  printf '%s' "hunter2" > "$OMSA_password_FILE"

  run_entrypoint

  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password file with no trailing newline should start the container"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:hunter2" \
    "and should read the password whole"
}

function test_a_password_file_the_container_cannot_read_stops_it() {
  # A secret mounted for another user, which is what a Swarm secret looks like
  # to a container that does not run as root. Read as an empty password it would
  # be the empty-password failure again, one indirection further away
  if [ "$(id -u)" -eq 0 ]; then
    skip_test "root reads a file whatever its mode, so an unreadable one cannot be simulated here"
    return 0
  fi

  export OMSA_username="omsauser"
  given_the_password_is_in_a_file "hunter2"
  command -p chmod 000 "$OMSA_password_FILE"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password file the container cannot read should stop it"
  assert_contains "$ENTRYPOINT_OUTPUT" "OMSA_password_FILE" \
    "and the refusal should name the variable"
  assert_nothing_was_provisioned
}
