#!/bin/bash

# ==============================================================================
# probe_container_privileges.sh -- find out which Docker privileges Dell OMSA
# actually needs, by measuring it on a real server.
#
# WHY THIS EXISTS
# ---------------
# ShaneMcC/docker-omsa#33 asks what --privileged is actually needed for.
# The maintainer's answer is that he has not looked into it himself, and nobody
# else has either: every published Dell OMSA container image
# (ShaneMcC/docker-omsa, kamermans/docker-openmanage,
# srcshelton/docker-dell-utilities) runs --privileged, and the one documented
# attempt at something narrower -- lovoo/ipmi_exporter issue #9, --device
# /dev/ipmi0 with no --privileged -- failed and was never resolved.
#
# One thing is known, and it shapes how the table below should be read. The
# maintainer posted the logs of a run without --privileged, and they show the
# entrypoint completing -- "Starting init..." -- three times inside the same
# second, with --restart=always doing the rest. So the first thing that fails is
# systemd as PID 1, before OMSA is reached at all. A rung whose "systemd" column
# fails has therefore said nothing about what OMSA needs : it has said what this
# packaging needs. The two questions are separate and only the second one needs
# a PowerEdge.
#
# So the honest state of the art is "nobody knows". A capability list invented
# from the capabilities(7) man page would be the worst possible answer to that:
# it would read as authoritative while never having touched a real machine, and
# the next person would build on it. This script measures instead of guessing.
# It starts the image under a ladder of progressively narrower Docker
# configurations and records, for each one, which OMSA capabilities still work.
#
# WHY IT CANNOT BE A CI JOB
# -------------------------
# The question is only answerable on hardware. A GitHub runner has no BMC, no
# IPMI character device and no PERC, so on a runner every rung of the ladder
# fails -- including --privileged -- and it fails for lack of hardware rather
# than for lack of privilege. The run would print a table of dashes that looks
# like a result and means nothing. The measurement therefore has to be taken by
# somebody who owns a PowerEdge, which is why this is an operator tool in
# tools/ rather than a workflow in .github/.
#
# HOW TO READ THE OUTPUT
# ----------------------
# Two markdown tables go to stdout. The first one is the ladder: which Docker
# flags each configuration id stands for. The second is the result: one row per
# configuration, one column per probe. The probes fail independently and a
# partial row is the interesting outcome -- "chassis works, storage does not"
# is the shape of an answer to ShaneMcC/docker-omsa#33, while "everything works" and "nothing
# works" are merely its two ends.
#
# Read it against two controls, one at each end of the ladder:
#
#   * the top rung is the README's own recipe. If a probe fails there, it fails
#     for a reason that has nothing to do with privilege, and the same probe
#     failing further down the ladder says nothing at all. Those cells are
#     marked with a dagger and should not be read as evidence.
#   * the bottom rung grants nothing whatsoever. Anything that passes there
#     passes without hardware access of any kind, so a pass higher up the
#     ladder is not evidence of anything either. "omreport about" is expected
#     to be in this category: it reports the installation, not the machine.
#
# Progress goes to stderr and the report goes to stdout, so
# "./tools/probe_container_privileges.sh > results.md" gives a file that can be
# pasted into ShaneMcC/docker-omsa#33 verbatim.
#
# SAFETY
# ------
# This is meant to be run on a production server, so: every container it starts
# carries a unique name and a run label and is removed on every exit path,
# interrupt included; it refuses to start if a name collides; it never touches
# a running omsa container; it publishes no port; and it only ever runs
# "omreport", which reads. Nothing here invokes omconfig or any other verb that
# writes to the hardware, and a runtime guard refuses to execute a probe
# command that is not omreport.
#
# The one host-side effect it cannot avoid is the one the README recipe has
# anyway: on the privileged rungs OMSA may load its own kernel modules (dcdbas,
# dell_rbu) into the host kernel. That is what the documented recipe does every
# time it starts, and this script does not unload them afterwards, because
# unloading a module on a production host is a far larger intervention than
# loading one.
# ==============================================================================

# Deliberately not "set -e". Most of what this script runs is expected to fail:
# the failures *are* the measurement. Every command's status is examined where
# it is run, and an "errexit" that aborted the run on the first failing probe
# would defeat the entire purpose.
set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
# ':latest' and not ':dev-latest' on purpose : the measurement should describe
# what people actually pull, and a nightly rebuild moving underneath a run would
# make two rungs incomparable. --image overrides it.
readonly DEFAULT_IMAGE='shanemcc/docker-omsa:latest'
readonly CONTAINER_NAME_PREFIX='omsa-privilege-probe'
readonly CONTAINER_LABEL='omsa-privilege-probe'
readonly OMSA_WEB_PORT='1311'
readonly OMSA_USERNAME='probe'

# The modules worth reporting: the two OMSA loads itself, the IPMI stack the
# chassis probes go through, and the two RAID drivers whose ioctl node the
# storage probes go through.
readonly INTERESTING_MODULES=(dcdbas dell_rbu dell_smbios ipmi_msghandler ipmi_si ipmi_devintf ipmi_ssif megaraid_sas mpt3sas)

# Defaults, all overridable on the command line. The timeouts exist because a
# container that never comes up must not hang the run: every wait in this
# script is bounded, and a timeout is reported as its own result rather than
# being folded into "failed".
IMAGE="$DEFAULT_IMAGE"
IPMI_DEVICE='/dev/ipmi0'
MEGARAID_DEVICE='/dev/megaraid_sas_ioctl_node'
BOOT_TIMEOUT='60'
OMSA_TIMEOUT='90'
PROBE_TIMEOUT='30'
DOCKER_TIMEOUT='120'
MODULES_MOUNT_MODE='ro'
MOUNT_SYS='true'
DRY_RUN='false'
LIST_ONLY='false'
FORCE='false'
ONLY_RUNGS=''
LOG_DIRECTORY=''

# Run state.
RUN_ID=''
OMSA_PASSWORD=''
INTERRUPTED=''
REPORT_PRINTED='false'
HOST_MODULES=''
HOST_VENDOR='unknown'
HOST_PRODUCT='unknown'
HOST_KERNEL=''
DOCKER_VERSION='unknown'
IMAGE_REFERENCE=''
FORCED_PRECONDITIONS=''
CREATED_CONTAINERS=()

declare -A RESULT=()
declare -A DETAIL=()
declare -A RUNG_NOTE=()

# ------------------------------------------------------------------ messages --

# Progress narration goes to stderr so that stdout stays a clean markdown
# report that can be redirected straight into a file and pasted into the issue.
log() { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
out() { printf '%s\n' "$*"; }

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<USAGE
${SCRIPT_NAME} -- measure which Docker privileges Dell OMSA actually needs.

Starts the Dell OMSA image under a ladder of progressively narrower Docker
configurations, probes what still works in each one, and prints a markdown
table ready to paste into ShaneMcC/docker-omsa#33.

Usage:
  ${SCRIPT_NAME} [options]
  ${SCRIPT_NAME} --dry-run          # print the docker command lines, run nothing
  ${SCRIPT_NAME} --list             # print the ladder and exit

Options:
  --image REFERENCE     Image to probe (default: ${DEFAULT_IMAGE}).
  --ipmi-device PATH    Host IPMI character device (default: ${IPMI_DEVICE}).
                        Older kernels expose /dev/ipmi/0 or /dev/ipmidev/0.
  --megaraid-device PATH
                        PERC ioctl node (default: ${MEGARAID_DEVICE}).
                        Its rung is skipped when the node does not exist.
  --only IDS            Comma-separated rung ids to run (see --list). The
                        control rung is always run first regardless.
  --boot-timeout SEC    Seconds to wait for systemd inside the container
                        (default: ${BOOT_TIMEOUT}).
  --omsa-timeout SEC    Seconds to wait for OMSA's services to answer after
                        systemd is up (default: ${OMSA_TIMEOUT}).
  --probe-timeout SEC   Seconds any single probe may take (default: ${PROBE_TIMEOUT}).
  --modules-rw          Bind /lib/modules read-write, exactly as the README
                        recipe does. The default is read-only, because this
                        script does not write to the host; use this if, and
                        only if, the control rung fails and you suspect the
                        read-only mount is why.
  --no-sys-mount        Skip every rung that bind-mounts the host's /sys.
  --log-directory DIR   Where to keep the raw output of every probe
                        (default: a fresh directory under \${TMPDIR:-/tmp}).
  --force               Run even if the hardware preconditions fail. The report
                        then carries a warning saying its results are not
                        trustworthy, because they are not.
  --dry-run             Print every docker command line without running any.
  --list                Print the ladder and exit.
  -h, --help            This text.

Exit status:
  0  the run completed (whatever the probes found)
  1  refused to start, or the control rung failed
  130 interrupted
USAGE
}

