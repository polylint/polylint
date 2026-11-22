#!/usr/bin/env bats
#
# Contract tests for plugin/scripts/mcp-launch.sh.
#
# This launcher pins the release it ships with (PINNED_VERSION) and has no npx or uvx tier.
#
# The suite tests strictly through the process boundary: it runs the script and asserts the
# exit status, which launcher was exec'd, and that argv arrives intact. Internal names never
# appear. Every parameter it needs is read out of the script in setup_file.
#
# The script exec()s, so the launcher it chooses BECOMES the process -- a stub that prints a
# marker is therefore direct evidence of the branch taken, not an inference from log text. ~keep

setup_file() {
	bats_load_library xberg-bats

	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
	SCRIPT="$REPO_ROOT/plugin/scripts/mcp-launch.sh"
	[ -f "$SCRIPT" ] || {
		echo "no plugin/scripts/mcp-launch.sh under $REPO_ROOT" >&2
		return 1
	}

	# Read the per-product parameters out of the script itself. Deriving them is what keeps
	# this file identical across repos; an empty derivation would silently turn most assertions
	# below into comparisons between two empty strings, so each one is checked. ~keep
	BINARY_NAME="$(sed -n 's/^BINARY_NAME="\(.*\)"$/\1/p' "$SCRIPT" | head -n 1)"
	PINNED_VERSION="$(sed -n 's/^PINNED_VERSION="\(.*\)"[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$SCRIPT" | head -n 1)"
	LAUNCHER_VAR="$(sed -n 's/^LAUNCHER="\${\([A-Z_]*\):-auto}"$/\1/p' "$SCRIPT" | head -n 1)"

	local name
	for name in BINARY_NAME PINNED_VERSION LAUNCHER_VAR; do
		[ -n "${!name}" ] || {
			echo "could not read ${name} out of ${SCRIPT}; the suite would assert nothing" >&2
			return 1
		}
	done

	# The launchers must be genuinely absent, not merely shadowed by a stub: the script decides
	# what to do by probing `command -v brew`, so a prepended stub directory cannot express "this
	# machine has no brew" and the probe would find the developer's real copy. The product binary
	# is excluded for the same reason -- a developer with it installed would otherwise take the
	# PATH branch in every test. ~keep
	xberg_shadow_system_path_without brew curl wget "$BINARY_NAME"

	export REPO_ROOT SCRIPT BINARY_NAME PINNED_VERSION LAUNCHER_VAR
}

setup() {
	bats_load_library xberg-bats
	xberg_setup_isolated

	PLUGIN_ROOT="$XBERG_WORK/plugin"
	mkdir -p "$PLUGIN_ROOT"
	LAUNCH_MODE="auto"
}

# Run the script in a clean environment with the isolated PATH.
#
# `env -i` rather than merely overriding PATH: the launcher reads CLAUDE_PLUGIN_ROOT and its own
# mode variable, and a developer who happens to export either would otherwise change the result
# of the suite on their machine only.
# XBERG_TRACE is forwarded explicitly. `env -i` strips it otherwise, and a trace stub whose
# output file is unset fails silently and writes nothing -- which makes xberg_assert_trace_empty
# pass whether or not the command was called. That is a test that cannot fail, so the variable is
# part of the contract of this helper rather than something a caller remembers. ~keep
launch() {
	run env -i \
		PATH="$(xberg_isolated_path)" \
		HOME="$XBERG_WORK/home" \
		XBERG_TRACE="$XBERG_TRACE" \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
		"${LAUNCHER_VAR}=${LAUNCH_MODE}" \
		"$SCRIPT" "$@"
}

# An executable that reports a version, announces itself, and echoes argv one line per argument.
#
# The unconditional `<marker>:ran` line answers "which binary was exec'd" even when the script is
# launched with no arguments; the per-argument lines answer "what argv arrived". Keeping them
# separate matters because joining argv with "$*" cannot tell `a b` from `"a b"`, which is
# exactly the pass-through bug this suite needs to be able to see. ~keep
make_cli() {
	local target="$1" marker="${2:-CLI}"
	mkdir -p "$(dirname "$target")"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		"if [ \"\$1\" = \"--version\" ]; then printf '%s\\n' \"${VERSION_REPORTED:-$PINNED_VERSION}\"; exit 0; fi" \
		"printf '${marker}:ran\\n'" \
		"for a in \"\$@\"; do printf '${marker}[%s]\\n' \"\$a\"; done" \
		'exit 0' >"$target"
	chmod +x "$target"
}

# An executable that refuses to report a version, which is how the script decides a binary it
# found is not usable.
make_broken_cli() {
	local target="$1"
	mkdir -p "$(dirname "$target")"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'if [ "$1" = "--version" ]; then exit 1; fi' \
		'printf "BROKEN:ran\n"' \
		'exit 0' >"$target"
	chmod +x "$target"
}

cached_binary() { printf '%s/bin/%s' "$PLUGIN_ROOT" "$BINARY_NAME"; }

# --- launcher selection -------------------------------------------------------------------------

