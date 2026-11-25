#!/usr/bin/env python3
# MISE description="Pin the plugin version to the Cargo.toml version (--check verifies, --expect X.Y.Z pins to a release)"
# USAGE flag "--check" help="Verify the plugin version tracks Cargo.toml without writing"
# USAGE flag "--expect <version>" help="Verify core, plugin and launcher pin all equal this version"
"""Sync the coding-agent plugin version to the core ``Cargo.toml`` version.

``ai-rulez generate --plugin`` renders every per-runtime plugin manifest under
``plugin/`` from ``plugin/.ai-rulez/config.plugins.toml``'s ``[plugin].version``. This script
keeps that single source pinned to the crate version in ``Cargo.toml`` (the repo's
version source of truth), the same way ``alef sync-versions`` pins the alef-managed
binding manifests. Run before ``mise run plugin:generate``;
freshness of the generated bundles themselves is enforced by ``ai-rulez verify
--plugin`` in CI, so this script only touches the config source.

Usage:
    mise run plugin:sync-version                 # apply
    mise run plugin:sync-version --check         # verify against Cargo.toml
    mise run plugin:sync-version --expect X.Y.Z  # verify core, plugin and launcher pin equal X.Y.Z

``--check`` answers "does plugin/ track core?" and is the gate CI runs on `main`.
``--expect`` additionally pins both to the version actually being released, so a
release cannot ship a plugin bundle that lags the tag it is built from. Both exit 1
on drift.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_CONFIG = ROOT / "plugin" / ".ai-rulez" / "config.plugins.toml"
if not PLUGIN_CONFIG.exists():
    PLUGIN_CONFIG = ROOT / "plugin" / ".ai-rulez" / "config.toml"
# ~keep Matches the `version` key of the `[plugin]` table only. The file also has a
# top-level ai-rulez schema `version = "4.0"` that must never be rewritten.
PLUGIN_VERSION_RE = re.compile(r'(\[plugin\][^\[]*?\nversion = ")([^"]*)(")', re.DOTALL)
LAUNCHER = ROOT / "plugin" / ".ai-rulez" / "scripts" / "mcp-launch.sh"
# ~keep The launcher pins the exact release it downloads and the minimum binary version it accepts,
# so it has to move with every release exactly like the plugin manifest does.
LAUNCHER_PIN_RE = re.compile(r'(?m)^(PINNED_VERSION=")([^"]*)(")')
SERVER_JSON = ROOT / "server.json"
NPM_PACKAGE_JSON = ROOT / "npm-package" / "package.json"
MCP_NAME = "io.github.polylint/polylint"
SYNC_HINT = (
    "run `mise run plugin:sync-version` and `mise run plugin:generate` to re-pin the plugin and regenerate its bundles"
)


def core_version() -> str:
    """Read the workspace crate version from ``Cargo.toml``."""
    text = (ROOT / "Cargo.toml").read_text(encoding="utf-8")
    match = re.search(r'(?m)^version = "([^"]+)"', text)
    if not match:
        sys.exit("could not read version from Cargo.toml")
    return match.group(1)


def plugin_version() -> str:
    """Read ``[plugin].version`` from the plugin config."""
    match = PLUGIN_VERSION_RE.search(PLUGIN_CONFIG.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"could not read [plugin].version from {PLUGIN_CONFIG.relative_to(ROOT)}")
    return match.group(2)


def launcher_pin() -> str:
    """Read ``PINNED_VERSION`` from the MCP launcher."""
    match = LAUNCHER_PIN_RE.search(LAUNCHER.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"could not read PINNED_VERSION from {LAUNCHER.relative_to(ROOT)}")
    return match.group(2)


def transform_launcher(version: str) -> tuple[str, str]:
    """Rewrite ``PINNED_VERSION`` in the launcher, failing when the line is absent."""
    original = LAUNCHER.read_text(encoding="utf-8")
    updated, substitutions = LAUNCHER_PIN_RE.subn(rf"\g<1>{version}\g<3>", original, count=1)
    if substitutions == 0:
        sys.exit(f"could not read PINNED_VERSION from {LAUNCHER.relative_to(ROOT)}")
    return original, updated


def server_json_versions() -> tuple[str, list[str]]:
    """Read the MCP Registry entry's ``version`` and each package ``version`` from ``server.json``."""
    data = json.loads(SERVER_JSON.read_text(encoding="utf-8"))
    return data["version"], [package["version"] for package in data["packages"]]


