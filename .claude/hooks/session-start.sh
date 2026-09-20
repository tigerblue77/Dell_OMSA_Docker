#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell OMSA Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# SessionStart hook for Claude Code on the web.
#
# What this repository is, and therefore what a session here owes : a Dockerfile that installs
# Dell OpenManage Server Administrator onto an AlmaLinux base, and a short POSIX sh entrypoint
# that configures OMSA and hands over to init. Two artefacts, two linters, and one build.
#
# THE BUILD IS THE ONE A SESSION CANNOT RUN, and it is the first thing worth knowing here rather
# than the last. Claude Code on the web has no Docker daemon and installing one is not on the
# table, but the docker binary IS on the PATH, so "docker build ." looks perfectly runnable right
# up to the moment it answers "cannot connect to the Docker daemon". Worse, the usual reflex of
# piping a long build into "tail" or "head" hides even that : the pipeline's status is its last
# command's, so the pipe exits 0 whatever docker did, and a session reports a build that never
# happened. A .github/ workflow builds the image on every pull request, so nothing is lost by
# leaving it out -- what costs is claiming it was done. Say plainly that it was not.
#
# What a session CAN run is the two linters, which is why this script exists.
#
# The first of them is shellcheck, over configure_and_run_Dell_OMSA.sh and over this file, and
# the remote image is not guaranteed to carry it. Installing it up front turns "push and find
# out" into a local run, which is one CI round trip saved per finding -- and the entrypoint is
# "#!/bin/sh" rather than bash, where the findings that matter are the ones a reader's eye is
# least likely to catch, because they are the constructs bash would have accepted.
#
# hadolint is the same argument applied to the other artefact, and it arrives by a different
# road : it is not in apt, in any distribution this image is likely to be built on. Upstream
# publishes one statically linked binary per release per architecture on GitHub, and that is the
# whole installation -- no package, no dependencies, no post-install. The apt block below cannot
# be asked to do it, so it gets its own, with its own failure that costs the session its
# Dockerfile linter rather than its start.
#
# jq is deliberately NOT installed. The sibling repository installs it because two of its test
# cases skip themselves without it ; nothing in THIS tree reads JSON -- not the entrypoint, not
# the workflow, not this hook, which pins its download rather than asking an API which version to
# take. An install with nothing behind it is decoration that a later session has to re-argue, so
# it is left out until something here actually needs it.
#
# Best-effort by design : neither linter is needed to read, edit or reason about this repository,
# so a package index or a release host that cannot be reached costs the session a linter, not its
# start.
#
# WHAT MAKES THAT PROMISE TRUE, rather than merely stated. This runs synchronously, so every
# second it spends is a second the session does not start, and four things had to be true before
# "costs the session a linter, not its start" was actually the case :
#
#   - apt is given a deadline. Unbounded, its own defaults are 120 s per connection with retries,
#     per source line. A mirror that refuses or fails DNS returns in seconds, but one that accepts
#     the connection and never answers - a filtering proxy, a half-open NAT, a wedged mirror -
#     does not : measured against a listener that accepts and never replies, "apt-get update"
#     blocked for 248 seconds. Both calls now carry acquire timeouts and sit under "timeout", and
#     .claude/settings.json gives the hook a budget larger than the sum of every deadline below,
#     so the script always gives up on its own terms before the platform kills it. A kill landing
#     inside dpkg is what leaves a container refusing every later apt operation until someone runs
#     "dpkg --configure -a" by hand, and the container state is cached, so that breakage would
#     persist across sessions rather than being retried from clean.
#
#   - "apt-get update" is told to treat a failed index as an error. It reports one as a warning
#     and exits 0 otherwise, which left the branch below dead in exactly the case it was written
#     for : the network could be down, nothing would say so, and the install would go on against
#     whatever index the image was built with.
#
#   - the messages that report a problem go to STDOUT. Claude Code feeds a hook's stdout into the
#     session and keeps stderr only on the non-zero-exit path, so a notice written to stderr
#     beside "exit 0" is the one combination the session never sees. Announcing success while
#     swallowing "you have no linter" is backwards : the failure is the half worth delivering,
#     since a session that does not know shellcheck is missing runs it, gets "command not found",
#     and pushes anyway.
#
#   - the downloaded binary is proved to run BEFORE it is given a name on the PATH, and never
#     written to that name directly. A transfer that is cut off midway leaves a plausible-looking
#     file, and a truncated 50 MB binary is still a file that "command -v hadolint" finds : the
#     idempotence check below would then skip the install for the rest of the container's life,
#     every session after this one inheriting a linter that only fails when it is run. So the
#     download lands on a temporary name, is made executable, is asked for its version there, and
#     is only renamed into place once it has answered. Whatever it answers is what gets printed,
#     rather than the version that was asked for : a session told "hadolint 2.15.1 installed"
#     because that is what the pin says has learnt nothing about what is actually on its PATH.