# -------------------------------------------------------------------- ladder --

# The ladder. Ordered by decreasing privilege, and -- apart from the jump from
# privileged to capabilities, which is the whole question -- each rung differs
# from a neighbour in exactly one dimension, so that a difference in the results
# names the thing responsible for it.
readonly RUNG_IDS=(
	01-privileged-modules
	02-privileged
	03-caps3-ipmi-sys-modules
	04-caps3-ipmi-sys
	05-caps3-ipmi
	06-rawio-admin-ipmi-sys
	07-rawio-ipmi-sys
	08-admin-ipmi-sys
	09-rawio-ipmi-megaraid
	10-rawio-ipmi
	11-ipmi
	12-caps3-only
	13-admin-only
	14-nothing
)

# The control: the recipe the README tells people to use today. Everything else
# in the report is read as a difference from this row.
readonly CONTROL_RUNG='01-privileged-modules'

rung_label() {
	case "$1" in
	01-privileged-modules) printf '%s\n' 'privileged + /lib/modules (README recipe, control)' ;;
	02-privileged) printf '%s\n' 'privileged, no /lib/modules' ;;
	03-caps3-ipmi-sys-modules) printf '%s\n' 'RAWIO+ADMIN+MODULE, ipmi0, /sys, /lib/modules' ;;
	04-caps3-ipmi-sys) printf '%s\n' 'RAWIO+ADMIN+MODULE, ipmi0, /sys' ;;
	05-caps3-ipmi) printf '%s\n' 'RAWIO+ADMIN+MODULE, ipmi0' ;;
	06-rawio-admin-ipmi-sys) printf '%s\n' 'RAWIO+ADMIN, ipmi0, /sys' ;;
	07-rawio-ipmi-sys) printf '%s\n' 'RAWIO, ipmi0, /sys' ;;
	08-admin-ipmi-sys) printf '%s\n' 'ADMIN, ipmi0, /sys' ;;
	09-rawio-ipmi-megaraid) printf '%s\n' 'RAWIO, ipmi0 + PERC ioctl node' ;;
	10-rawio-ipmi) printf '%s\n' 'RAWIO, ipmi0' ;;
	11-ipmi) printf '%s\n' 'ipmi0 alone, no capability' ;;
	12-caps3-only) printf '%s\n' 'RAWIO+ADMIN+MODULE, no device, no mounts' ;;
	13-admin-only) printf '%s\n' 'SYS_ADMIN alone, no device, no mounts' ;;
	14-nothing) printf '%s\n' 'nothing at all (negative control)' ;;
	esac
}

# What each rung is for. This is the argument for the ladder's shape, and it is
# printed by --list so that the operator can read the reasoning before trusting
# the thing on a live server.
rung_rationale() {
	case "$1" in
	01-privileged-modules) printf '%s\n' 'The documented recipe. If this fails the host or the image is at fault and the rest of the run means nothing, so the run stops here.' ;;
	02-privileged) printf '%s\n' 'Removes only the modules mount, which is what tells you whether OMSA needs to load a module or merely to use one the host already loaded.' ;;
	03-caps3-ipmi-sys-modules) printf '%s\n' 'The jump under test: the three capabilities that privileged is usually a shorthand for, plus everything else privileged implies -- the device node, sysfs and the modules. The most generous non-privileged configuration there is.' ;;
	04-caps3-ipmi-sys) printf '%s\n' 'Same as above without /lib/modules: isolates module loading from module use, one rung further down.' ;;
	05-caps3-ipmi) printf '%s\n' 'Same again without the /sys bind mount: isolates what OMSA reads out of sysfs (DMI tables, PCI config space) from what it reads through the IPMI device.' ;;
	06-rawio-admin-ipmi-sys) printf '%s\n' 'Drops SYS_MODULE. If nothing changes against rung 04, the container was never loading a module in the first place.' ;;
	07-rawio-ipmi-sys) printf '%s\n' 'Drops SYS_ADMIN too. SYS_RAWIO is the one the PERC is expected to need, because the storage path goes through ioctls and raw PCI config space.' ;;
	08-admin-ipmi-sys) printf '%s\n' 'The mirror of rung 07 -- SYS_ADMIN instead of SYS_RAWIO. Comparing the two is what identifies which single capability carries the storage probes.' ;;
	09-rawio-ipmi-megaraid) printf '%s\n' 'SYS_RAWIO with the PERC ioctl node passed in as a device. This is the rung that could plausibly answer ShaneMcC/docker-omsa#33 for storage without any bind mount at all.' ;;
	10-rawio-ipmi) printf '%s\n' 'SYS_RAWIO and the IPMI device, nothing else: the smallest configuration that still grants a hardware capability.' ;;
	11-ipmi) printf '%s\n' 'The configuration lovoo/ipmi_exporter issue #9 tried and could not make work. Measuring it here settles what it does and does not buy.' ;;
	12-caps3-only) printf '%s\n' 'The first of two rungs that ask about systemd rather than about OMSA, and the only pair in this ladder that needs no Dell hardware at all: no device node, no bind mount, nothing the machine has to own. The maintainer reported the container looping without --privileged, and his logs show the entrypoint completing before it restarts, so it is systemd as PID 1 that is failing. Whether these three capabilities are enough for it is answerable on any host with a Docker daemon, including a virtual machine.' ;;
	13-admin-only) printf '%s\n' 'The same question with only SYS_ADMIN, which is the capability systemd is usually said to want. If this starts and rung 12 does too, the looping has a one-flag answer and it is separable from anything OMSA needs.' ;;
	14-nothing) printf '%s\n' 'The negative control. Whatever passes here passes with no hardware access whatsoever, so the same pass higher up the ladder is not evidence of anything.' ;;
	esac
}

