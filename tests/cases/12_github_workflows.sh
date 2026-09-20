#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The workflow that publishes the image is the one file here no pull request
# ever runs : it fires on a push to master, after review is over. A mistake in
# it is found at publication time, by which point it has already cost a release.
# This is where it gets read anyway.

# Every workflow file, and the Dependabot configuration beside them : all of it
# is YAML GitHub parses on its own, and none of it is read by anything in this
# repository
function every_github_yaml_file() {
  shopt -s nullglob
  local FILE
  for FILE in "$REPO_ROOT"/.github/*.yml "$REPO_ROOT"/.github/*.yaml \
    "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
    [ -f "$FILE" ] && printf '%s\n' "$FILE"
  done
  shopt -u nullglob
}

function every_workflow_file() {
  shopt -s nullglob
  local FILE
  for FILE in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
    [ -f "$FILE" ] && printf '%s\n' "$FILE"
  done
  shopt -u nullglob
}

function test_every_github_yaml_file_parses() {
  # A workflow that does not parse does not run, and GitHub reports it on the
  # Actions page rather than on the pull request that introduced it : the push
  # that was supposed to publish the image simply produces no run at all.
  #
  # Skipped rather than approximated where no YAML parser is available : a
  # hand-rolled check would pass the documents a real parser refuses, which is
  # worse than saying nothing
  if ! python3 -c "import yaml" > /dev/null 2>&1; then
    skip_test "python3 with PyYAML is what parses these, and it is not installed"
    return 0
  fi

  local FILE PARSE_ERRORS
  local FILES_READ=0
  while IFS= read -r FILE; do
    FILES_READ=$((FILES_READ + 1))
    if PARSE_ERRORS=$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$FILE" 2>&1); then
      pass
    else
      fail "${FILE#"$REPO_ROOT"/} is not valid YAML, so GitHub never runs it" "$PARSE_ERRORS"
    fi
  done < <(every_github_yaml_file)

  if [ "$FILES_READ" -eq 0 ]; then
    fail "no YAML file was found under .github/, and the image is published by one"
  fi
}

# Every step of every workflow runs shell, and none of it is shell to any tool
# that reads this repository : bash never parses a workflow, and a YAML linter
# reads the document rather than the scalar. Whatever a workflow runs is
# therefore written and merged unchecked, and a missing "fi" in it is found by
# the run that needed the workflow -- a release -- rather than by the pull
# request that introduced it.
#
# Pulling the scalars back out is enough to hand them to "bash -n". It is a
# syntax check and nothing more : it says the block parses, never that it does
# the right thing. The ${{ }} expressions survive it -- bash reads them as a
# parameter expansion and asks no question about the name -- so the blocks are
# checked as written, with nothing substituted and nothing added to any workflow.
#
# Usage : extract_workflow_run_blocks WORKFLOW OUTPUT_DIRECTORY
#         -> one "LINE<TAB>SCRIPT" per block, the scripts written in the directory
function extract_workflow_run_blocks() {
  awk -v OUTPUT_DIRECTORY="$2" '
    # A block scalar ends where the indentation returns to the key that opened
    # it, and is written out dedented : a heredoc terminator carrying the
    # workflow indentation is one bash would never recognise
    function flush_block(   INDEX, TEXT, SCRIPT) {
      SCRIPT = OUTPUT_DIRECTORY "/" (++BLOCKS) ".sh"
      printf "" > SCRIPT
      for (INDEX = 1; INDEX <= BUFFERED; INDEX++) {
        TEXT = BUFFER[INDEX]
        if (TEXT !~ /^[[:space:]]*$/) TEXT = substr(TEXT, MINIMUM_INDENT + 1)
        print TEXT > SCRIPT
      }
      close(SCRIPT)
      print BLOCK_LINE "\t" SCRIPT
      BUFFERED = 0
      IN_BLOCK = 0
    }
    {
      LINE = $0
      if (IN_BLOCK) {
        if (LINE ~ /^[[:space:]]*$/) { BUFFER[++BUFFERED] = ""; next }
        match(LINE, /^[[:space:]]*/)
        if (RLENGTH > KEY_INDENT) {
          if (MINIMUM_INDENT < 0 || RLENGTH < MINIMUM_INDENT) MINIMUM_INDENT = RLENGTH
          BUFFER[++BUFFERED] = LINE
          next
        }
        flush_block()
      }
      # "run: |", the shape all but a handful of the steps are written in
      if (LINE ~ /^[[:space:]-]*run:[[:space:]]*\|[-+]?[[:space:]]*$/) {
        KEY_INDENT = index(LINE, "run:") - 1
        IN_BLOCK = 1
        MINIMUM_INDENT = -1
        BLOCK_LINE = FNR
        next
      }
      # "run: one command", the rest of them
      if (LINE ~ /^[[:space:]-]*run:[[:space:]]*[^|>[:space:]]/) {
        COMMAND = LINE
        sub(/^[[:space:]-]*run:[[:space:]]*/, "", COMMAND)
        SCRIPT = OUTPUT_DIRECTORY "/" (++BLOCKS) ".sh"
        print COMMAND > SCRIPT
        close(SCRIPT)
        print FNR "\t" SCRIPT
      }
    }
    END { if (IN_BLOCK) flush_block() }
  ' "$1"
}

