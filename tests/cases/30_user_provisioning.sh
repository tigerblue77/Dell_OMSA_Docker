#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The account OMSA authenticates against. The container is restarted far more
# often than it is created, so the contract has two halves : the user is created
# when it is not there, and the run is harmless when it is -- with the password
# set either way, because that is what lets somebody change it by restarting the
# container with a new OMSA_password.
#
# Five cases below used to pin behaviour that was wrong rather than behaviour
# that was right, each saying what a later pull request was expected to change.
# That pull request is the entrypoint rewrite for issues #10 and #11, and every
# one of the five moved with it : the defect is named where it was, and what the
# case asserts now is the behaviour that replaced it. Documenting them is what
# made the rewrite visible instead of silent -- the case failed, somebody read
# why, and the expectation moved in the same commit as the fix.
#
# The account is created with "useradd" since that rewrite, and no longer with
# "adduser" : the latter is a compatibility symbolic link to the former on the
# EL family and a different program with different options everywhere else,
# which is not something an image whose base is under discussion should depend
# on. The two mocks are both still shipped, and several cases below read one of
# the call logs to assert that the other tool was not reached either.

function test_the_user_is_created_when_the_machine_does_not_have_it() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  # "useradd -- omsauser" rather than "adduser omsauser" since the rewrite for
  # issues #10 and #11 : a different tool, and the name behind a "--" so that it
  # is read as a name whatever it begins with
  assert_equals "1" "$(count_calls_matching useradd '^useradd -- omsauser$')" \
    "an account that does not exist should be created, once"
  assert_contains "$(sandbox_file_content /etc/passwd)" "omsauser:" \
    "and should be in the user database afterwards"
  assert_contains "$ENTRYPOINT_OUTPUT" "omsauser" \
    "the log should say which account it created"
}

function test_the_user_is_not_created_when_it_already_exists() {
  # The restart case, and the common one : the image is run with the same
  # OMSA_username it was run with yesterday. Creating the account again is not
  # idempotent -- the real adduser fails, and on a distribution where it does
  # not, it is a second account with the same name
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "0" "$(count_calls_matching useradd '.')" \
    "an account that already exists should not be created again"
  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "by either of the two account tools"
  assert_equals "1" "$(printf '%s\n' "$(sandbox_file_content /etc/passwd)" | grep -c '^omsauser:')" \
    "and the user database should still hold exactly one of it"
  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "finding the account already there is the normal case, not an error"
}

function test_the_password_is_set_when_the_account_was_just_created() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching chpasswd '.')" \
    "the password should be set, once"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:hunter2" \
    "chpasswd should be handed the account and the password it was given"
}

function test_the_password_is_set_again_when_the_account_already_exists() {
  # What makes "restart the container with a new OMSA_password" the way to
  # change the password. Skipping chpasswd for an existing account would make
  # the variable read-once, and nothing would say so
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "omsauser" "a-new-password"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching chpasswd '.')" \
    "an existing account should have its password set too"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:a-new-password" \
    "with the password the container was restarted with"
}

function test_the_password_never_reaches_a_command_line() {
  # A password given as an argument is readable in "ps" by every process on the
  # machine, and the container runs privileged. chpasswd reads it on its
  # standard input, which is the reason it is the tool used here -- this case is
  # what keeps a rewrite from "simplifying" that into an argument
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_not_contains "$(recorded_calls chpasswd)" "hunter2" \
    "the password should not appear in chpasswd's arguments"
  assert_not_contains "$(recorded_calls useradd)" "hunter2" \
    "nor in useradd's"
  assert_not_contains "$(recorded_calls adduser)" "hunter2" \
    "nor in those of the tool useradd replaced"
  assert_contains "$(recorded_chpasswd_input)" "hunter2" \
    "it travels on the standard input instead"
}

function test_the_password_is_not_printed_in_the_container_log() {
  # "docker logs" is kept by the daemon and read by anybody who can reach it
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_not_contains "$ENTRYPOINT_OUTPUT" "hunter2" \
    "the log should say what it is doing without printing the password"
}