@test "mcp-launch should_reject_an_unrecognised_launcher_value" {
	LAUNCH_MODE="wget-please"
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "invalid ${LAUNCHER_VAR}='wget-please'"
	xberg_assert_output_contains "auto|brew|download"
}

@test "mcp-launch should_accept_every_documented_launcher_value" {
	local mode
	for mode in auto brew download; do
		LAUNCH_MODE="$mode"
		launch
		# Each of these still fails -- nothing is installed -- but it must fail at the end, not
		# at the argument check. Asserting the absence of the validation error is what separates
		# "the mode is accepted" from "the mode happens to fail the same way". ~keep
		[[ "$output" != *"invalid ${LAUNCHER_VAR}"* ]] || {
			echo "mode '$mode' was rejected as invalid" >&2
			return 1
		}
	done
}

@test "mcp-launch should_report_installation_instructions_when_no_strategy_can_provide_a_binary" {
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "could not locate or install"
	xberg_assert_output_contains "brew install polylint/tap/polylint"
	xberg_assert_output_contains "cargo binstall"
}

# --- cached and PATH binaries -------------------------------------------------------------------

@test "mcp-launch should_exec_the_cached_binary_when_it_reports_a_version" {
	make_cli "$(cached_binary)" CACHED
	launch

	xberg_assert_status 0
	[[ "$output" == *"CACHED:ran"* ]]
}

@test "mcp-launch should_pass_arguments_through_to_the_cached_binary_verbatim" {
	make_cli "$(cached_binary)" CACHED
	launch --config "a b" --flag

	xberg_assert_status 0
	# One line per argument: "a b" must survive as a single argument, not become two.
	xberg_assert_output_contains "CACHED[--config]"
	xberg_assert_output_contains "CACHED[a b]"
	xberg_assert_output_contains "CACHED[--flag]"
}

@test "mcp-launch should_ignore_the_cached_binary_when_it_cannot_report_a_version" {
	make_broken_cli "$(cached_binary)"
	launch

	xberg_assert_status 1
	[[ "$output" != *"BROKEN:ran"* ]]
}

@test "mcp-launch should_exec_the_binary_on_path_when_there_is_no_cached_binary" {
	make_cli "$XBERG_STUB_BIN/$BINARY_NAME" ONPATH
	launch

	xberg_assert_status 0
	[[ "$output" == *"ONPATH:ran"* ]]
}

@test "mcp-launch should_ignore_a_path_binary_that_cannot_report_a_version" {
	make_broken_cli "$XBERG_STUB_BIN/$BINARY_NAME"
	launch

	xberg_assert_status 1
	[[ "$output" != *"BROKEN:ran"* ]]
}

@test "mcp-launch should_prefer_the_cached_binary_over_the_one_on_path" {
	make_cli "$(cached_binary)" CACHED
	make_cli "$XBERG_STUB_BIN/$BINARY_NAME" ONPATH
	launch

	xberg_assert_status 0
	[[ "$output" == *"CACHED:ran"* ]]
	[[ "$output" != *"ONPATH:ran"* ]]
}

# --- version gate -------------------------------------------------------------------------------

@test "mcp-launch should_ignore_a_cached_binary_older_than_the_pinned_version" {
	VERSION_REPORTED="0.0.1"
	make_cli "$(cached_binary)" CACHED
	launch

	xberg_assert_status 1
	[[ "$output" != *"CACHED:ran"* ]]
	xberg_assert_output_contains "older than the pinned ${PINNED_VERSION}"
}

@test "mcp-launch should_ignore_a_path_binary_older_than_the_pinned_version" {
	VERSION_REPORTED="0.0.1"
	make_cli "$XBERG_STUB_BIN/$BINARY_NAME" ONPATH
	launch

	xberg_assert_status 1
	[[ "$output" != *"ONPATH:ran"* ]]
}

@test "mcp-launch should_ignore_a_prerelease_of_the_pinned_version" {
	VERSION_REPORTED="${PINNED_VERSION}-rc.1"
	make_cli "$(cached_binary)" CACHED
	launch

	xberg_assert_status 1
	[[ "$output" != *"CACHED:ran"* ]]
}

@test "mcp-launch should_exec_a_binary_newer_than_the_pinned_version" {
	VERSION_REPORTED="999.0.0"
	make_cli "$(cached_binary)" CACHED
	launch

	xberg_assert_status 0
	[[ "$output" == *"CACHED:ran"* ]]
}

# --- brew ---------------------------------------------------------------------------------------

@test "mcp-launch should_install_through_brew_and_exec_what_it_put_on_path" {
	LAUNCH_MODE="brew"
	# A brew that actually delivers the binary, so the post-install PATH lookup has something to
	# find. Asserting only that `brew install` ran would pass against a script that never used
	# the result. ~keep
	xberg_stub brew \
		"cat >\"\$0.called\" <<<\"\$*\"" \
		"printf '%s\\n' '#!/usr/bin/env bash' 'if [ \"\$1\" = \"--version\" ]; then echo $PINNED_VERSION; exit 0; fi' 'for a in \"\$@\"; do printf \"BREWED[%s]\\\\n\" \"\$a\"; done' 'exit 0' >\"$XBERG_STUB_BIN/$BINARY_NAME\"" \
		"chmod +x \"$XBERG_STUB_BIN/$BINARY_NAME\"" \
		'exit 0'
	launch serve

	xberg_assert_status 0
	[[ "$output" == *"BREWED[serve]"* ]]
	xberg_assert_file "$XBERG_STUB_BIN/brew.called" "install polylint/tap/polylint"
}

