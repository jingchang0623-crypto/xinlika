#!/usr/bin/env python3
"""Validate App Store profiles and write ephemeral XcodeGen/export settings."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re

REQUIRED = (
    "APPLE_TEAM_ID", "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD",
    "IOS_APPSTORE_PROFILE_BASE64", "WATCH_APPSTORE_PROFILE_BASE64", "ASC_KEY_ID",
    "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_BASE64",
)
TARGETS = {"Shennao": "com.zaowuyun.shennao", "XinlikaWatch": "com.zaowuyun.shennao.watchkitapp"}


def validate_profile(profile, bundle_id, team_id, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise ValueError("Profile has no expiration date")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if expiry <= now:
        raise ValueError("Profile has expired")
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if (team_id not in profile.get("TeamIdentifier", [])
            or entitlements.get("com.apple.developer.team-identifier") != team_id):
        raise ValueError("Profile team does not match APPLE_TEAM_ID")
    if not any(entitlements.get("application-identifier") == f"{prefix}.{bundle_id}" for prefix in prefixes):
        raise ValueError("Profile does not match the exact app bundle identifier")
    if ("ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")
            or entitlements.get("get-task-allow", False)):
        raise ValueError("An App Store distribution profile is required")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", uuid):
        raise ValueError("Invalid profile UUID")
    return uuid


def check_inputs():
    missing = [key for key in REQUIRED if not os.environ.get(key)]
    if missing:
        raise ValueError("Missing GitHub secrets: " + ", ".join(missing))
    if not re.fullmatch(r"[A-Z0-9]{10}", os.environ["APPLE_TEAM_ID"]):
        raise ValueError("APPLE_TEAM_ID must contain 10 uppercase letters or digits")
    if not re.fullmatch(r"[A-Za-z0-9]+", os.environ["ASC_KEY_ID"]):
        raise ValueError("Invalid ASC_KEY_ID")


def prepare(directory, spec_path, build_number):
    check_inputs()
    if not re.fullmatch(r"[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}", build_number):
        raise ValueError("Build number must use Apple's numeric major.minor.patch format")
    team = os.environ["APPLE_TEAM_ID"]
    targets, profiles = {}, {}
    for target, bundle in TARGETS.items():
        with (directory / f"{target}.plist").open("rb") as handle:
            profile = plistlib.load(handle)
        uuid = validate_profile(profile, bundle, team)
        profiles[bundle] = uuid
        targets[target] = {"settings": {"base": {
            "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": team,
            "CODE_SIGN_IDENTITY": "Apple Distribution", "PROVISIONING_PROFILE_SPECIFIER": uuid,
        }}}
    # Stored beside project.yml so included source/config paths keep their meaning.
    spec_path.write_text(json.dumps({"include": ["project.yml"], "targets": targets,
        "settings": {"base": {"CURRENT_PROJECT_VERSION": build_number}}}))
    with (directory / "ExportOptions.plist").open("wb") as handle:
        plistlib.dump({"method": "app-store-connect", "destination": "upload", "teamID": team,
            "signingStyle": "manual", "signingCertificate": "Apple Distribution",
            "provisioningProfiles": profiles, "manageAppVersionAndBuildNumber": False,
            "uploadSymbols": True}, handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-inputs", action="store_true")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--spec", type=Path)
    parser.add_argument("--build-number")
    args = parser.parse_args()
    try:
        if args.check_inputs:
            check_inputs()
            print("All required signing secrets are present")
        elif args.directory and args.spec and args.build_number:
            prepare(args.directory, args.spec, args.build_number)
        else:
            parser.error("Provide --check-inputs or --directory, --spec and --build-number")
    except (ValueError, OSError, plistlib.InvalidFileException) as exc:
        parser.exit(2, str(exc) + "\n")


if __name__ == "__main__":
    main()