function test_a_refused_account_creation_stops_the_container() {
  # The first half of issue #10 : every command was assumed to succeed. A
  # useradd that refused -- a name already taken by a system account, a full
  # disk, a read-only /etc -- left the run carrying on to set a password on an
  # account that was not there, to grant it rights it could not use, and to hand
  # the machine over as though it had worked
  given_the_credentials "omsauser" "hunter2"
  export MOCK_USERADD_EXIT_CODE=1

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "an account that could not be created should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "omsauser" \
    "and the message should name the account it failed on"
  assert_equals "0" "$(count_calls_matching chpasswd '.')" \
    "no password should be set on an account that was not created"
  assert_command_fails "and the handover should not happen on top of it" \
    the_entrypoint_reached_init
}

function test_a_refused_password_change_stops_the_container() {
  # The account exists and its password is not the one the operator set, which
  # is indistinguishable from a wrong password at the OMSA login page : the
  # container comes up, and the only symptom is somebody unable to log in
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "omsauser" "hunter2"
  export MOCK_CHPASSWD_EXIT_CODE=1

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a password that could not be set should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "omsauser" \
    "and the message should name the account it failed on"
  assert_not_contains "$ENTRYPOINT_OUTPUT" "hunter2" \
    "without printing the password it failed to set"
  assert_command_fails "and the handover should not happen on top of it" \
    the_entrypoint_reached_init
}

function test_the_password_is_not_handed_down_to_init() {
  # The other half of issue #11 : a password given in the environment is
  # inherited by every process started from it, which here means systemd and
  # everything systemd starts -- each of them carrying a copy of it in
  # /proc/<pid>/environ for as long as the container runs. The entrypoint takes
  # it back out of the environment once chpasswd has used it, and this reads the
  # environment the handover actually passed on.
  #
  # It does NOT make the password a secret from anybody who can reach the Docker
  # socket : the value is still part of the container's configuration and
  # "docker inspect" prints it. What it removes is the inherited copy
  given_the_credentials "omsauser" "hunter2"
  export MOCK_INIT_ENVIRONMENT_LOG="$TEST_ROOT/run/init_environment"

  run_entrypoint

  assert_command_succeeds "the handover should have happened" \
    the_entrypoint_reached_init || return 1

  local -r INIT_ENVIRONMENT="$(cat "$MOCK_INIT_ENVIRONMENT_LOG")"

  assert_contains "$INIT_ENVIRONMENT" "OMSA_username=omsauser" \
    "the username is not a secret and is still there, which is what says this is a real environment"
  assert_not_contains "$INIT_ENVIRONMENT" "hunter2" \
    "while the password should not be in the environment init is started with"
}

function test_a_username_differing_only_in_case_from_an_existing_one_is_created() {
  # WAS A BUG, fixed by the entrypoint rewrite for issues #10 and #11. The
  # lookup was `grep -i "^${OMSA_username}:"` over /etc/passwd, and -i made it
  # case-insensitive while the account database is not : "OMSAuser" matched the
  # existing "omsauser", the entrypoint concluded the account was there and
  # created nothing -- then handed chpasswd a username that did not exist, so
  # the password was set on nothing and the run carried on to init regardless.
  #
  # It asks the user database itself now, `getent passwd -- "$OMSA_username"`,
  # which answers for the exact name it is given. Two names differing in case
  # are two accounts, and the one that was asked for is created
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "OMSAuser" "hunter2"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching useradd '^useradd -- OMSAuser$')" \
    "a username differing only in case is a different account, and it is created"
  assert_contains "$(sandbox_file_content /etc/passwd)" "OMSAuser:" \
    "so the account that was asked for is in the user database afterwards"
  assert_equals "1" "$(printf '%s\n' "$(sandbox_file_content /etc/passwd)" | grep -c '^omsauser:')" \
    "while the account that merely looks like it is left exactly as it was"
  assert_contains "$(recorded_chpasswd_input)" "OMSAuser:hunter2" \
    "and the password is set on the name chpasswd is handed, which now carries an account"
}

function test_a_username_carrying_a_regular_expression_metacharacter_is_created() {
  # WAS A BUG, fixed by the same rewrite : the username was interpolated into a
  # regular expression without being escaped, so "omsa.ser" matched "omsauser"
  # the way "." matches any character. Same consequence as the case above, and
  # the same fix -- an exact lookup rather than a pattern built out of a value
  # somebody gave the container
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "omsa.ser" "hunter2"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching useradd '^useradd -- omsa\.ser$')" \
    "a name that merely looks like an existing one is not that account, and is created"
  assert_contains "$(sandbox_file_content /etc/passwd)" "omsa.ser:" \
    "so the requested account is in the user database afterwards"
  assert_contains "$(recorded_chpasswd_input)" "omsa.ser:hunter2" \
    "with its own password set on it"
}