# The docker arguments each rung adds, one per line. This is the single source
# of truth for the ladder: --dry-run prints what this builds, and a real run
# executes what this builds, so the two cannot drift apart.
rung_docker_arguments() {
	local modules_directory="/lib/modules/${HOST_KERNEL}"
	case "$1" in
	01-privileged-modules)
		printf '%s\n' '--privileged'
		printf '%s\n' '--volume' "${modules_directory}:${modules_directory}:${MODULES_MOUNT_MODE}"
		;;
	02-privileged)
		printf '%s\n' '--privileged'
		;;
	03-caps3-ipmi-sys-modules)
		printf '%s\n' '--cap-add' 'SYS_RAWIO' '--cap-add' 'SYS_ADMIN' '--cap-add' 'SYS_MODULE'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--volume' '/sys:/sys'
		printf '%s\n' '--volume' "${modules_directory}:${modules_directory}:${MODULES_MOUNT_MODE}"
		;;
	04-caps3-ipmi-sys)
		printf '%s\n' '--cap-add' 'SYS_RAWIO' '--cap-add' 'SYS_ADMIN' '--cap-add' 'SYS_MODULE'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--volume' '/sys:/sys'
		;;
	05-caps3-ipmi)
		printf '%s\n' '--cap-add' 'SYS_RAWIO' '--cap-add' 'SYS_ADMIN' '--cap-add' 'SYS_MODULE'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		;;
	06-rawio-admin-ipmi-sys)
		printf '%s\n' '--cap-add' 'SYS_RAWIO' '--cap-add' 'SYS_ADMIN'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--volume' '/sys:/sys'
		;;
	07-rawio-ipmi-sys)
		printf '%s\n' '--cap-add' 'SYS_RAWIO'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--volume' '/sys:/sys'
		;;
	08-admin-ipmi-sys)
		printf '%s\n' '--cap-add' 'SYS_ADMIN'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--volume' '/sys:/sys'
		;;
	09-rawio-ipmi-megaraid)
		printf '%s\n' '--cap-add' 'SYS_RAWIO'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		printf '%s\n' '--device' "${MEGARAID_DEVICE}"
		;;
	10-rawio-ipmi)
		printf '%s\n' '--cap-add' 'SYS_RAWIO'
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		;;
	11-ipmi)
		printf '%s\n' '--device' "${IPMI_DEVICE}"
		;;
	12-caps3-only)
		printf '%s\n' '--cap-add' 'SYS_RAWIO' '--cap-add' 'SYS_ADMIN' '--cap-add' 'SYS_MODULE'
		;;
	13-admin-only)
		printf '%s\n' '--cap-add' 'SYS_ADMIN'
		;;
	14-nothing) ;;
	esac
}

# A rung is skipped, rather than run and reported as a failure, when the host
# cannot offer what it asks for. A skip is not a result and must not read as one.
rung_skip_reason() {
	case "$1" in
	03-caps3-ipmi-sys-modules | 04-caps3-ipmi-sys | 06-rawio-admin-ipmi-sys | 07-rawio-ipmi-sys | 08-admin-ipmi-sys)
		[ "$MOUNT_SYS" = 'true' ] || printf '%s\n' 'the /sys bind mount was declined with --no-sys-mount'
		;;
	09-rawio-ipmi-megaraid)
		[ -e "$MEGARAID_DEVICE" ] || printf '%s does not exist on this host: no megaraid_sas driver, or a controller that does not use it\n' "$MEGARAID_DEVICE"
		;;
	esac
}

# -------------------------------------------------------------------- probes --

# One column of the results table each. They are listed in the order they run,
# which is also the order of increasing depth into the hardware.
readonly PROBE_KEYS=(start systemd about chassis temps storage_controller storage_pdisk web modules)

# The backticks in these headings are markdown code spans on their way to
# GitHub, not command substitution, and the single quotes are what keeps them
# literal all the way there. Same for every other quoted fragment of report
# prose below.
# shellcheck disable=SC2016
probe_heading() {
	case "$1" in
	start) printf '%s\n' 'Start' ;;
	systemd) printf '%s\n' 'systemd' ;;
	about) printf '%s\n' '`about`' ;;
	chassis) printf '%s\n' '`chassis`' ;;
	temps) printf '%s\n' '`temps`' ;;
	storage_controller) printf '%s\n' '`stor ctl`' ;;
	storage_pdisk) printf '%s\n' '`stor pd`' ;;
	web) printf '%s\n' "${OMSA_WEB_PORT}" ;;
	modules) printf '%s\n' 'Modules' ;;
	esac
}

# The omreport probes, as argv. Every one of them reads and only reads -- see
# assert_read_only_command, which refuses anything else at run time rather than
# relying on this list staying honest.
probe_command() {
	case "$1" in
	about) printf '%s\n' 'omreport' 'about' ;;
	chassis) printf '%s\n' 'omreport' 'chassis' ;;
	temps) printf '%s\n' 'omreport' 'chassis' 'temps' ;;
	storage_controller) printf '%s\n' 'omreport' 'storage' 'controller' ;;
	storage_pdisk) printf '%s\n' 'omreport' 'storage' 'pdisk' 'controller=0' ;;
	esac
}

# The hard rule of this tool, enforced rather than documented: it reads the
# hardware and never writes to it. omconfig, omupdate and the racadm verbs all
# change a live server's configuration, and none of them can answer the
# question this script exists to answer, so none of them may ever be executed
# from here -- including by a future edit that adds "just one" write probe.
is_read_only_command() {
	case "$1" in
	omreport) return 0 ;;
	*) return 1 ;;
	esac
}

# Checked once, at startup, in the shell that can actually stop the run. The
# per-probe check further down runs inside a command substitution, and an exit
# taken in a subshell kills the subshell and lets the run carry on -- so the
# guard that matters is this one, before anything has started.
verify_probe_commands_are_read_only() {
	local probe
	local -a command=()
	for probe in "${PROBE_KEYS[@]}"; do
		mapfile -t command < <(probe_command "$probe")
		[ "${#command[@]}" -gt 0 ] || continue
		is_read_only_command "${command[0]}" ||
			die "probe '${probe}' is defined as '${command[*]}'. This tool only ever runs omreport, which reads; it will not run '${command[0]}' against anybody's server"
	done
}

# The web probe runs inside the container rather than through a published port,
# because publishing 1311 on a production host would collide with the real
# omsa container the operator is probably already running. It takes the
# port as $1 so the number lives in exactly one place. curl is preferred
# because an HTTP status proves a server answered; the /dev/tcp fallback only
# proves something is listening, and is reported as the weaker result it is.
# shellcheck disable=SC2016  # This string is a script for the container's shell; $1 and $() must reach it unexpanded.
readonly WEB_PROBE_SCRIPT='
port="$1"
if command -v curl >/dev/null 2>&1; then
	code=$(curl --silent --insecure --output /dev/null --write-out "%{http_code}" --max-time 8 "https://127.0.0.1:${port}/" 2>/dev/null)
	if [ -n "${code}" ] && [ "${code}" != "000" ]; then
		printf "http %s\n" "${code}"
		exit 0
	fi
fi
if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
	printf "tcp\n"
	exit 0
fi
printf "closed\n"
exit 1
'

# ------------------------------------------------------- command line, setup --

parse_command_line() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--image)
			IMAGE="${2:-}"
			[ -n "$IMAGE" ] || die '--image needs a value'
			shift 2
			;;
		--ipmi-device)
			IPMI_DEVICE="${2:-}"
			[ -n "$IPMI_DEVICE" ] || die '--ipmi-device needs a value'
			shift 2
			;;
		--megaraid-device)
			MEGARAID_DEVICE="${2:-}"
			[ -n "$MEGARAID_DEVICE" ] || die '--megaraid-device needs a value'
			shift 2
			;;
		--only)
			ONLY_RUNGS="${2:-}"
			[ -n "$ONLY_RUNGS" ] || die '--only needs a value'
			shift 2
			;;
		--boot-timeout)
			BOOT_TIMEOUT="${2:-}"
			shift 2
			;;
		--omsa-timeout)
			OMSA_TIMEOUT="${2:-}"
			shift 2
			;;
		--probe-timeout)
			PROBE_TIMEOUT="${2:-}"
			shift 2
			;;
		--log-directory)
			LOG_DIRECTORY="${2:-}"
			[ -n "$LOG_DIRECTORY" ] || die '--log-directory needs a value'
			shift 2
			;;
		--modules-rw)
			MODULES_MOUNT_MODE='rw'
			shift
			;;
		--no-sys-mount)
			MOUNT_SYS='false'
			shift
			;;
		--force)
			FORCE='true'
			shift
			;;
		--dry-run)
			DRY_RUN='true'
			shift
			;;
		--list)
			LIST_ONLY='true'
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "unknown option '${1}' (try --help)" ;;
		esac
	done

	local value
	for value in "$BOOT_TIMEOUT" "$OMSA_TIMEOUT" "$PROBE_TIMEOUT"; do
		case "$value" in
		'' | *[!0-9]*) die "timeouts must be whole numbers of seconds, got '${value}'" ;;
		esac
	done

	# Validated here rather than where the list is used: selected_rungs is read
	# through "mapfile < <(...)", and a die() inside that subshell would end the
	# subshell and leave the run going with an empty ladder.
	local wanted rung known
	local -a requested=()
	[ -n "$ONLY_RUNGS" ] || return 0
	IFS=',' read -ra requested <<<"$ONLY_RUNGS"
	for wanted in ${requested[@]+"${requested[@]}"}; do
		known='false'
		for rung in "${RUNG_IDS[@]}"; do
			[ "$rung" = "$wanted" ] && known='true'
		done
		[ "$known" = 'true' ] || die "unknown rung id '${wanted}' (try --list)"
	done
}