set -uo pipefail

# Local checkouts are the developer's own machine, with their own package manager and their own
# idea of what should be installed on it
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# WHOSE COPY OF THIS REPOSITORY THIS IS, which decides the block that follows it.
#
# This file is repository content : it is cloned with the tree, so a contributor working on their
# own FORK runs it exactly as the maintainer's session does. What the block below has to say is
# about this project's conventions -- an identity to commit under, an issue and pull request rule
# -- and none of it is addressed to them. Said there anyway, it does real harm rather than none :
# the sign-off alias puts THE MAINTAINER'S Developer Certificate of Origin attestation on work the
# maintainer has never seen, silently, and CONTRIBUTING.md says the opposite to a contributor in
# as many words -- "sign your own work, with your own name".
#
# The fork is visible in one command, in either URL form : "https://github.com/<owner>/..." and
# "git@github.com:<owner>/...". Lower-cased because a clone URL keeps whatever case was typed,
# while a GitHub login compares case-insensitively.
#
# Any other answer is treated as "not this repository", deliberately. A checkout with no origin,
# or with the remote under another name, loses what CLAUDE.md still carries in writing -- the
# belt, not the braces -- where the opposite default hands a stranger's session an identity and a
# rule that are not theirs.
#
# The login is this repository's maintainer, the same person the trailer below names : the address
# is that login's own GitHub noreply address, so the two cannot drift apart without the mismatch
# being visible in these four lines side by side.
#
# Everything the linters need is below this block and outside it, on purpose. A fork's session is
# not this project's to configure, but it is building the same image against the same two CI
# checks, so it gets the same tools.
readonly MAINTAINER_GITHUB_LOGIN="tigerblue77"

ORIGIN_URL=""
ORIGIN_URL="$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2> /dev/null)"
ORIGIN_URL="${ORIGIN_URL,,}"

IS_THIS_REPOSITORY=false
[[ "$ORIGIN_URL" == *"/${MAINTAINER_GITHUB_LOGIN,,}/"* ]] && IS_THIS_REPOSITORY=true
[[ "$ORIGIN_URL" == *":${MAINTAINER_GITHUB_LOGIN,,}/"* ]] && IS_THIS_REPOSITORY=true
readonly IS_THIS_REPOSITORY

