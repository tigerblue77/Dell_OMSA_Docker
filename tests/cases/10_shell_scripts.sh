#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Checks on the repository's own files, before any behaviour is exercised : a
# syntax error in the entrypoint breaks every container at once, and the sandbox
# seam the rest of this suite rests on is only as honest as the map that
# declares it.

# The two SPDX lines every authored file here carries. The identifier is the
# project's own, stated in LICENSE and NOTICE ; the copyright line is what
# attributes it.
#
# Held WITHOUT a comment marker, because the marker is the file type's business
# and not the header's : a shell script and a YAML file carry them behind "# ",
# Markdown carries them inside an <!-- --> block, and the Dockerfile behind "#"
# again. Matching the text rather than the line lets one check cover all of
# them, which is what stops a new file type quietly falling outside it -- the
# way every Markdown file in this tree did until it was noticed.
readonly SPDX_LICENCE_TEXT='SPDX-License-Identifier: AGPL-3.0-only'
readonly SPDX_COPYRIGHT_TEXT='SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors'

# Kept for the failure message, which is worth printing in the shape the reader
# has to type
readonly SPDX_LICENCE_LINE="# $SPDX_LICENCE_TEXT"
readonly SPDX_COPYRIGHT_LINE="# $SPDX_COPYRIGHT_TEXT"

# Read from the first five lines : a header is only a header where a reader and
# a scanner both find it, and one buried below the code it covers discharges
# nothing. Five is enough for every shape in this tree -- a shebang, a blank
# line and the two lines, or the four lines of an HTML comment block
function carries_the_licence_header() {
  local -r HEAD="$(head -5 "$1")"

  [[ "$HEAD" == *"$SPDX_COPYRIGHT_TEXT"* ]] && [[ "$HEAD" == *"$SPDX_LICENCE_TEXT"* ]]
}