# Read-only facts about the machine this is running on. Separated from the
# refusals below because --list has to work anywhere, including on the laptop
# somebody reads the ladder on before carrying it to the server.
collect_host_facts() {
	if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
		die "bash 4.2 or newer is required (this is ${BASH_VERSION})"
	fi
	command -v timeout >/dev/null 2>&1 || die 'coreutils "timeout" is required: every wait in this script is bounded by it'

	HOST_KERNEL="$(uname -r)"
	[ -r /sys/class/dmi/id/sys_vendor ] && HOST_VENDOR="$(tr -d '\r' </sys/class/dmi/id/sys_vendor)"
	[ -r /sys/class/dmi/id/product_name ] && HOST_PRODUCT="$(tr -d '\r' </sys/class/dmi/id/product_name)"

	# What the host kernel has loaded. Read once, here, because it is the
	# difference between "this probe failed because a capability was dropped"
	# and "this probe failed because the driver it needs is not on this host",
	# and the report has to be able to tell those two apart.
	if [ -r /proc/modules ]; then
		HOST_MODULES="$(awk '{print $1}' /proc/modules | tr '\n' ' ')"
	fi
}

# Everything that would make the run pointless is checked here, before a single
# container starts, so that the operator gets one clear sentence instead of a
# confusing failure eleven rungs in.
check_preconditions() {
	local fatal='false'

	# A run on something that is not a Dell cannot answer anything about OMSA,
	# and neither can a run on a Dell whose BMC is not exposed as a character
	# device.
	case "$HOST_VENDOR" in
	*Dell*) : ;;
	*)
		warn "this host reports its vendor as '${HOST_VENDOR}', not Dell: OMSA has nothing to talk to here"
		fatal='true'
		FORCED_PRECONDITIONS="${FORCED_PRECONDITIONS}the host is not a Dell (${HOST_VENDOR}); "
		;;
	esac

	if [ ! -e "$IPMI_DEVICE" ]; then
		warn "${IPMI_DEVICE} does not exist. On the host, the ipmi_si and ipmi_devintf modules create it; older kernels name it /dev/ipmi/0 or /dev/ipmidev/0 (--ipmi-device)"
		fatal='true'
		FORCED_PRECONDITIONS="${FORCED_PRECONDITIONS}${IPMI_DEVICE} is missing; "
	fi

	local module
	for module in dcdbas ipmi_devintf megaraid_sas; do
		case " ${HOST_MODULES} " in
		*" ${module} "*) : ;;
		*) warn "the host kernel has no ${module} module loaded: failures of the probes that need it are the host's doing, not the container's, and the report says so" ;;
		esac
	done

	if [ "$DRY_RUN" = 'true' ]; then
		# A dry run touches nothing, so a missing device or a foreign vendor
		# is worth saying out loud and not worth refusing over: reading the
		# ladder before trusting it is exactly what --dry-run is for.
		return 0
	fi

	if ! command -v docker >/dev/null 2>&1; then
		die 'docker is not on PATH. This tool drives the Docker CLI; there is nothing it can do without it'
	fi
	local docker_information
	if ! docker_information="$(timeout "$DOCKER_TIMEOUT" docker version --format '{{.Server.Version}}' 2>&1)"; then
		# Folded onto one line: the daemon's refusal is several lines, one of
		# them blank, and a die() message that starts with a newline reads as
		# though the tool had nothing to say.
		die "the Docker daemon is not answering: $(printf '%s\n' "$docker_information" | awk 'NF { printf "%s%s", separator, $0; separator = " " }')"
	fi
	DOCKER_VERSION="$docker_information"

	if [ "$fatal" = 'true' ] && [ "$FORCE" != 'true' ]; then
		die 'the hardware preconditions above are not met, so a run would measure nothing. Fix them, or pass --force and read the warning the report will carry'
	fi
	[ "$fatal" = 'true' ] && warn '--force given: continuing on a host that cannot answer the question. The report will say so.'

	# The image. Present locally is enough; otherwise pull it once, here,
	# rather than letting the first "docker run" pull it inside a timeout
	# that was sized for starting a container and not for a download.
	if ! timeout "$DOCKER_TIMEOUT" docker image inspect "$IMAGE" >/dev/null 2>&1; then
		log "Image ${IMAGE} is not present locally, pulling it..."
		if ! timeout 900 docker pull "$IMAGE" >&2; then
			die "cannot pull ${IMAGE}: fix that, or build it locally and pass --image"
		fi
	fi
	IMAGE_REFERENCE="$(timeout "$DOCKER_TIMEOUT" docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null)"
	[ -n "$IMAGE_REFERENCE" ] || IMAGE_REFERENCE="$IMAGE (no digest: locally built?)"

	# A name collision means a previous run died without cleaning up, or that
	# something else on this host uses the same prefix. Either way, refuse:
	# reusing a name would mean removing a container this script did not create.
	local leftovers
	leftovers="$(timeout "$DOCKER_TIMEOUT" docker ps --all --format '{{.Names}}' --filter "name=^${CONTAINER_NAME_PREFIX}" 2>/dev/null)"
	if [ -n "$leftovers" ]; then
		warn "containers from an earlier probe run are still here:"
		printf '%s\n' "$leftovers" >&2
		die "refusing to start. Remove them first:  docker rm --force \$(docker ps --all --quiet --filter label=${CONTAINER_LABEL})"
	fi
}

prepare_run() {
	RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$$"

	# A throwaway account that exists for as long as one container does. It is
	# random because the container joins the default bridge network with OMSA's
	# web server running on it, and it is never printed: --dry-run redacts it.
	OMSA_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
	if [ "${#OMSA_PASSWORD}" -lt 16 ]; then
		OMSA_PASSWORD="probe${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
	fi

	[ "$DRY_RUN" = 'true' ] && return 0

	if [ -z "$LOG_DIRECTORY" ]; then
		LOG_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/omsa-privilege-probe-XXXXXX")" || die 'cannot create a log directory'
	else
		mkdir -p "$LOG_DIRECTORY" || die "cannot create ${LOG_DIRECTORY}"
	fi
	log "Raw probe output will be kept in ${LOG_DIRECTORY}"
}

# ------------------------------------------------------ containers, lifecycle --

container_name_for() { printf '%s-%s-%s\n' "$CONTAINER_NAME_PREFIX" "$RUN_ID" "$1"; }

# Removal refuses any name this script did not mint. The running Dell_OMSA
# container an operator already has is the thing this guard exists to protect:
# it is never inspected, never stopped and never removed.
remove_probe_container() {
	local container="$1"
	case "$container" in
	"${CONTAINER_NAME_PREFIX}"*) : ;;
	*)
		warn "refusing to remove '${container}': not a probe container"
		return 1
		;;
	esac
	timeout "$DOCKER_TIMEOUT" docker rm --force --volumes "$container" >/dev/null 2>&1
}