@test "mcp-launch should_fall_through_when_brew_install_fails" {
	LAUNCH_MODE="brew"
	xberg_stub_exit brew 1
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "falling through"
}

# --- download -----------------------------------------------------------------------------------

@test "mcp-launch should_fall_through_when_the_platform_has_no_prebuilt_archive" {
	LAUNCH_MODE="download"
	xberg_stub uname \
		'case "$1" in' \
		'  -m) printf "sparc64\n" ;;' \
		'  *) printf "Plan9\n" ;;' \
		'esac'
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "falling through"
}

@test "mcp-launch should_fall_through_when_no_downloader_is_available" {
	LAUNCH_MODE="download"
	# curl and wget are both missing from the mirrored system path, which is the state this
	# branch exists for.
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "falling through"
}

# Build a release the way publish.yaml ships it: a flat archive holding the binary, and a
# sha256sums.txt whose entries carry a leading "./". A curl stub serves these files by name, so
# the launcher's real download, checksum and extraction code runs. ~keep
make_release() {
	local version="${1:-$PINNED_VERSION}" triple="x86_64-unknown-linux-gnu"
	RELEASE_DIR="$BATS_TEST_TMPDIR/release"
	ASSET="poly-${version}-${triple}.tar.gz"
	mkdir -p "$RELEASE_DIR/payload"
	make_cli "$RELEASE_DIR/payload/$BINARY_NAME" DOWNLOADED
	tar -czf "$RELEASE_DIR/$ASSET" -C "$RELEASE_DIR/payload" "$BINARY_NAME"
	SUM="$(shasum -a 256 "$RELEASE_DIR/$ASSET" | awk '{print $1}')"
	printf '%s  ./%s\n' "$SUM" "$ASSET" >"$RELEASE_DIR/sha256sums.txt"

	xberg_stub uname \
		'case "$1" in' \
		'  -m) printf "x86_64\n" ;;' \
		'  *) printf "Linux\n" ;;' \
		'esac'
	# Record every requested URL, then copy the fixture named by the URL's last path segment.
	xberg_stub curl \
		'out=""; url=""' \
		'while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done' \
		"printf '%s\\n' \"\$url\" >>\"$XBERG_STUB_BIN/curl.urls\"" \
		"cp \"$RELEASE_DIR/\${url##*/}\" \"\$out\""
}

@test "mcp-launch should_download_exactly_the_pinned_release_verify_it_and_exec_it" {
	LAUNCH_MODE="download"
	make_release
	launch serve

	xberg_assert_status 0
	xberg_assert_output_contains "checksum verified for $ASSET"
	xberg_assert_output_contains "DOWNLOADED[serve]"
	grep -qxF "https://github.com/Goldziher/poly/releases/download/v${PINNED_VERSION}/${ASSET}" "$XBERG_STUB_BIN/curl.urls"
	grep -qxF "https://github.com/Goldziher/poly/releases/download/v${PINNED_VERSION}/sha256sums.txt" "$XBERG_STUB_BIN/curl.urls"
	[ -x "$(cached_binary)" ]
}

@test "mcp-launch should_refuse_a_download_whose_checksum_does_not_match" {
	LAUNCH_MODE="download"
	make_release
	printf '%064d  ./%s\n' 0 "$ASSET" >"$RELEASE_DIR/sha256sums.txt"
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "checksum mismatch"
	[[ "$output" != *"DOWNLOADED:ran"* ]]
	[ ! -e "$(cached_binary)" ]
}

@test "mcp-launch should_refuse_a_download_with_no_checksum_entry_for_its_archive" {
	LAUNCH_MODE="download"
	make_release
	printf '%s  ./%s\n' "$SUM" "poly-other.tar.gz" >"$RELEASE_DIR/sha256sums.txt"
	launch

	xberg_assert_status 1
	xberg_assert_output_contains "refusing to execute an unverified binary"
	[[ "$output" != *"DOWNLOADED:ran"* ]]
	[ ! -e "$(cached_binary)" ]
}

# --- plugin root resolution ---------------------------------------------------------------------

@test "mcp-launch should_resolve_the_plugin_root_from_its_own_location_when_the_variable_is_unset" {
	# Without CLAUDE_PLUGIN_ROOT the script derives the plugin directory from BASH_SOURCE, so the
	# cached binary it looks for is the one in the repo's own plugin/bin. Asserting the derived
	# path directly would require writing into the working tree; asserting that it does NOT use
	# the temp root is the same claim without the side effect. ~keep
	make_cli "$(cached_binary)" CACHED
	run env -i \
		PATH="$(xberg_isolated_path)" \
		HOME="$XBERG_WORK/home" \
		"${LAUNCHER_VAR}=auto" \
		"$SCRIPT"

	[[ "$output" != *"CACHED:ran"* ]]
}