if "$IS_THIS_REPOSITORY"; then
  # The two identities a commit made here carries, set before anything below can exit early : the
  # container state is cached once this has run, so a second session reaches the "already
  # installed" return and nothing after it.
  #
  # A commit has three identity fields, and they answer two different questions. WHO WROTE IT is
  # the author, and that is the tool : git log, git blame, git shortlog and GitHub's contributor
  # graph all read that field, so recording the tool anywhere else is not recording it. WHO
  # CERTIFIES IT is the Signed-off-by trailer -- CONTRIBUTING.md asks for "a real name and a
  # reachable address" and the DCO's own text is first-person, "I certify that", which a tool
  # cannot say -- so that one is the maintainer's. This repository is dual-licensed, and the
  # sign-off is precisely what records that a contribution could be offered under both arms, so a
  # trailer naming nobody who could make the statement is not a formality quietly skipped : it is
  # the commercial arm quietly becoming ungrantable.
  #
  # The confusion can be created in either direction. Left alone, a session writes "Signed-off-by:
  # Claude <noreply@anthropic.com>", a trailer that satisfies a checker while naming nobody.
  # Setting user.* to the maintainer repairs that trailer but moves the confusion into the author
  # field, where the log then says the maintainer typed what a tool wrote. Setting each field to
  # the identity it is actually asking about is what says both things at once.
  #
  # The trailer therefore cannot come from "git commit -s", which derives it from user.* -- the
  # very fields that have to stay the tool's. It is passed explicitly instead, wrapped in an alias
  # so that it is a command rather than something to remember : a rule that needs a human to
  # recall it every time is a rule that will be forgotten.
  #
  # /!\ Do not fold this into "trailer.<token>.key". That config does work -- with the key spelled
  # exactly "Signed-off-by", git supplies the ": " separator and a checker accepts the result --
  # but it fails invisibly when the key is spelled with the separator already in it.
  # "Signed-off-by: " (trailing space) emits a line that is byte-for-byte identical to a valid
  # sign-off, that "git log" displays normally and that %(trailers) lists, while a keyed read of
  # it returns empty : git stored the key WITH the separator, so a gate looking for
  # "Signed-off-by" finds nothing and refuses a commit whose message looks perfectly right. There
  # is no symptom to notice and nothing reports it. The alias carries the whole trailer as one
  # string instead, where a mistake shows up in the line itself.
  #
  # What this does not do is make the certification true by itself : the maintainer certifies by
  # reviewing and merging. It only stops either field from saying something else meanwhile. See
  # CONTRIBUTING.md, "Contributions written by an agent".
  #
  # Repository-local on purpose -- this is this project's rule, and nothing here should reach into
  # a configuration the session may share with other work
  readonly SIGN_OFF_NAME="Tigerblue77"
  readonly SIGN_OFF_EMAIL="37409593+tigerblue77@users.noreply.github.com"
  readonly AGENT_NAME="Claude"
  readonly AGENT_EMAIL="noreply@anthropic.com"

  if ! git -C "${CLAUDE_PROJECT_DIR:-.}" config user.name "$AGENT_NAME" 2> /dev/null ||
    ! git -C "${CLAUDE_PROJECT_DIR:-.}" config user.email "$AGENT_EMAIL" 2> /dev/null ||
    ! git -C "${CLAUDE_PROJECT_DIR:-.}" config alias.signoff "commit --trailer \"Signed-off-by: $SIGN_OFF_NAME <$SIGN_OFF_EMAIL>\"" 2> /dev/null; then
    echo "session-start : could not set the git identity and its sign-off alias, so a commit made here would be authored and signed off by the session's default rather than by the tool and the maintainer"
  fi

  # The other half of what a session here has to know before it touches GitHub, and the half there
  # is nothing to configure for : an issue and a pull request are not settings, they are created
  # through the platform's API with whatever the caller passes, and both fields are decided at
  # that call. A web session is told by its harness to open a pull request as a DRAFT, and told by
  # nobody to assign anything, so both end up at a value nobody here chose -- and the session that
  # would come back to repair them has ended by then.
  #
  # Neither buys anything in exchange. A draft cannot be merged until somebody converts it by
  # hand, so the state costs a click at exactly the moment its author wanted to merge and saves
  # nothing before then ; unassigned is quieter and costs the same way, one list further, since
  # the maintainer's Assigned list is where work is scheduled and what is not on it has to be
  # remembered instead.
  #
  # Said at the start of every session rather than left in CLAUDE.md alone, for the reason the
  # alias above exists : a rule that has to be recalled every time is a rule that gets forgotten.
  # CLAUDE.md carries the argument, this carries the reminder -- and it is printed before the
  # early return below, so the second session on a cached container is told too
  echo "session-start : an issue or pull request opened here is assigned to $MAINTAINER_GITHUB_LOGIN and is never a draft -- see CLAUDE.md, \"Conventions\""