# Reached from the EXIT trap, which is why shellcheck cannot see a caller.
# shellcheck disable=SC2317
cleanup() {
	local exit_code="$?"
	trap - EXIT INT TERM HUP

	if [ "${#CREATED_CONTAINERS[@]}" -gt 0 ]; then
		log "Removing ${#CREATED_CONTAINERS[@]} probe container(s)..."
		local container
		for container in "${CREATED_CONTAINERS[@]}"; do
			remove_probe_container "$container" || warn "could not remove ${container}; remove it by hand: docker rm --force ${container}"
		done
		CREATED_CONTAINERS=()
	fi

	# An interrupted run still knows things, and throwing them away would mean
	# running the whole ladder again to learn what it had already measured.
	if [ -n "$INTERRUPTED" ] && [ "$REPORT_PRINTED" = 'false' ] && [ "${#RESULT[@]}" -gt 0 ]; then
		log "Interrupted by SIG${INTERRUPTED}: printing what was measured before the interruption."
		print_report 'interrupted'
	fi

	exit "$exit_code"
}

# Reached from the INT, TERM and HUP traps, same as above.
# shellcheck disable=SC2317
on_signal() {
	INTERRUPTED="$1"
	exit "$2"
}

start_container() {
	local rung="$1" container_name="$2"
	local -a argv=()
	mapfile -t argv < <(build_run_argv "$rung" "$container_name" 'real')
	CREATED_CONTAINERS+=("$container_name")
	if ! timeout "$DOCKER_TIMEOUT" "${argv[@]}" >"${LOG_DIRECTORY}/${rung}.docker-run.log" 2>&1; then
		return 1
	fi
	return 0
}

build_run_argv() {
	local rung="$1" container_name="$2" password_mode="$3"
	local password_value
	local -a argv=()
	local -a rung_args=()

	if [ "$password_mode" = 'redact' ]; then
		# Shell-safe on purpose: --dry-run prints this line through printf
		# '%q', and anything with a space or an angle bracket in it comes out
		# smeared in backslashes and stops being a line you can read.
		password_value='REDACTED-random-string-generated-per-run'
	else
		password_value="$OMSA_PASSWORD"
	fi

	mapfile -t rung_args < <(rung_docker_arguments "$rung")

	# No published port: 1311 is probed from inside the container so that a
	# probe run never fights the operator's real omsa container for it.
	argv=(docker run --detach
		--name "$container_name"
		--label "${CONTAINER_LABEL}=${RUN_ID}"
		--env "OMSA_USER=${OMSA_USERNAME}"
		--env "OMSA_PASS=${password_value}"
		# Not a privilege and not under test : this image runs systemd as PID 1,
		# the README asks for it on every run, and without it systemd can fail
		# for a reason that has nothing to do with the rung. It therefore
		# belongs on every rung including the negative control, so that what
		# differs between two rows is only what the ladder meant to vary.
		--cgroupns private)
	argv+=(${rung_args[@]+"${rung_args[@]}"})
	argv+=("$IMAGE")

	printf '%s\n' "${argv[@]}"
}

container_is_running() {
	local state
	state="$(timeout "$DOCKER_TIMEOUT" docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)"
	[ "$state" = 'true' ]
}

# systemd is PID 1 in this image, so nothing OMSA does can work until it has
# booted. Bounded by --boot-timeout, and a timeout is reported as "t/o" rather
# than as a failure, because "never came up" and "came up broken" are different
# findings.
wait_for_systemd() {
	local container="$1"
	local deadline state now
	deadline="$(($(date +%s) + BOOT_TIMEOUT))"
	while :; do
		now="$(date +%s)"
		[ "$now" -lt "$deadline" ] || break
		if ! container_is_running "$container"; then
			printf 'exited\n'
			return 1
		fi
		state="$(timeout "$PROBE_TIMEOUT" docker exec "$container" systemctl is-system-running 2>/dev/null | tr -d '\r\n')"
		case "$state" in
		# "degraded" is the expected healthy answer here: this image starts a
		# systemd that has units it cannot run in a container, and OMSA does
		# not care.
		running | degraded)
			printf '%s\n' "$state"
			return 0
			;;
		maintenance | stopping)
			printf '%s\n' "$state"
			return 1
			;;
		esac
		sleep 3
	done
	printf 't/o\n'
	return 1
}

# OMSA's daemons come up well after systemd does, so a probe run immediately
# after boot reads as a failure that is really a race. Poll the cheapest
# omreport there is until it answers, bounded by --omsa-timeout.
wait_for_omsa() {
	local container="$1"
	local deadline now
	deadline="$(($(date +%s) + OMSA_TIMEOUT))"
	while :; do
		now="$(date +%s)"
		[ "$now" -lt "$deadline" ] || break
		container_is_running "$container" || return 1
		if timeout "$PROBE_TIMEOUT" docker exec "$container" omreport about >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
	done
	return 1
}

# --------------------------------------------------------------- running one --

# Turn an omreport invocation into one table cell. Three results, not two:
# "t/o" is kept apart from "fail" because a command that never returned and a
# command that returned an error are different findings, and omreport hanging
# on a device it cannot reach is a real and common shape of this failure.
#
# omreport is also not trustworthy about its exit status -- several subcommands
# print "Error! ..." and still exit 0 -- so the output is inspected as well.
classify_omreport_output() {
	local status="$1" output="$2"
	case "$status" in
	124 | 137)
		printf 't/o\n'
		return
		;;
	0) ;;
	*)
		printf 'fail\n'
		return
		;;
	esac
	case "$output" in
	*'Error!'* | *'Error :'* | *'Unable to'* | *'No controllers found'* | *'not supported'*)
		printf 'fail\n'
		;;
	'')
		printf 'fail\n'
		;;
	*) printf 'ok\n' ;;
	esac
}

# The first line worth quoting out of a probe's output, for the notes under the
# table. Truncated, because a note is a pointer to the log file and not a
# substitute for it.
summarise_output() {
	local line
	while IFS= read -r line; do
		case "$line" in
		'' | 'Error!') continue ;;
		esac
		printf '%.140s\n' "$line"
		return
	done <<<"$1"
	printf '(no output)\n'
}

run_omreport_probe() {
	local container="$1" probe="$2" logfile="$3"
	local -a command=()
	local output status

	mapfile -t command < <(probe_command "$probe")
	# Belt and braces: verify_probe_commands_are_read_only has already refused
	# to let the run start if this could fail, but nothing is executed here
	# until it has been checked again.
	if ! is_read_only_command "${command[0]}"; then
		printf 'refused\t%s is not a read-only command and was not run\n' "${command[0]}"
		return
	fi

	output="$(timeout "$PROBE_TIMEOUT" docker exec "$container" "${command[@]}" 2>&1)"
	status="$?"
	printf '%s\n' "$output" >"$logfile"

	# Verdict and detail come back on one line, tab-separated, rather than
	# through a global: every probe here is called as "$(...)", and a command
	# substitution is a subshell, so an assignment made inside one never
	# reaches the caller. That silently emptied the report's Notes section the
	# first time this was written.
	local verdict
	verdict="$(classify_omreport_output "$status" "$output")"
	if [ "$verdict" = 'ok' ]; then
		printf '%s\n' "$verdict"
	else
		printf '%s\t%s\n' "$verdict" "$(summarise_output "$output")"
	fi
}

probe_web_server() {
	local container="$1" logfile="$2"
	local output status
	output="$(timeout "$PROBE_TIMEOUT" docker exec "$container" bash -c "$WEB_PROBE_SCRIPT" 'omsa-web-probe' "$OMSA_WEB_PORT" 2>&1)"
	status="$?"
	printf '%s\n' "$output" >"$logfile"
	case "$status" in
	124 | 137) printf 't/o\n' ;;
	0) printf '%s\n' "${output%%$'\n'*}" ;;
	*)
		case "$output" in
		*closed*) printf 'closed\n' ;;
		*) printf 'fail\n' ;;
		esac
		;;
	esac
}