function test_a_username_beginning_with_a_dash_is_refused_before_it_reaches_useradd() {
  # WAS A BUG, fixed by the same rewrite : the username was passed as
  # `adduser "${OMSA_username}"` with no "--" in front of it, so a name
  # beginning with a dash was read as an option rather than as a username --
  # no account was created, nothing said so, and the container started anyway.
  #
  # Two things changed, and only one of them is what this case now reads. The
  # name is validated against a conservative pattern before it reaches useradd,
  # and a leading dash is not in it, so the container stops with a message
  # naming the value. The "--" went in as well, one token in front of the name,
  # which is what keeps a later widening of that pattern from turning a name
  # back into an option
  given_the_credentials "-v" "hunter2"

  run_entrypoint

  assert_not_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "a username beginning with a dash should stop the container"
  assert_contains "$ENTRYPOINT_OUTPUT" "-v" \
    "and the refusal should name the value, rather than leaving useradd to report it"
  assert_equals "0" "$(count_calls_matching useradd '.')" \
    "the name should never reach useradd at all"
  assert_equals "0" "$(count_calls_matching chpasswd '.')" \
    "and no password should be set on an account that was not created"
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "-v:" \
    "nothing is created either way -- but now the container says so"
}

function test_an_account_only_the_user_database_can_see_is_not_created_again() {
  # WAS A BUG, fixed by the same rewrite : /etc/passwd is not the user database,
  # it is one source of it. An account that comes from LDAP, SSSD or any other
  # NSS module is invisible to a grep over that file, so the entrypoint tried to
  # create it -- and the real useradd refuses, because as far as the system is
  # concerned the name is taken.
  #
  # The sandbox has no NSS, so the account is described here the way the mocked
  # getent answers for it : present in the database, absent from the file. That
  # is the difference "getent passwd" exists to see, and the reason its mock was
  # shipped before anything called it
  export MOCK_GETENT_OUTPUT="omsauser:x:5000:5000:from LDAP:/home/omsauser:/bin/bash"
  given_the_credentials "omsauser" "hunter2"

  # The premise, verified rather than assumed : asked, the system database does
  # answer for this account, while the file the entrypoint used to read does not
  # hold it
  assert_command_succeeds "the system database should answer for the account" \
    getent passwd omsauser
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "omsauser:" \
    "while /etc/passwd should not hold it"
  forget_recorded_calls getent

  run_entrypoint

  assert_not_equals "0" "$(count_calls_matching getent '^getent passwd -- omsauser$')" \
    "the entrypoint should ask the database, by the exact name and behind a \"--\""
  assert_equals "0" "$(count_calls_matching useradd '.')" \
    "an account the database answers for should not be created a second time"
  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "by either of the two account tools"
  assert_contains "$(recorded_chpasswd_input)" "omsauser:hunter2" \
    "while its password is still set, which is what a restart is for"
}

function test_a_password_carrying_a_backslash_reaches_chpasswd_exactly_as_it_was_given() {
  # WAS A BUG, fixed by the same rewrite : the password was piped with
  # `echo "$OMSA_username:$OMSA_password"`, and "echo" is the one utility whose
  # treatment of backslashes POSIX leaves to the implementation. Under dash --
  # /bin/sh on Debian and Ubuntu -- "\t" became a tab before chpasswd ever saw
  # it, so the account ended up with a password nobody typed. Under bash, which
  # is /bin/sh on the AlmaLinux this image is built from, it arrived intact : the
  # image did not carry the bug and the script did, which is the kind of defect
  # that waits for a base image change to show up.
  #
  # It is `printf '%s:%s\n'` now, whose treatment of its arguments is specified,
  # so the answer no longer depends on which shell the suite runs under and this
  # case no longer has to measure it before asserting it
  given_the_credentials "omsauser" 'pa\tss'

  run_entrypoint

  local -r CHPASSWD_INPUT="$(recorded_chpasswd_input)"

  assert_equals 'omsauser:pa\tss' "$CHPASSWD_INPUT" \
    "the password should reach chpasswd exactly as it was given, backslash included"
  assert_not_contains "$CHPASSWD_INPUT" "pa$(printf '\t')ss" \
    "and the escape should not have been expanded on the way, whatever /bin/sh is here"
}