else
  # Not silence, but the only sentence that is theirs rather than this repository's. An agent
  # working on a fork has an obligation of its own -- CONTRIBUTING.md requires a Signed-off-by on
  # every commit, in a contributor's own name -- and learning it here rather than from a refused
  # pull request is the same trade this script already makes by installing the linters up front :
  # one round trip saved
  echo "session-start : this is not $MAINTAINER_GITHUB_LOGIN's copy of the repository, so no identity and no issue or pull request convention has been set for it here -- sign your own work, with your own name, on every commit (CONTRIBUTING.md)"
fi

# Said to every session, on a fork as much as here, and said before the early return below so that
# the second session on a cached container hears it too. This is the one fact about this
# environment that costs something to discover late : the header above argues why, and the short
# version is that the binary exists, the daemon does not, and a piped build lies about both
echo "session-start : there is no Docker daemon in this environment -- \"docker build\" will answer \"cannot connect to the Docker daemon\", and piping it into \"tail\" or \"head\" makes it exit 0 anyway, so report the build as not run rather than as passed"

# Bounded so that a mirror which accepts a connection and then goes quiet cannot hold the session
# open : two acquire timeouts because a source line may be either scheme, one retry rather than
# apt's three, and an outer wall clock in case something below the acquire layer is what hangs
readonly APT_NETWORK_OPTIONS=(
  -o Acquire::http::Timeout=10
  -o Acquire::https::Timeout=10
  -o Acquire::Retries=1
)
readonly APT_DEADLINE_SECONDS=45

# The release this pins, and the three things that decided the number.
#
# It is PINNED rather than resolved from "/releases/latest" because resolving it needs the GitHub
# API, and this hook would then have a second network dependency, a second failure mode and a JSON
# parser to install, in order to be handed a version nobody had looked at. A pin is one line to
# bump, in a diff a human reads, which is the same reason the Dockerfile's own base image is worth
# pinning.
#
# It is a FULL version rather than a floating major because the whole binary is the tool : there
# is no package manager underneath to carry a security fix in sideways, so "whatever the latest
# release is today" buys nothing here except the chance that a session and CI disagree about what
# a rule means. When CI's own hadolint version moves, this moves with it, deliberately and in one
# place.
#
# 2.15.1 was the newest tag upstream published when this was written. Verified rather than
# assumed, the release and both of its Linux assets answering HTTP 200 at the URLs below, and the
# x86_64 one running and reporting "Haskell Dockerfile Linter 2.15.1".
readonly HADOLINT_VERSION="v2.15.1"
readonly HADOLINT_DEADLINE_SECONDS=60

# /usr/local/bin because it is the one directory on this image's PATH that is meant for exactly
# this : software the local administrator installed, that the distribution's package manager knows
# nothing about. It is already on the PATH ahead of /usr/bin, it is writable by the user this hook
# runs as, and nothing dpkg owns lives there -- so if hadolint ever does appear in apt, the two
# occupy different paths instead of overwriting each other's file. ~/.local/bin was the
# alternative and is worse on the first count alone : it is on the PATH of the shell that happens
# to have read a profile, which a hook's non-interactive child process has not.
readonly HADOLINT_INSTALL_DIRECTORY="/usr/local/bin"

# An array holding one package today, because what apt is asked for is a set : the install call,
# the messages and the report below all read it, and a second package arriving is then a word
# rather than a rewrite. hadolint is not in it and never will be -- it is not a package
MISSING_PACKAGES=()
command -v shellcheck > /dev/null 2>&1 || MISSING_PACKAGES+=("shellcheck")

HADOLINT_IS_MISSING=false
command -v hadolint > /dev/null 2>&1 || HADOLINT_IS_MISSING=true
readonly HADOLINT_IS_MISSING