# Which of the modules that matter are visible from inside the container. The
# cell is "seen/loaded-on-host", so a host that never loaded megaraid_sas is
# not counted against the container. See the caveat this prints in the report:
# /proc/modules is not namespaced, so this measures visibility and not usability.
probe_visible_modules() {
	local container="$1" logfile="$2"
	local output status module seen=0 total=0 names=''

	output="$(timeout "$PROBE_TIMEOUT" docker exec "$container" sh -c 'lsmod 2>/dev/null || cat /proc/modules' 2>&1)"
	status="$?"
	printf '%s\n' "$output" >"$logfile"
	case "$status" in
	124 | 137)
		printf 't/o\n'
		return
		;;
	0) ;;
	*)
		printf -- '-\n'
		return
		;;
	esac

	for module in "${INTERESTING_MODULES[@]}"; do
		case " ${HOST_MODULES} " in
		*" ${module} "*) total="$((total + 1))" ;;
		*) continue ;;
		esac
		if printf '%s\n' "$output" | awk -v module="$module" '$1 == module { found = 1 } END { exit found ? 0 : 1 }'; then
			seen="$((seen + 1))"
			names="${names}${module} "
		fi
	done
	if [ -n "$names" ]; then
		printf '%s/%s\t%s\n' "$seen" "$total" "${names% }"
	else
		printf '%s/%s\n' "$seen" "$total"
	fi
}

# Split what a probe returned into the results table and the notes. Called in
# the caller's shell, which is the entire point: see run_omreport_probe.
record_probe_result() {
	local rung="$1" probe="$2" payload="$3"
	local verdict detail
	verdict="${payload%%$'\t'*}"
	RESULT["${rung}:${probe}"]="$verdict"
	if [ "$payload" != "$verdict" ]; then
		detail="${payload#*$'\t'}"
		[ -n "$detail" ] && DETAIL["${rung}:${probe}"]="$detail"
	fi
	return 0
}

forget_container() {
	local wanted="$1" container
	local -a remaining=()
	for container in ${CREATED_CONTAINERS[@]+"${CREATED_CONTAINERS[@]}"}; do
		[ "$container" = "$wanted" ] && continue
		remaining+=("$container")
	done
	CREATED_CONTAINERS=(${remaining[@]+"${remaining[@]}"})
}

run_rung() {
	local rung="$1"
	local container_name probe skip_reason systemd_state

	skip_reason="$(rung_skip_reason "$rung")"
	if [ -n "$skip_reason" ]; then
		for probe in "${PROBE_KEYS[@]}"; do RESULT["${rung}:${probe}"]='skip'; done
		RUNG_NOTE["$rung"]="not run: ${skip_reason}"
		log "Rung ${rung}: skipped, ${skip_reason}"
		return 0
	fi

	container_name="$(container_name_for "$rung")"
	log "Rung ${rung}: $(rung_label "$rung")"

	if ! start_container "$rung" "$container_name"; then
		RESULT["${rung}:start"]='fail'
		for probe in "${PROBE_KEYS[@]}"; do
			[ "$probe" = 'start' ] || RESULT["${rung}:${probe}"]='-'
		done
		RUNG_NOTE["$rung"]="the container could not be created: $(summarise_output "$(cat "${LOG_DIRECTORY}/${rung}.docker-run.log" 2>/dev/null)")"
		log "  the container could not be created -- see ${LOG_DIRECTORY}/${rung}.docker-run.log"
		forget_container "$container_name"
		return 0
	fi
	RESULT["${rung}:start"]='ok'

	systemd_state="$(wait_for_systemd "$container_name")"
	RESULT["${rung}:systemd"]="$systemd_state"
	log "  systemd: ${systemd_state}"

	# Only wait for OMSA's daemons if there is an init alive to start them.
	# Waiting 90 seconds for a container that is already gone is 90 seconds of
	# nothing, twelve times over.
	if [ "$systemd_state" = 'running' ] || [ "$systemd_state" = 'degraded' ]; then
		if ! wait_for_omsa "$container_name"; then
			RUNG_NOTE["$rung"]="systemd reached '${systemd_state}' but OMSA's services never answered within ${OMSA_TIMEOUT}s"
			log "  OMSA's services never answered within ${OMSA_TIMEOUT}s; probing anyway"
		fi
	fi

	# The probes run whatever happened above, because their errors are the
	# measurement. They are bounded individually, so a dead container costs one
	# probe timeout each and not an unbounded wait.
	if container_is_running "$container_name"; then
		for probe in about chassis temps storage_controller storage_pdisk; do
			record_probe_result "$rung" "$probe" \
				"$(run_omreport_probe "$container_name" "$probe" "${LOG_DIRECTORY}/${rung}.${probe}.log")"
			log "  ${probe}: ${RESULT["${rung}:${probe}"]}"
		done
		record_probe_result "$rung" 'web' "$(probe_web_server "$container_name" "${LOG_DIRECTORY}/${rung}.web.log")"
		record_probe_result "$rung" 'modules' "$(probe_visible_modules "$container_name" "${LOG_DIRECTORY}/${rung}.modules.log")"
		log "  port ${OMSA_WEB_PORT}: ${RESULT["${rung}:web"]}, modules: ${RESULT["${rung}:modules"]}"
	else
		for probe in about chassis temps storage_controller storage_pdisk web modules; do
			RESULT["${rung}:${probe}"]='-'
		done
		[ -n "${RUNG_NOTE["$rung"]:-}" ] || RUNG_NOTE["$rung"]='the container stopped before any probe could run'
		log '  the container is no longer running; no probe could be attempted'
	fi

	timeout "$DOCKER_TIMEOUT" docker logs --tail 200 "$container_name" >"${LOG_DIRECTORY}/${rung}.container.log" 2>&1

	# Removed as soon as its rung is done rather than at the end of the run:
	# twelve systemd containers alive at once on somebody's production server
	# is not a reasonable thing to ask of it.
	remove_probe_container "$container_name" || warn "could not remove ${container_name}"
	forget_container "$container_name"
}

# ------------------------------------------------------------------ reporting --

readonly FIELD_SEPARATOR=$'\037'

# How many columns a cell occupies once rendered. Not "${#field}": in a C
# locale that counts bytes, and the footnote dagger is one column written in
# three of them, which shears every row that carries one two columns short of
# the rest. Everything else in this report is ASCII, so folding the dagger back
# to a single byte is exactly right and costs nothing.
display_width() {
	local stripped="${1//†/+}"
	printf '%s' "${#stripped}"
}

# Pad the columns so the table is readable in a terminal as well as after
# GitHub renders it. Every row is a separator-joined field list; the first row
# is the heading.
render_table() {
	local -a rows=("$@")
	local -a widths=()
	local row field line index padding width

	# printf '%s\n', not '%s': without the trailing newline "read" discards the
	# last field of every row, which is how the ladder table silently lost its
	# widest column the first time this was written.
	for row in "${rows[@]}"; do
		index=0
		while IFS= read -r field; do
			width="$(display_width "$field")"
			[ "$width" -gt "${widths[index]:-0}" ] && widths["$index"]="$width"
			index="$((index + 1))"
		done < <(printf '%s\n' "$row" | tr "$FIELD_SEPARATOR" '\n')
	done

	local row_number=0
	for row in "${rows[@]}"; do
		line='|'
		index=0
		while IFS= read -r field; do
			# Padded by hand rather than with printf's own "%-*s", which
			# pads to a byte count and not to a column count.
			padding="$((${widths[index]:-0} - $(display_width "$field")))"
			[ "$padding" -lt 0 ] && padding=0
			line="${line} ${field}$(printf '%*s' "$padding" '') |"
			index="$((index + 1))"
		done < <(printf '%s\n' "$row" | tr "$FIELD_SEPARATOR" '\n')
		out "$line"
		if [ "$row_number" -eq 0 ]; then
			line='|'
			for index in "${!widths[@]}"; do
				line="${line} $(printf '%*s' "${widths[index]}" '' | tr ' ' '-') |"
			done
			out "$line"
		fi
		row_number="$((row_number + 1))"
	done
}

