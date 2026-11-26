#!/usr/bin/env python3
"""Prepare a ZIP and signed appcast locally; never build or publish a release."""

import argparse
import base64
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FEED_URL = (
    "https://raw.githubusercontent.com/kleber-maia/helm/main/updates/appcast.xml"
)
DOWNLOAD_PREFIX = "https://github.com/kleber-maia/helm/releases/download/"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, capture=False):
    return subprocess.run(
        [str(arg) for arg in args], check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
    ).stdout


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def feed_items(path):
    return ET.parse(path).findall("./channel/item")


def version(item):
    return item.findtext(f"{{{SPARKLE}}}version")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True,
                        help="Already built, signed, final Helm.app")
    parser.add_argument("--sparkle", type=Path, required=True,
                        help="Extracted official Sparkle 2.10.1 distribution")
    parser.add_argument("--tag", required=True, help="e.g. v1.0b22")
    parser.add_argument("--account", required=True,
                        help="Existing Sparkle Keychain signing account")
    parser.add_argument("--notes", type=Path,
                        help="Optional HTML release notes to embed in the feed")
    args = parser.parse_args()

    require(re.fullmatch(r"v[0-9][0-9A-Za-z.]*", args.tag), "Invalid tag")
    app = args.app.resolve()
    info = read_plist(app / "Contents/Info.plist")
    build = info["CFBundleVersion"]
    require(app.name == "Helm.app", "Expected Helm.app")
    require(info["CFBundleIdentifier"] == "group.soft.HelmIDE",
            "Unexpected bundle identifier")
    require(args.tag == "v" + info["CFBundleShortVersionString"],
            "Tag must match the built app's marketing version")
    require(re.fullmatch(r"[1-9][0-9]*", build),
            "CFBundleVersion must be a positive, increasing integer")
    required_settings = {
        "SUFeedURL": FEED_URL,
        "SUEnableAutomaticChecks": True,
        "SUScheduledCheckInterval": 3600,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    for key, value in required_settings.items():
        require(info.get(key) == value, f"Unexpected {key} in built app")

    public_key = info.get("SUPublicEDKey", "")
    require(len(base64.b64decode(public_key, validate=True)) == 32,
            "SUPublicEDKey must be a base64-encoded 32-byte public key")
    distribution = args.sparkle.resolve()
    for framework in (distribution / "Sparkle.framework",
                      app / "Contents/Frameworks/Sparkle.framework"):
        require(read_plist(framework / "Resources/Info.plist")[
            "CFBundleShortVersionString"] == "2.10.1",
            f"Expected Sparkle exactly 2.10.1 at {framework}")
    tools = distribution / "bin"
    for name in ("generate_keys", "generate_appcast", "sign_update"):
        require((tools / name).is_file(), f"Missing Sparkle tool: {name}")
    output = ROOT / "build/releases" / args.tag
    require(not output.exists(), f"Refusing to overwrite {output}")
    if args.notes:
        require(args.notes.is_file(), "Release notes file does not exist")

    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(run("/usr/bin/lipo", "-archs", executable, capture=True).split() == ["arm64"],
            "Expected an Apple Silicon-only release executable")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    # -p only reads an existing public key; it never creates or exports keys.
    key = run(tools / "generate_keys", "--account", args.account, "-p",
              capture=True).strip()
    require(key == public_key, "Keychain signing key differs from bundled public key")

    previous_feed = ROOT / "updates/appcast.xml"
    previous_versions = set()
    if previous_feed.exists():
        run(tools / "sign_update", "--account", args.account,
            "--verify", previous_feed)
        previous_versions = {version(item) for item in feed_items(previous_feed)}
        require(all(v and v.isdecimal() and int(v) < int(build)
                    for v in previous_versions),
                "Build must increase beyond every published feed version")

    output.parent.mkdir(parents=True, exist_ok=True)
    # Failed generation/verification never replaces the public feed or leaves
    # publishable output. Only the fully verified directory is promoted.
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=output.parent) as tmp:
        staging = Path(tmp) / "release"
        staging.mkdir()
        archive = staging / f"Helm-{info['CFBundleShortVersionString']}-arm64.zip"
        feed = staging / "appcast.xml"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            app, archive)
        if previous_feed.exists():
            shutil.copyfile(previous_feed, feed)
        if args.notes:
            shutil.copyfile(args.notes, archive.with_suffix(".html"))
        run(tools / "generate_appcast", "--account", args.account,
            "--download-url-prefix", DOWNLOAD_PREFIX + args.tag + "/",
            "--maximum-deltas", "0", "--maximum-versions", "0",
            "--versions", build, "--embed-release-notes", staging)
        run(tools / "sign_update", "--account", args.account, "--verify", feed)
        items = feed_items(feed)
        require(previous_versions <= {version(item) for item in items},
                "Generated feed unexpectedly removed published versions")
        new_items = [item for item in items if version(item) == build]
        require(len(new_items) == 1, "Expected exactly one item for the new build")
        item = new_items[0]
        require(item.find(f"{{{SPARKLE}}}channel") is None,
                "Prereleases must remain in the default channel")
        require(item.find(f"{{{SPARKLE}}}releaseNotesLink") is None,
                "Release notes must be embedded, not separately hosted")
        enclosure = item.find("enclosure")
        require(enclosure is not None, "Missing archive enclosure")
        require(enclosure.get("url") == DOWNLOAD_PREFIX + args.tag + "/" + archive.name,
                "Archive URL must be the official tagged GitHub release ZIP")
        require(enclosure.get("length") == str(archive.stat().st_size),
                "Archive length mismatch")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
        require(bool(signature), "Missing archive EdDSA signature")
        run(tools / "sign_update", "--account", args.account,
            "--verify", archive, signature)
        staging.rename(output)
    print(f"Prepared {output}; nothing published and updates/appcast.xml unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError,
            subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release preparation stopped: {error}") from error