# Idempotent : the container state is cached once this hook has run, so the second session onwards
# finds both linters already there and does nothing. Both halves are asked separately and the
# early return needs both, because they install by different routes and either can be the one that
# failed last time
if [ ${#MISSING_PACKAGES[@]} -eq 0 ] && ! "$HADOLINT_IS_MISSING"; then
  echo "session-start : shellcheck and hadolint are already installed"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
  echo "session-start : installing ${MISSING_PACKAGES[*]}"

  # APT::Update::Error-Mode=any is what makes this test mean anything : without it a refresh that
  # fetched nothing still exits 0, and the session would be told the index is current when it is
  # whatever the image was built with
  APT_OUTPUT=""
  if ! APT_OUTPUT="$(timeout "$APT_DEADLINE_SECONDS" apt-get update -qq \
    "${APT_NETWORK_OPTIONS[@]}" -o APT::Update::Error-Mode=any 2>&1)"; then
    echo "session-start : could not refresh the package index, installing against the one the image was built with"
    printf '%s\n' "$APT_OUTPUT" | tail -3
  fi

  # Its output is kept rather than discarded : "could not install" with no reason attached cannot
  # tell a dead network from an index too old to still name the version it offers, and those are
  # repaired differently
  APT_OUTPUT=""
  if ! APT_OUTPUT="$(timeout "$APT_DEADLINE_SECONDS" apt-get install -y --no-install-recommends \
    "${APT_NETWORK_OPTIONS[@]}" "${MISSING_PACKAGES[@]}" 2>&1)"; then
    echo "session-start : could not install ${MISSING_PACKAGES[*]}. Findings on the shell scripts will only surface in CI."
    printf '%s\n' "$APT_OUTPUT" | tail -5
  else
    for PACKAGE in "${MISSING_PACKAGES[@]}"; do
      if ! command -v "$PACKAGE" > /dev/null 2>&1; then
        echo "session-start : $PACKAGE reported installed but is not on the PATH"
        continue
      fi

      # The status is checked and only stdout is read, because a binary that is on the PATH and
      # cannot run is a real state : an installed shellcheck built against a newer glibc prints
      # "version `GLIBC_2.34' not found", and folding that into the version parse announces
      # "shellcheck 2.34 installed" to a session that in fact has nothing that runs
      VERSION_OUTPUT=""
      if ! VERSION_OUTPUT="$("$PACKAGE" --version 2> /dev/null)"; then
        echo "session-start : $PACKAGE is installed but does not run"
        continue
      fi

      VERSION=""
      VERSION="$(printf '%s' "$VERSION_OUTPUT" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

      if [ -n "$VERSION" ]; then
        echo "session-start : $PACKAGE $VERSION installed"
      else
        echo "session-start : $PACKAGE installed"
      fi
    done
  fi
fi

if "$HADOLINT_IS_MISSING"; then
  # Upstream publishes one asset per architecture, named for what "uname -m" reports on x86 and
  # for something else entirely on ARM : aarch64 is what the kernel calls it, arm64 is what the
  # release is called. Anything outside these two is not a case to guess at -- the asset name
  # would be a fabrication, and a 404 reported as "could not download" reads like a network
  # problem when it is in fact an architecture upstream does not ship
  HADOLINT_ARCHITECTURE=""
  case "$(uname -m)" in
    x86_64) HADOLINT_ARCHITECTURE="x86_64" ;;
    aarch64 | arm64) HADOLINT_ARCHITECTURE="arm64" ;;
  esac
  readonly HADOLINT_ARCHITECTURE

  if [ -z "$HADOLINT_ARCHITECTURE" ]; then
    echo "session-start : hadolint publishes no Linux binary for $(uname -m), so the Dockerfile linter is unavailable here and its findings will only surface in CI"
    exit 0
  fi

  echo "session-start : installing hadolint $HADOLINT_VERSION"

  # Made in the destination directory rather than in /tmp, so that the rename at the end is a
  # rename within one filesystem and not a copy : a copy can be interrupted halfway and leave the
  # destination holding a partial binary under its real name, which is the one outcome this whole
  # dance exists to prevent. The trap is what keeps that choice from littering /usr/local/bin with
  # a failed download's leftovers -- on every exit path, including the deadline expiring
  HADOLINT_DOWNLOAD_PATH=""
  if ! HADOLINT_DOWNLOAD_PATH="$(mktemp "$HADOLINT_INSTALL_DIRECTORY/hadolint.XXXXXXXX" 2> /dev/null)"; then
    echo "session-start : could not create a temporary file in $HADOLINT_INSTALL_DIRECTORY, so hadolint was not installed and its findings will only surface in CI"
    exit 0
  fi
  # shellcheck disable=SC2064 # expanded now on purpose : the path is fixed from here on, and a
  # trap that resolved it later would read a variable this script may have moved past
  trap "rm -f '$HADOLINT_DOWNLOAD_PATH'" EXIT

  # The same number given twice, to curl and to timeout, because they bound different things and
  # either can be the one that was needed : --max-time is curl's own idea of how long a transfer
  # may take, and the outer wall clock catches anything that hangs where curl is not counting.
  # --connect-timeout is the smaller of the two on purpose, for the same reason apt gets an acquire
  # timeout : a host that accepts a connection and then says nothing is the slow failure, and there
  # is no point waiting a full minute to find out. -f so that an HTTP error is an error rather than
  # an error page written to disk and made executable a moment later
  readonly HADOLINT_URL="https://github.com/hadolint/hadolint/releases/download/$HADOLINT_VERSION/hadolint-Linux-$HADOLINT_ARCHITECTURE"

  CURL_OUTPUT=""
  if ! CURL_OUTPUT="$(timeout "$HADOLINT_DEADLINE_SECONDS" curl -fsSL \
    --connect-timeout 10 --max-time "$HADOLINT_DEADLINE_SECONDS" \
    -o "$HADOLINT_DOWNLOAD_PATH" "$HADOLINT_URL" 2>&1)"; then
    echo "session-start : could not download hadolint from $HADOLINT_URL. The Dockerfile linter is unavailable here and its findings will only surface in CI."
    printf '%s\n' "$CURL_OUTPUT" | tail -3
    exit 0
  fi

  if ! chmod +x "$HADOLINT_DOWNLOAD_PATH" 2> /dev/null; then
    echo "session-start : downloaded hadolint but could not make it executable, so it was not installed and its findings will only surface in CI"
    exit 0
  fi

  # The proof, and the reason the file is still sitting under a temporary name : a transfer that
  # was cut off leaves a file that exists, has a plausible size and is not a hadolint. Asked for
  # its version here it says so, and nothing is renamed ; asked for it after the rename, the
  # answer arrives too late, because "command -v hadolint" already succeeds and every later
  # session on this cached container skips the install
  HADOLINT_VERSION_OUTPUT=""
  if ! HADOLINT_VERSION_OUTPUT="$("$HADOLINT_DOWNLOAD_PATH" --version 2> /dev/null)"; then
    echo "session-start : the downloaded hadolint does not run, so it was not installed and the Dockerfile linter's findings will only surface in CI"
    exit 0
  fi

  if ! mv "$HADOLINT_DOWNLOAD_PATH" "$HADOLINT_INSTALL_DIRECTORY/hadolint" 2> /dev/null; then
    echo "session-start : could not move hadolint into $HADOLINT_INSTALL_DIRECTORY, so the Dockerfile linter is unavailable here and its findings will only surface in CI"
    exit 0
  fi

  # What it answered, not what was asked for : the pin above says which release was fetched, and
  # this says which one is on the PATH. They should agree, and the way to notice that they do not
  # is to print the second rather than the first
  HADOLINT_REPORTED_VERSION=""
  HADOLINT_REPORTED_VERSION="$(printf '%s' "$HADOLINT_VERSION_OUTPUT" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

  if [ -n "$HADOLINT_REPORTED_VERSION" ]; then
    echo "session-start : hadolint $HADOLINT_REPORTED_VERSION installed in $HADOLINT_INSTALL_DIRECTORY"
  else
    echo "session-start : hadolint installed in $HADOLINT_INSTALL_DIRECTORY"
  fi
fi