print_ladder_table() {
	local rung
	local -a rows=()
	local heading="id${FIELD_SEPARATOR}Configuration${FIELD_SEPARATOR}Docker arguments added"
	rows+=("$heading")
	for rung in "${RUNG_IDS[@]}"; do
		local -a rung_args=()
		local arguments
		mapfile -t rung_args < <(rung_docker_arguments "$rung")
		if [ "${#rung_args[@]}" -gt 0 ]; then
			arguments="${rung_args[*]}"
		else
			arguments='(none)'
		fi
		rows+=("${rung}${FIELD_SEPARATOR}$(rung_label "$rung")${FIELD_SEPARATOR}\`${arguments}\`")
	done
	render_table "${rows[@]}"
}

# A cell that the control rung also failed is not evidence about privilege: the
# probe was already broken before anything was taken away. Those get a dagger
# and a line in the legend, rather than being silently reported as failures.
# What counts as a pass, per column. Any HTTP status at all is one: OMSA's web
# interface answers 401 before it answers anything else, and the question here
# is whether a server was listening and talking, not what it said.
probe_result_is_pass() {
	case "$1" in
	ok | running | degraded | tcp | 'http '*) return 0 ;;
	*) return 1 ;;
	esac
}

cell_text() {
	local rung="$1" probe="$2"
	local value control_value
	value="${RESULT["${rung}:${probe}"]:--}"
	control_value="${RESULT["${CONTROL_RUNG}:${probe}"]:-}"
	case "$probe" in
	# "start", "systemd" and "modules" describe the container rather than the
	# hardware behind it, so a control that failed them does not make the same
	# column meaningless further down: a rung where the container will not even
	# start is a finding in its own right.
	start | systemd | modules) ;;
	*)
		case "$value" in
		# Nothing was measured in these cells, so there is nothing to qualify.
		'skip' | '-') ;;
		*)
			if [ "$rung" != "$CONTROL_RUNG" ] && [ -n "$control_value" ] &&
				! probe_result_is_pass "$control_value"; then
				value="${value} †"
			fi
			;;
		esac
		;;
	esac
	printf '%s\n' "$value"
}

print_results_table() {
	local rung probe
	local -a rows=()
	local heading="Configuration"
	for probe in "${PROBE_KEYS[@]}"; do
		heading="${heading}${FIELD_SEPARATOR}$(probe_heading "$probe")"
	done
	rows+=("$heading")
	for rung in ${ATTEMPTED_RUNGS[@]+"${ATTEMPTED_RUNGS[@]}"}; do
		local row="$rung"
		for probe in "${PROBE_KEYS[@]}"; do
			row="${row}${FIELD_SEPARATOR}$(cell_text "$rung" "$probe")"
		done
		rows+=("$row")
	done
	render_table "${rows[@]}"
}

ATTEMPTED_RUNGS=()

# Whether any cell in the table actually carries the dagger. Recomputed here
# rather than flagged while rendering, because every cell is rendered inside a
# command substitution and a flag set in one would not survive it.
dagger_in_use() {
	local probe control_value
	[ "${#ATTEMPTED_RUNGS[@]}" -gt 1 ] || return 1
	for probe in "${PROBE_KEYS[@]}"; do
		case "$probe" in
		start | systemd | modules) continue ;;
		esac
		control_value="${RESULT["${CONTROL_RUNG}:${probe}"]:-}"
		[ -n "$control_value" ] || continue
		probe_result_is_pass "$control_value" || return 0
	done
	return 1
}

# shellcheck disable=SC2016  # Backticks here are markdown code spans, kept literal on purpose.
print_legend() {
	out '<!-- Legend -->'
	out ''
	out '`ok` the probe answered; `fail` it ran and did not answer; `t/o` it did not return within the probe timeout; `-` not attempted, because nothing was running to attempt it on; `skip` the rung itself was not run (the notes say why).'
	out ''
	out 'The `systemd` column carries systemd'"'"'s own word for its state: `running` and `degraded` are both a healthy boot for this image, which ships units a container cannot run. The port column is `http NNN` when a server answered, `tcp` when the port accepted a connection but no HTTP client was available inside the container to ask it anything, and `closed` otherwise. The modules column is `N/M`: N of the M interesting modules the *host* has loaded were visible inside the container.'
	if dagger_in_use; then
		out ''
		out '† the control rung failed this probe too, so the cell says nothing about privilege. Read those columns as unmeasured rather than as failures.'
	fi
}

# shellcheck disable=SC2016  # Backticks here are markdown code spans, kept literal on purpose.
print_caveats() {
	out '### What this run cannot tell you'
	out ''
	out 'Stated plainly, because a table that hides its own limits is worse than no table.'
	out ''
	out '* **The modules column measures visibility, not usability.** `/proc/modules` is not namespaced, so a container sees the host'"'"'s loaded modules whatever privileges it was given. Expect this column to be near-constant down the ladder; what it is good for is showing which drivers were available *at all* during the run.'
	out '* **A failure of a probe the control rung also failed is not a privilege finding.** Those cells carry a dagger. They mean the probe was already broken before anything was taken away -- wrong controller index, a service that never started, hardware OMSA does not support -- and the raw logs are where that gets diagnosed.'
	out '* **systemd in a container is its own confound.** This image runs `/sbin/init` as PID 1, and systemd itself is one of the things `--privileged` makes easy. A rung where systemd never comes up has not shown that OMSA needs that privilege; it has shown that *this packaging* does. Running OMSA'"'"'s daemons directly, without systemd, is a separate experiment and a plausible other half of the answer to ShaneMcC/docker-omsa#33.'
	out "* **Port ${OMSA_WEB_PORT} is probed from inside the container**, because publishing it would collide with the real omsa container this host may be running. A pass means the web server answered, not that the host can reach it; publishing a port is orthogonal to privilege and needs no measurement."
	out '* **The result is this server.** A PowerEdge generation, a PERC model, an OMSA version and a host kernel. A capability that suffices here may not suffice on a machine three generations older, which is exactly why the table carries the model and kernel above rather than being quoted on its own.'
	if [ "$MODULES_MOUNT_MODE" = 'ro' ]; then
		out '* **The `/lib/modules` mounts were read-only**, where the README recipe leaves them writable. This tool does not write to the host. If the control rung is the only one that failed, re-run with `--modules-rw` before concluding anything.'
	fi

	local module
	for module in dcdbas ipmi_devintf megaraid_sas; do
		case " ${HOST_MODULES} " in
		*" ${module} "*) : ;;
		*) out "* **The host kernel had no \`${module}\` loaded during this run.** Every probe that needs it failed for the host's reasons, on every rung, and none of those failures is about privilege." ;;
		esac
	done
}