def transform_server_json(version: str) -> tuple[str, str]:
    """Rewrite the registry entry's ``version`` and every package ``version`` in ``server.json``."""
    original = SERVER_JSON.read_text(encoding="utf-8")
    data = json.loads(original)
    data["version"] = version
    for package in data["packages"]:
        package["version"] = version
    return original, json.dumps(data, indent=2) + "\n"


def mcp_name_problem() -> str | None:
    """Describe a mismatch between the registry name and the npm ``mcpName`` the registry verifies."""
    server_name = json.loads(SERVER_JSON.read_text(encoding="utf-8"))["name"]
    npm_name = json.loads(NPM_PACKAGE_JSON.read_text(encoding="utf-8")).get("mcpName")
    if server_name != MCP_NAME or npm_name != MCP_NAME:
        return f"server.json name={server_name!r} and npm-package/package.json mcpName={npm_name!r} must both be {MCP_NAME!r}"
    return None


def transform(version: str) -> tuple[str, str]:
    """Rewrite ``version`` inside the ``[plugin]`` table (not the top-level ai-rulez
    schema ``version = "4.0"``) of the plugin config. Uses the native/semver form,
    which is also what ai-rulez expects; ai-rulez renders the PEP 440 form for the
    Hermes wheel.
    """
    original = PLUGIN_CONFIG.read_text(encoding="utf-8")
    # ~keep Count the substitutions rather than letting the caller infer success from
    # `original != updated`. `re.sub` returns the subject unchanged when nothing matched, so
    # a drifted `[plugin]` table reads exactly like an already-synced one -- and the caller
    # treats "unchanged" as "in sync", which would make `--check`, the gate CI runs on main,
    # pass on a config this script can no longer write.
    updated, substitutions = PLUGIN_VERSION_RE.subn(rf"\g<1>{version}\g<3>", original, count=1)
    if substitutions == 0:
        sys.exit(f"could not find [plugin].version in {PLUGIN_CONFIG.relative_to(ROOT)}")
    return original, updated


def parse_expect(argv: list[str]) -> str | None:
    """Return the version passed to ``--expect``, or ``None`` when absent."""
    for index, arg in enumerate(argv):
        if arg == "--expect":
            if index + 1 >= len(argv):
                sys.exit("--expect requires a version argument")
            return argv[index + 1]
        if arg.startswith("--expect="):
            return arg.split("=", 1)[1]
    return None


def report_drift(expected: str, core: str, plugin: str, pin: str) -> int:
    """Print every version that disagrees with ``expected`` and fail."""
    print(f"plugin/core version drift — expected {expected}")
    if core != expected:
        print(f"  Cargo.toml [workspace.package].version -> {core}")
    if plugin != expected:
        print(f"  {PLUGIN_CONFIG.relative_to(ROOT)} [plugin].version -> {plugin}")
    if pin != expected:
        print(f"  {LAUNCHER.relative_to(ROOT)} PINNED_VERSION -> {pin}")
    entry, packages = server_json_versions()
    if entry != expected or any(version != expected for version in packages):
        print(f"  {SERVER_JSON.relative_to(ROOT)} version -> {entry}, packages -> {packages}")
    problem = mcp_name_problem()
    if problem:
        print(f"  {problem}")
    print(SYNC_HINT)
    return 1


def main() -> int:
    argv = sys.argv[1:]
    expect = parse_expect(argv)
    core = core_version()

    if expect is not None:
        plugin = plugin_version()
        pin = launcher_pin()
        entry, packages = server_json_versions()
        registry_ok = entry == expect and all(version == expect for version in packages)
        if core == expect and plugin == expect and pin == expect and registry_ok and mcp_name_problem() is None:
            print(f"plugin, launcher pin and core all at {expect}")
            return 0
        return report_drift(expect, core, plugin, pin)

    original, updated = transform(core)
    launcher_original, launcher_updated = transform_launcher(core)
    problem = mcp_name_problem()
    if problem:
        print(problem)
        return 1
    server_original, server_updated = transform_server_json(core)
    if original == updated and launcher_original == launcher_updated and server_original == server_updated:
        return 0
    if "--check" in argv:
        return report_drift(core, core, plugin_version(), launcher_pin())
    PLUGIN_CONFIG.write_text(updated, encoding="utf-8")
    LAUNCHER.write_text(launcher_updated, encoding="utf-8")
    SERVER_JSON.write_text(server_updated, encoding="utf-8")
    print(f"synced plugin version, launcher pin and server.json -> {core}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