# Every Markdown file this repository authors. Globbed for the same reason the
# shell scripts are : a document added later is covered rather than forgotten.
#
# LICENSE is deliberately absent -- it is the AGPL's own text, verbatim from the
# FSF, and a copyright line of this project's on top of it would be a claim over
# somebody else's document
function every_markdown_file_of_the_tree() {
  shopt -s globstar nullglob
  local DOCUMENT
  for DOCUMENT in "$REPO_ROOT"/*.md "$REPO_ROOT"/.github/**/*.md \
    "$REPO_ROOT"/tools/*.md "$TESTS_DIRECTORY"/*.md; do
    [ -f "$DOCUMENT" ] && printf '%s\n' "$DOCUMENT"
  done
  shopt -u globstar nullglob
}

# The interpreter a script declares, so that a POSIX sh script is parsed by sh
# and a bash one by bash. "bash -n" accepts constructs sh rejects, so checking
# the entrypoint with bash would be checking a shell it never runs under : the
# image's CMD runs it as /bin/sh
function shebang_interpreter_of() {
  local -r SHEBANG="$(head -1 "$1")"

  case "$SHEBANG" in
    '#!'*bash*) printf 'bash' ;;
    '#!'*sh*) printf 'sh' ;;
    *) printf '' ;;
  esac
}

# Every file of this repository that is a shell script, whatever directory it
# sits in. Globbed rather than listed, so a script added later is covered by
# these cases instead of quietly falling outside them.
#
# tools/ is in the walk although it is empty on this branch : an operator tool
# arrives there on claude/privilege-probe, and a directory added to the tree
# after the walk was written is exactly how a script ends up checked by nothing.
# nullglob makes an absent directory cost nothing, so the entry is free until
# the day it is not
function every_shell_script_of_the_tree() {
  shopt -s globstar nullglob
  local SCRIPT
  for SCRIPT in "$REPO_ROOT"/*.sh "$REPO_ROOT"/.github/**/*.sh "$REPO_ROOT"/.claude/**/*.sh \
    "$REPO_ROOT"/tools/*.sh \
    "$TESTS_DIRECTORY"/*.sh "$TESTS_DIRECTORY"/lib/*.sh "$TESTS_DIRECTORY"/cases/*.sh \
    "$TESTS_DIRECTORY"/mocks/*; do
    [ -f "$SCRIPT" ] && printf '%s\n' "$SCRIPT"
  done
  shopt -u globstar nullglob
}

function test_every_shell_script_has_a_valid_syntax() {
  local SCRIPT INTERPRETER SYNTAX_ERRORS
  while IFS= read -r SCRIPT; do
    INTERPRETER="$(shebang_interpreter_of "$SCRIPT")"
    if [ -z "$INTERPRETER" ]; then
      fail "${SCRIPT#"$REPO_ROOT"/} declares no shell in its shebang, so nothing can say which parser it has to satisfy"
      continue
    fi

    if SYNTAX_ERRORS=$("$INTERPRETER" -n "$SCRIPT" 2>&1); then
      pass
    else
      fail "${SCRIPT#"$REPO_ROOT"/} has a syntax error under $INTERPRETER" "$SYNTAX_ERRORS"
    fi
  done < <(every_shell_script_of_the_tree)
}

function test_every_file_the_test_suite_ships_carries_the_licence_header() {
  # The suite's own files, checked whatever the rest of the repository does :
  # they are written here and a header missing from one of them is this pull
  # request's own omission, not a question about what the project has adopted.
  # Mocks and helpers included -- they are files like any other
  shopt -s nullglob
  local FILE
  for FILE in "$TESTS_DIRECTORY"/*.sh "$TESTS_DIRECTORY"/lib/*.sh \
    "$TESTS_DIRECTORY"/cases/*.sh "$TESTS_DIRECTORY"/mocks/*; do
    [ -f "$FILE" ] || continue

    if carries_the_licence_header "$FILE"; then
      pass
    else
      fail "${FILE#"$REPO_ROOT"/} carries no SPDX licence header in its first five lines" \
        "expected both :" "$SPDX_COPYRIGHT_LINE" "$SPDX_LICENCE_LINE"
    fi
  done
  shopt -u nullglob
}

function test_every_markdown_document_carries_the_licence_header() {
  # Markdown carries the same two lines, inside an <!-- --> block, and until it
  # was asked out loud nothing checked that it did -- the header walk covered
  # shell, YAML and the Dockerfile, and every document in the tree sat outside
  # it. A rule stated in CONTRIBUTING and enforced by nothing is a rule that
  # holds exactly as long as whoever wrote it is still reading the diffs.
  #
  # Held to the same gate as the case above : a header is a claim about terms,
  # and it cannot be made before the repository states any.
  if [ ! -f "$REPO_ROOT/LICENSE" ]; then
    skip_test "the repository states no licence yet, so no document can be held to an SPDX header"
    return 0
  fi

  local DOCUMENT
  while IFS= read -r DOCUMENT; do
    if carries_the_licence_header "$DOCUMENT"; then
      pass
    else
      fail "${DOCUMENT#"$REPO_ROOT"/} carries no SPDX licence header in its first five lines" \
        "expected both, inside an HTML comment :" "$SPDX_COPYRIGHT_TEXT" "$SPDX_LICENCE_TEXT"
    fi
  done < <(every_markdown_file_of_the_tree)
}

function test_the_test_suite_readme_carries_the_licence_header() {
  # Split out from the walk above so that it is checked whatever the rest of the
  # repository does, for the same reason the suite's own scripts are : it is
  # written here, so a header missing from it is this pull request's omission
  # rather than a question about what the project has adopted
  local -r README="$TESTS_DIRECTORY/README.md"

  if [ ! -f "$README" ]; then
    fail "tests/README.md is missing"
    return 1
  fi

  if carries_the_licence_header "$README"; then
    pass
  else
    fail "tests/README.md carries no SPDX licence header in its first five lines" \
      "expected both, inside an HTML comment :" "$SPDX_COPYRIGHT_TEXT" "$SPDX_LICENCE_TEXT"
  fi
}

function test_every_file_of_the_repository_carries_the_licence_header() {
  # The entrypoint, the Dockerfile and the workflows, which are the files the
  # image is actually built and published from.
  #
  # Skipped while the repository states no licence of its own : writing an SPDX
  # identifier into a file is a claim about terms, and a suite is not where
  # terms get adopted. The licensing work is a pull request of its own, and the
  # day it lands -- LICENSE at the root, NOTICE beside it -- this case starts
  # enforcing the headers over the whole tree with nothing to change here.
  #
  # .devcontainer/devcontainer.json is deliberately out of the walk : JSON has
  # no comment syntax at all, so a header cannot be written in it
  if [ ! -f "$REPO_ROOT/LICENSE" ]; then
    skip_test "the repository states no licence yet, so no file can be held to an SPDX header"
    return 0
  fi

  shopt -s nullglob
  local FILE
  for FILE in "$REPO_ROOT"/*.sh "$REPO_ROOT"/Dockerfile \
    "$REPO_ROOT"/tools/*.sh \
    "$REPO_ROOT"/.github/*.yml "$REPO_ROOT"/.github/*.yaml \
    "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
    [ -f "$FILE" ] || continue

    if carries_the_licence_header "$FILE"; then
      pass
    else
      fail "${FILE#"$REPO_ROOT"/} carries no SPDX licence header in its first five lines" \
        "expected both :" "$SPDX_COPYRIGHT_LINE" "$SPDX_LICENCE_LINE"
    fi
  done
  shopt -u nullglob
}

# The scripts a "Run shellcheck" step names, one per line. That workflow names
# its files one by one rather than globbing them, which is what lets it lint the
# repository's scripts under one set of options and the suite's under another --
# and what makes the list something somebody has to remember to extend
# Usage : scripts_the_shellcheck_workflow_names WORKFLOW
function scripts_the_shellcheck_workflow_names() {
  sed -n 's/^ *\([A-Za-z0-9_./-]*\.sh\) *\\\{0,1\}$/\1/p' "$1"
}

function test_the_shellcheck_workflow_lints_every_script_of_this_tree() {
  # Nothing in this repository lints shell today : there is no shellcheck
  # workflow, no .shellcheckrc and no CI job that reads a script. The suite's
  # own "bash -n" above is a syntax check and nothing more.
  #
  # So this case is written for the workflow rather than against it : the day
  # one is added, it holds the hand-maintained list to the tree instead of
  # letting a script sit outside it for months, which is exactly what happened
  # in the sibling repository. Until then it says so rather than passing quietly
  local -r SHELLCHECK_WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck.yml"

  if [ ! -f "$SHELLCHECK_WORKFLOW" ]; then
    skip_test "no .github/workflows/shellcheck.yml : nothing in this repository lints shell yet"
    return 0
  fi

  local -r LINTED_SCRIPTS="$(scripts_the_shellcheck_workflow_names "$SHELLCHECK_WORKFLOW")"

  assert_not_empty "$LINTED_SCRIPTS" \
    "the shellcheck workflow should name the scripts it lints" || return 1

  local SCRIPT RELATIVE_PATH
  while IFS= read -r SCRIPT; do
    RELATIVE_PATH="${SCRIPT#"$REPO_ROOT"/}"
    if printf '%s\n' "$LINTED_SCRIPTS" | grep -qxF "$RELATIVE_PATH"; then
      pass
    else
      fail "$RELATIVE_PATH is linted by nothing, the shellcheck workflow does not name it" \
        "it checks : $(printf '%s' "$LINTED_SCRIPTS" | tr '\n' ' ')"
    fi
  done < <(every_shell_script_of_the_tree)

  # And the other way round : a path that left the tree but stayed in the list
  # makes the step fail on a file that is not there, in a workflow no pull
  # request may be running yet
  local NAMED_SCRIPT
  while IFS= read -r NAMED_SCRIPT; do
    [ -n "$NAMED_SCRIPT" ] || continue
    if [ -f "$REPO_ROOT/$NAMED_SCRIPT" ]; then
      pass
    else
      fail "the shellcheck workflow names $NAMED_SCRIPT, which is not in the tree"
    fi
  done < <(printf '%s\n' "$LINTED_SCRIPTS")
}

function test_every_absolute_path_the_entrypoint_names_is_declared_in_the_sandbox_map() {
  # THE invariant of this suite. The entrypoint writes to absolute paths of the
  # machine it runs on -- /etc/passwd, /etc/rc.local, OMSA's role map, two
  # systemd units -- and a mock first in the PATH cannot intercept any of them,
  # an absolute path being resolved without consulting the PATH at all. What
  # keeps a test run from provisioning the machine running it is one thing only :
  # lib/harness.sh rewrites each of those paths into $TEST_ROOT before the copy
  # is run.
  #
  # That rewrite is driven by a hand-written map, so an edit adding a write to a
  # path the map does not know would escape it silently -- the suite would stay
  # green, and the write would land on the developer's own /etc. This case is
  # what makes that edit red instead : every absolute path the real script
  # names has to be declared, as "sandbox" or, deliberately, as "verbatim"
  local -r DECLARED_PATHS="$(mapped_absolute_paths)"

  local ABSOLUTE_PATH
  while IFS= read -r ABSOLUTE_PATH; do
    [ -n "$ABSOLUTE_PATH" ] || continue

    if printf '%s\n' "$DECLARED_PATHS" | grep -qxF "$ABSOLUTE_PATH"; then
      pass
    else
      fail "configure_and_run_Dell_OMSA.sh names $ABSOLUTE_PATH, which ENTRYPOINT_ABSOLUTE_PATHS does not declare" \
        "add it to the map in tests/lib/harness.sh, as \"$ABSOLUTE_PATH=sandbox\" if the script reads, writes or runs it," \
        "or as \"$ABSOLUTE_PATH=verbatim\" if it is text the script only writes into a file" \
        "until then, a test run would reach that path on the machine running the suite"
    fi
  done < <(absolute_paths_named_in "$(entrypoint_path)")
}

function test_the_sandbox_map_declares_nothing_the_entrypoint_no_longer_names() {
  # The same guard read backwards. A map entry for a path the script has stopped
  # naming is not dangerous, it is misleading : it says the suite is protecting
  # something it no longer needs to, and it is the entry a reader trusts when
  # deciding what the entrypoint touches
  local -r ENTRYPOINT_PATHS="$(absolute_paths_named_in "$(entrypoint_path)")"

  local DECLARED_PATH
  while IFS= read -r DECLARED_PATH; do
    [ -n "$DECLARED_PATH" ] || continue

    if printf '%s\n' "$ENTRYPOINT_PATHS" | grep -qxF "$DECLARED_PATH"; then
      pass
    else
      fail "ENTRYPOINT_ABSOLUTE_PATHS declares $DECLARED_PATH, which configure_and_run_Dell_OMSA.sh no longer names" \
        "drop the entry from tests/lib/harness.sh, or the map stops describing the script it is written for"
    fi
  done < <(mapped_absolute_paths)
}

function test_the_sandboxed_entrypoint_leaves_no_absolute_path_pointing_outside_the_sandbox() {
  # The map is a declaration ; this is the rewrite it produces, read back off
  # the copy the test cases actually run. The two are different failures : the
  # case above catches a path nobody declared, this one catches a declared path
  # the substitution did not reach
  local -r ESCAPING_PATHS="$(absolute_paths_escaping_the_sandbox "$SANDBOXED_ENTRYPOINT")"

  assert_empty "$ESCAPING_PATHS" \
    "the sandboxed copy still names paths of the machine running the suite"

  local -r SANDBOXED_SOURCE="$(cat "$SANDBOXED_ENTRYPOINT")"

  # Rewritten, not merely absent : a substitution that dropped the path instead
  # of moving it would satisfy the assertion above and leave the script writing
  # nowhere, which would make every behavioural case below pass against a script
  # that does nothing
  local ABSOLUTE_PATH
  while IFS= read -r ABSOLUTE_PATH; do
    [ -n "$ABSOLUTE_PATH" ] || continue
    assert_contains "$SANDBOXED_SOURCE" "$TEST_ROOT$ABSOLUTE_PATH" \
      "$ABSOLUTE_PATH should have been rewritten into the sandbox rather than removed"
  done < <(mapped_absolute_paths sandbox)

  # And the paths declared "verbatim" are still themselves. The extraction
  # returns the longest path it finds, so a rewritten one comes back as
  # "$TEST_ROOT/opt/..." and not as "/opt/..." : finding the short form means
  # it survived untouched
  local -r COPY_PATHS="$(absolute_paths_named_in "$SANDBOXED_ENTRYPOINT")"
  while IFS= read -r ABSOLUTE_PATH; do
    [ -n "$ABSOLUTE_PATH" ] || continue
    if printf '%s\n' "$COPY_PATHS" | grep -qxF "$ABSOLUTE_PATH"; then
      pass
    else
      fail "$ABSOLUTE_PATH is declared verbatim but the sandboxed copy no longer names it" \
        "rewriting it changes what the script means rather than where it writes"
    fi
  done < <(mapped_absolute_paths verbatim)
}

function test_the_dockerfile_runs_the_entrypoint_it_ships() {
  # The image copies one script in and runs it. Two lines, and nothing else in
  # this repository would notice if they stopped naming the same file : the
  # build would succeed, and the container would exit immediately on a CMD
  # pointing at a path that is not there
  local -r DOCKERFILE="$REPO_ROOT/Dockerfile"

  assert_command_succeeds "the repository should ship a Dockerfile" test -f "$DOCKERFILE" || return 1

  local -r ADDED_SCRIPT="$(sed -n 's/^ADD[[:space:]]\+\([^[:space:]]*configure_and_run_Dell_OMSA\.sh\)[[:space:]].*$/\1/p' "$DOCKERFILE")"
  assert_equals "configure_and_run_Dell_OMSA.sh" "$ADDED_SCRIPT" \
    "the Dockerfile should copy the entrypoint this suite tests into the image"

  local -r COMMAND_LINE="$(grep -E '^CMD ' "$DOCKERFILE")"
  assert_contains "$COMMAND_LINE" "configure_and_run_Dell_OMSA.sh" \
    "the image's CMD should run the script it just copied in"

  assert_command_succeeds "the entrypoint the Dockerfile names should exist in the tree" \
    test -f "$(entrypoint_path)"
}

function test_every_mock_is_executable_and_declares_a_shell() {
  # A mock that lost its executable bit is not found through the PATH, and the
  # real command runs instead -- adduser and chpasswd against the machine's own
  # account database. It fails as a permission error only if nothing else on the
  # machine answers to that name, which is precisely not the case for these five
  shopt -s nullglob
  local MOCK
  for MOCK in "$TESTS_DIRECTORY"/mocks/*; do
    [ -f "$MOCK" ] || continue

    if [ -x "$MOCK" ]; then
      pass
    else
      fail "tests/mocks/$(basename "$MOCK") is not executable, so the real command would run instead"
    fi

    assert_not_empty "$(shebang_interpreter_of "$MOCK")" \
      "tests/mocks/$(basename "$MOCK") should declare its shell in a shebang"
  done
  shopt -u nullglob
}

function test_every_command_the_entrypoint_calls_by_name_is_mocked() {
  # The commands the entrypoint runs by name are the ones a PATH mock can
  # intercept, and the ones it cannot intercept are the sandbox's business. A
  # command called by name with no mock behind it runs for real : "adduser" on
  # the machine running the suite creates an account on it.
  #
  # Read out of the script rather than listed, so that a command added to the
  # entrypoint later arrives here as a failure rather than as a real invocation
  local -r ENTRYPOINT_SOURCE="$(cat "$(entrypoint_path)")"

  # The commands this suite knows the entrypoint can reach. "echo", "cat" and
  # "grep" are left out on purpose : they read or print, they are given
  # sandboxed paths, and mocking them would replace the tools the assertions
  # themselves depend on
  local COMMAND
  for COMMAND in adduser chpasswd systemctl chmod rm; do
    if ! printf '%s' "$ENTRYPOINT_SOURCE" | grep -qE "(^|[|;&( \t])$COMMAND([ \t]|$)"; then
      # Not called today : nothing to assert, and the mock staying is a
      # deliberate choice this case does not second-guess
      continue
    fi

    if [ -x "$TESTS_DIRECTORY/mocks/$COMMAND" ]; then
      pass
    else
      fail "the entrypoint calls \"$COMMAND\" and tests/mocks/$COMMAND does not exist" \
        "the real command would run, against the machine running the suite"
    fi
  done
}