print_report() {
	local mode="$1"
	REPORT_PRINTED='true'

	out '## Dell OMSA container privilege probe'
	out ''
	out "Run on $(date -u '+%Y-%m-%d %H:%M:%S UTC') by \`tools/probe_container_privileges.sh\`, which starts the image under progressively narrower Docker configurations and records what still works. Issue #4."
	out ''
	out "* Server: \`${HOST_VENDOR} ${HOST_PRODUCT}\`"
	out "* Host kernel: \`${HOST_KERNEL}\`"
	out "* Docker: \`${DOCKER_VERSION}\`"
	out "* Image: \`${IMAGE_REFERENCE}\`"
	out "* Timeouts: boot ${BOOT_TIMEOUT}s, OMSA ${OMSA_TIMEOUT}s, probe ${PROBE_TIMEOUT}s"
	out "* Host modules loaded, of the ones that matter: \`$(
		module_list=''
		for module in "${INTERESTING_MODULES[@]}"; do
			case " ${HOST_MODULES} " in *" ${module} "*) module_list="${module_list}${module} " ;; esac
		done
		printf '%s' "${module_list:-none}"
	)\`"
	out ''

	case "$mode" in
	control-failed)
		out '> [!CAUTION]'
		out "> **The control rung failed, so this run measured nothing.** The README's own recipe (\`--privileged\` plus the \`/lib/modules\` mount) could not produce a working OMSA on this host, which means the host or the image is at fault and no narrower configuration could have told us anything. The ladder was not run. Fix the control first -- the raw logs say what happened -- then run this again."
		out ''
		;;
	interrupted)
		out '> [!WARNING]'
		out '> **This run was interrupted.** The rows below are what had been measured at that point; the rest of the ladder was not run.'
		out ''
		;;
	esac

	if [ -n "$FORCED_PRECONDITIONS" ]; then
		out '> [!WARNING]'
		out "> **\`--force\` was used on a host that failed its preconditions** (${FORCED_PRECONDITIONS%; }). Every result below is suspect, and a failure here is most likely the missing hardware rather than the dropped privilege."
		out ''
	fi

	out '### The ladder'
	out ''
	print_ladder_table
	out ''
	out '### Results'
	out ''
	print_results_table
	out ''
	print_legend
	out ''

	local rung note detail probe printed_note='false'
	for rung in ${ATTEMPTED_RUNGS[@]+"${ATTEMPTED_RUNGS[@]}"}; do
		note="${RUNG_NOTE["$rung"]:-}"
		local details=''
		for probe in "${PROBE_KEYS[@]}"; do
			detail="${DETAIL["${rung}:${probe}"]:-}"
			[ -n "$detail" ] || continue
			details="${details}  * \`${probe}\`: ${detail}"$'\n'
		done
		[ -n "$note" ] || [ -n "$details" ] || continue
		if [ "$printed_note" = 'false' ]; then
			out '### Notes'
			out ''
			printed_note='true'
		fi
		out "* **${rung}**${note:+ -- ${note}}"
		[ -n "$details" ] && printf '%s' "$details"
	done
	[ "$printed_note" = 'true' ] && out ''

	print_caveats
	out ''
	out "Raw output of every probe, and the container log of every rung, is in \`${LOG_DIRECTORY}\` on the machine this ran on."
}

print_ladder() {
	out '## The ladder'
	out ''
	print_ladder_table
	out ''
	out '### Why each rung is there'
	out ''
	local rung
	for rung in "${RUNG_IDS[@]}"; do
		out "* **${rung}** -- $(rung_rationale "$rung")"
	done
}

# --dry-run prints exactly what a real run would execute, built by the same
# function that a real run executes, so that reading it is a way of trusting
# the tool rather than a separate thing to keep in step with it.
# shellcheck disable=SC2016  # Backticks here are markdown code spans, kept literal on purpose.
print_dry_run() {
	out '## Dry run'
	out ''
	out "No container is started and no docker command is run. Below is every command line this tool would execute, in order, against \`${IMAGE}\` on \`${HOST_VENDOR} ${HOST_PRODUCT}\` (kernel \`${HOST_KERNEL}\`)."
	out ''
	if [ -n "$FORCED_PRECONDITIONS" ]; then
		out "A real run would refuse to start here: ${FORCED_PRECONDITIONS%; }. Pass \`--force\` to override, and read the warning the report will then carry."
		out ''
	fi

	local rung container_name probe skip_reason command_line
	local -a argv=() command=()
	for rung in "${RUNG_IDS[@]}"; do
		out "### ${rung} -- $(rung_label "$rung")"
		out ''
		out "$(rung_rationale "$rung")"
		out ''
		skip_reason="$(rung_skip_reason "$rung")"
		if [ -n "$skip_reason" ]; then
			out "Would be skipped: ${skip_reason}."
			out ''
			continue
		fi
		container_name="$(container_name_for "$rung")"
		out '```sh'
		mapfile -t argv < <(build_run_argv "$rung" "$container_name" 'redact')
		command_line="$(printf '%q ' "${argv[@]}")"
		out "${command_line% }"
		out "docker inspect --format '{{.State.Running}}' ${container_name}"
		out "docker exec ${container_name} systemctl is-system-running    # polled, up to ${BOOT_TIMEOUT}s"
		out "docker exec ${container_name} omreport about                 # polled, up to ${OMSA_TIMEOUT}s"
		for probe in about chassis temps storage_controller storage_pdisk; do
			mapfile -t command < <(probe_command "$probe")
			out "docker exec ${container_name} ${command[*]}"
		done
		out "docker exec ${container_name} bash -c '<connect to 127.0.0.1:${OMSA_WEB_PORT}>' omsa-web-probe ${OMSA_WEB_PORT}"
		out "docker exec ${container_name} sh -c 'lsmod 2>/dev/null || cat /proc/modules'"
		out "docker logs --tail 200 ${container_name}"
		out "docker rm --force --volumes ${container_name}"
		out '```'
		out ''
	done
	out 'Every one of those is a read. `omconfig` and every other verb that writes to the hardware is refused at run time, not merely left unused.'
}

# ---------------------------------------------------------------------- main --

selected_rungs() {
	if [ -z "$ONLY_RUNGS" ]; then
		printf '%s\n' "${RUNG_IDS[@]}"
		return
	fi
	# The ids were validated in parse_command_line; this only filters, in ladder
	# order rather than in the order they were typed.
	local wanted rung
	local -a requested=()
	IFS=',' read -ra requested <<<"$ONLY_RUNGS"
	for rung in "${RUNG_IDS[@]}"; do
		for wanted in ${requested[@]+"${requested[@]}"}; do
			[ "$rung" = "$wanted" ] && printf '%s\n' "$rung"
		done
	done
}

# The control has to produce a working OMSA, or nothing below it can be read.
# Note what this does *not* require: the control may well fail the storage or
# the chassis probes on a given machine, and the run continues, because the
# other columns are still measuring something. Only a control that cannot get
# OMSA answering at all makes the whole ladder meaningless.
control_is_usable() {
	[ "${RESULT["${CONTROL_RUNG}:start"]:-}" = 'ok' ] && [ "${RESULT["${CONTROL_RUNG}:about"]:-}" = 'ok' ]
}

main() {
	parse_command_line "$@"
	verify_probe_commands_are_read_only
	collect_host_facts

	# --list describes the ladder and touches nothing, so it answers on any
	# machine, before any precondition is even relevant.
	if [ "$LIST_ONLY" = 'true' ]; then
		print_ladder
		exit 0
	fi

	check_preconditions
	prepare_run

	if [ "$DRY_RUN" = 'true' ]; then
		print_dry_run
		exit 0
	fi

	# Installed before the first container exists, so that there is no window
	# in which an interrupt could leave one behind.
	trap 'on_signal INT 130' INT
	trap 'on_signal TERM 143' TERM
	trap 'on_signal HUP 129' HUP
	trap cleanup EXIT

	local -a rungs=()
	mapfile -t rungs < <(selected_rungs)

	log "${#rungs[@]} configuration(s) to run, up to about $(((${#rungs[@]} * (BOOT_TIMEOUT + OMSA_TIMEOUT)) / 60 + 1)) minutes in the worst case."
	log "Nothing here writes to the hardware: every probe is an omreport read."

	ATTEMPTED_RUNGS+=("$CONTROL_RUNG")
	run_rung "$CONTROL_RUNG"
	if ! control_is_usable; then
		log 'The control configuration could not produce a working OMSA. Stopping: no narrower configuration could tell us anything from here.'
		print_report 'control-failed'
		exit 1
	fi

	local rung
	for rung in "${rungs[@]}"; do
		[ "$rung" = "$CONTROL_RUNG" ] && continue
		ATTEMPTED_RUNGS+=("$rung")
		run_rung "$rung"
	done

	print_report 'complete'
	exit 0
}

main "$@"