function test_every_shell_block_the_workflows_run_has_a_valid_syntax() {
  local -r EXTRACTION_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/workflow_run_blocks"
  command -p rm -rf "$EXTRACTION_DIRECTORY"
  command -p mkdir -p "$EXTRACTION_DIRECTORY"

  local WORKFLOW RELATIVE_PATH DECLARED_BLOCKS EXTRACTED_BLOCKS BLOCK_LINE SCRIPT SYNTAX_ERRORS
  local DECLARED_ACROSS_THE_TREE=0
  while IFS= read -r WORKFLOW; do
    RELATIVE_PATH="${WORKFLOW#"$REPO_ROOT"/}"

    DECLARED_BLOCKS=$(grep -cE '^[[:space:]-]*run:' "$WORKFLOW" || true)
    DECLARED_ACROSS_THE_TREE=$((DECLARED_ACROSS_THE_TREE + DECLARED_BLOCKS))

    EXTRACTED_BLOCKS=0
    while IFS=$'\t' read -r BLOCK_LINE SCRIPT; do
      [ -n "$SCRIPT" ] || continue
      EXTRACTED_BLOCKS=$((EXTRACTED_BLOCKS + 1))

      SYNTAX_ERRORS=$(bash -n "$SCRIPT" 2>&1)
      if [ -z "$SYNTAX_ERRORS" ]; then
        pass
      else
        fail "$RELATIVE_PATH runs a shell block with a syntax error, at line $BLOCK_LINE" \
          "$SYNTAX_ERRORS"
      fi
    done < <(extract_workflow_run_blocks "$WORKFLOW" "$EXTRACTION_DIRECTORY")

    # A "run:" written in a shape the extraction above does not know -- a folded
    # scalar, a quoted string -- would be dropped rather than reported, and this
    # case would stay green over the one block nobody had ever parsed. Counting
    # the keys is what turns that into a failure
    assert_equals "$DECLARED_BLOCKS" "$EXTRACTED_BLOCKS" \
      "every run: block of $RELATIVE_PATH has to be one this case can read"
  done < <(every_workflow_file)

  # Today every step of the publishing workflow is a "uses:", so there is no
  # shell in the tree to check. Said out loud rather than passed over : a case
  # that quietly verifies nothing is the one thing a green suite cannot show
  if [ "$DECLARED_ACROSS_THE_TREE" -eq 0 ]; then
    skip_test "no workflow step runs a shell block today, every step being a \"uses:\" action"
  fi
}

function test_every_action_a_workflow_uses_names_a_version() {
  # "uses: docker/build-push-action" with no "@" is refused by the runner, and
  # refused at the moment the workflow fires rather than when it is written --
  # which for this repository is the push that was meant to publish the image.
  # The version itself is Dependabot's business ; that there is one is this
  # case's
  local WORKFLOW RELATIVE_PATH ACTION
  local ACTIONS_READ=0
  while IFS= read -r WORKFLOW; do
    RELATIVE_PATH="${WORKFLOW#"$REPO_ROOT"/}"

    while IFS= read -r ACTION; do
      [ -n "$ACTION" ] || continue
      ACTIONS_READ=$((ACTIONS_READ + 1))

      # A local action ("./.github/actions/...") is the one form that carries no
      # version, being part of the same commit
      case "$ACTION" in
        ./*) pass; continue ;;
      esac

      assert_matches "$ACTION" '@[A-Za-z0-9._/-]+$' \
        "$RELATIVE_PATH uses \"$ACTION\" without naming a version, and the runner refuses that when it fires"
    done < <(sed -n 's/^[[:space:]-]*uses:[[:space:]]*\([^[:space:]#]*\).*$/\1/p' "$WORKFLOW")
  done < <(every_workflow_file)

  if [ "$ACTIONS_READ" -eq 0 ]; then
    fail "no \"uses:\" was found across the workflows, and the image is published by one"
  fi
}
