#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The account OMSA authenticates against. The container is restarted far more
# often than it is created, so the contract has two halves : the user is created
# when it is not there, and the run is harmless when it is -- with the password
# set either way, because that is what lets somebody change it by restarting the
# container with a new OMSA_password.
#
# Several cases below pin behaviour that is wrong rather than behaviour that is
# right. They are marked, and each says what a later pull request is expected to
# change. A test that documents today's behaviour is what makes that rewrite
# visible instead of silent : it fails, somebody reads why, and the expectation
# moves in the same commit as the fix.

function test_the_user_is_created_when_the_machine_does_not_have_it() {
  given_the_credentials "omsauser" "hunter2"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching adduser '^adduser omsauser$')" \
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

  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "an account that already exists should not be created again"
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
  assert_not_contains "$(recorded_calls adduser)" "hunter2" \
    "nor in adduser's"
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

function test_a_username_differing_only_in_case_from_an_existing_one_is_not_created() {
  # BUG, documented rather than fixed : the lookup is
  # `grep -i "^${OMSA_username}:"` over /etc/passwd, and -i makes it
  # case-insensitive while the account database is not. "OMSAuser" therefore
  # matches the existing "omsauser", the entrypoint concludes the account is
  # there and creates nothing -- and then hands chpasswd a username that does
  # not exist, so the password is set on nothing and the run carries on to init
  # regardless.
  #
  # A later pull request is expected to ask the user database itself
  # ("getent passwd -- "$OMSA_username"", mocked in tests/mocks/getent), which
  # answers for the exact name and for the accounts /etc/passwd does not hold.
  # When it does, this case is the one that has to change, deliberately
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "OMSAuser" "hunter2"

  run_entrypoint

  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "today, a username differing only in case is taken for the existing account"
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "OMSAuser:" \
    "so the account the user actually asked for is never created"
  assert_contains "$(recorded_chpasswd_input)" "OMSAuser:hunter2" \
    "while chpasswd is still handed that name, which no account carries"
}

function test_a_username_carrying_a_regular_expression_metacharacter_matches_another_account() {
  # BUG, documented rather than fixed : the username is interpolated into a
  # regular expression without being escaped, so "omsa.ser" matches "omsauser"
  # the way "." matches any character. Same consequence as the case above, and
  # the same fix -- an exact lookup rather than a pattern built out of user input
  given_the_sandbox_already_has_the_user "omsauser"
  given_the_credentials "omsa.ser" "hunter2"

  run_entrypoint

  assert_equals "0" "$(count_calls_matching adduser '.')" \
    "today, a username read as a pattern matches an account that merely looks like it"
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "omsa.ser:" \
    "so the requested account is never created"
}

function test_a_username_beginning_with_a_dash_is_handed_to_adduser_as_an_option() {
  # BUG, documented rather than fixed : the username is passed as
  # `adduser "${OMSA_username}"` with no "--" in front of it, so a name
  # beginning with a dash is read by adduser as an option rather than as a
  # username. The mock behaves the way the real tool does here : it takes the
  # first non-option argument as the name, and there is none.
  #
  # The fix is one token, `adduser -- "${OMSA_username}"`, and it belongs to the
  # pull request that rewrites this script
  given_the_credentials "-v" "hunter2"

  run_entrypoint

  assert_equals "1" "$(count_calls_matching adduser '^adduser -v$')" \
    "today, the username reaches adduser as a bare argument, with no \"--\" before it"
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "-v:" \
    "so no account is created, and nothing says so"
  assert_equals "0" "$ENTRYPOINT_EXIT_CODE" \
    "and the container starts anyway"
}

function test_an_account_the_passwd_file_cannot_see_is_created_again() {
  # BUG, documented rather than fixed : /etc/passwd is not the user database, it
  # is one source of it. An account that comes from LDAP, SSSD or any other NSS
  # module is invisible to a grep over that file, so the entrypoint tries to
  # create it -- and the real adduser refuses, because as far as the system is
  # concerned the name is taken.
  #
  # The sandbox has no NSS, so the account is described here the way the mocked
  # getent would answer for it : present in the database, absent from the file.
  # That is the difference "getent passwd" exists to see, and the reason the
  # mock is shipped before anything calls it
  export MOCK_GETENT_OUTPUT="omsauser:x:5000:5000:from LDAP:/home/omsauser:/bin/bash"
  given_the_credentials "omsauser" "hunter2"

  # The premise, verified rather than assumed : asked, the system database does
  # answer for this account, while the file the entrypoint reads does not hold it
  assert_command_succeeds "the system database should answer for the account" \
    getent passwd omsauser
  assert_not_contains "$(sandbox_file_content /etc/passwd)" "omsauser:" \
    "while /etc/passwd should not hold it"
  forget_recorded_calls getent

  run_entrypoint

  assert_equals "1" "$(count_calls_matching adduser '^adduser omsauser$')" \
    "today, an account /etc/passwd does not hold is created, whatever the system database says"
  assert_equals "0" "$(count_calls_matching getent '.')" \
    "the entrypoint asks the file rather than the database, which is the defect itself"
}

function test_a_password_carrying_a_backslash_reaches_chpasswd_as_the_shell_echoes_it() {
  # BUG, documented rather than fixed : the password is piped with
  # `echo "$OMSA_username:$OMSA_password"`, and "echo" is the one utility whose
  # treatment of backslashes POSIX leaves to the implementation. Under dash --
  # /bin/sh on Debian and Ubuntu -- "\t" becomes a tab before chpasswd ever sees
  # it, so the account ends up with a password nobody typed. Under bash, which
  # is /bin/sh on the AlmaLinux this image is built from, it arrives intact.
  #
  # So the image does not carry the bug today and the script does : the fix is
  # `printf '%s:%s\n'`, which is specified. Measured here rather than assumed,
  # because the answer depends on the shell the suite happens to run under, and
  # a case asserting one of the two would fail on the other machine for a reason
  # having nothing to do with the entrypoint
  given_the_credentials "omsauser" 'pa\tss'

  run_entrypoint

  local -r CHPASSWD_INPUT="$(recorded_chpasswd_input)"

  assert_matches "$CHPASSWD_INPUT" '^omsauser:' \
    "whatever the shell does with the backslash, the line still names the account"

  if [ "$(sh -c 'echo "a\tb"')" == 'a\tb' ]; then
    assert_contains "$CHPASSWD_INPUT" 'pa\tss' \
      "this shell's echo leaves the backslash alone, so the password arrives as it was given"
  else
    assert_not_contains "$CHPASSWD_INPUT" 'pa\tss' \
      "this shell's echo expands the backslash, so the password does not arrive as it was given"
    assert_contains "$CHPASSWD_INPUT" "pa$(printf '\t')ss" \
      "it arrives with the escape expanded, which is the defect printf would remove"
  fi
}
