#!/usr/bin/env python3
"""Create and aggregate fail-closed native release-signing metadata."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


NATIVE_MODES = {"signed", "notarized", "ad-hoc", "unsigned", "not-applicable"}
TRUST_MODES = {"public-trust", "private-trust", "platform-key", "none", "not-applicable"}
ARTIFACT_MODES = {"none", "openpgp-detached"}
DELIVERY_MODES = {"installable", "re-signing-input", "deployment-artifact"}


def validate_record(record: dict[str, Any]) -> None:
    required_strings = ("platform", "architecture", "native_signing", "distribution_trust")
    for name in required_strings:
        if not isinstance(record.get(name), str) or not record[name]:
            raise ValueError(f"{name} must be a non-empty string")
    if record["native_signing"] not in NATIVE_MODES:
        raise ValueError(f"invalid native_signing: {record['native_signing']}")
    if record["distribution_trust"] not in TRUST_MODES:
        raise ValueError(f"invalid distribution_trust: {record['distribution_trust']}")
    if record.get("artifact_signing") not in ARTIFACT_MODES:
        raise ValueError(f"invalid artifact_signing: {record.get('artifact_signing')}")
    if record.get("delivery") not in DELIVERY_MODES:
        raise ValueError(f"invalid delivery: {record.get('delivery')}")

    native = record["native_signing"]
    trust = record["distribution_trust"]
    identity = record.get("identity")
    if native in {"signed", "notarized"} and (not isinstance(identity, str) or not identity):
        raise ValueError("signed/notarized artifacts require a non-empty identity")
    if native == "notarized" and trust != "public-trust":
        raise ValueError("notarized artifacts require public-trust")
    if native in {"unsigned", "ad-hoc"} and trust != "none":
        raise ValueError(f"{native} artifacts require distribution_trust=none")
    if native == "not-applicable" and trust != "not-applicable":
        raise ValueError("not-applicable native signing requires not-applicable trust")
    if record["artifact_signing"] == "openpgp-detached":
        fingerprint = record.get("artifact_signing_identity")
        if not isinstance(fingerprint, str) or len(fingerprint) not in {40, 64}:
            raise ValueError("OpenPGP signing requires a full fingerprint")

    artifacts = record.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("artifacts must be a non-empty list")
    if any(not isinstance(name, str) or not name or "/" in name or "\\" in name for name in artifacts):
        raise ValueError("artifact entries must be plain filenames")
    if len(artifacts) != len(set(artifacts)):
        raise ValueError("artifact entries must be unique")


def write_record(args: argparse.Namespace) -> None:
    artifact_directory = Path(args.artifact_directory)
    artifacts = sorted(
        path.name
        for path in artifact_directory.iterdir()
        if path.is_file() and not path.name.startswith("native-signing-")
    )
    record: dict[str, Any] = {
        "schema_version": 1,
        "platform": args.platform,
        "architecture": args.architecture,
        "native_signing": args.native_signing,
        "distribution_trust": args.distribution_trust,
        "identity": args.identity or None,
        "artifact_signing": args.artifact_signing,
        "artifact_signing_identity": args.artifact_signing_identity or None,
        "delivery": args.delivery,
        "artifacts": artifacts,
    }
    validate_record(record)
    output = Path(args.output)
    output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def aggregate(args: argparse.Namespace) -> None:
    asset_directory = Path(args.asset_directory)
    metadata_paths = sorted(asset_directory.glob("native-signing-*.json"))
    if not metadata_paths:
        raise ValueError("no native signing metadata files were found")

    records: list[dict[str, Any]] = []
    identities: set[tuple[str, str]] = set()
    claimed_artifacts: set[str] = set()
    for path in metadata_paths:
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("schema_version") != 1:
            raise ValueError(f"unsupported signing metadata schema in {path}")
        validate_record(record)
        key = (record["platform"], record["architecture"])
        if key in identities:
            raise ValueError(f"duplicate platform/architecture signing metadata: {key}")
        identities.add(key)
        for artifact in record["artifacts"]:
            if artifact in claimed_artifacts:
                raise ValueError(f"artifact is claimed by multiple signing records: {artifact}")
            if not (asset_directory / artifact).is_file():
                raise ValueError(f"recorded release artifact is missing: {artifact}")
            claimed_artifacts.add(artifact)
        records.append(record)

    manifest_path = Path(args.manifest)
    if manifest_path.parent.resolve() != asset_directory.resolve():
        raise ValueError("signing manifest must be inside the asset directory")
    expected_artifacts = {
        path.name
        for path in asset_directory.iterdir()
        if path.is_file()
        and path.name != manifest_path.name
        and not path.name.startswith("native-signing-")
    }
    unclaimed_artifacts = sorted(expected_artifacts - claimed_artifacts)
    if unclaimed_artifacts:
        raise ValueError(
            "release artifacts are missing signing metadata claims: "
            + ", ".join(unclaimed_artifacts)
        )

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["native_artifacts"] = sorted(
        records, key=lambda item: (item["platform"], item["architecture"])
    )
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "# Native signing status",
        "",
        (
            "Checksums and GitHub/Sigstore attestations apply in every mode. "
            "Native publisher trust is reported separately below."
        ),
        "",
        "| Platform | Architecture | Native mode | Distribution trust | Delivery |",
        "| --- | --- | --- | --- | --- |",
    ]
    for record in sorted(records, key=lambda item: (item["platform"], item["architecture"])):
        lines.append(
            f"| {record['platform']} | {record['architecture']} | "
            f"{record['native_signing']} | {record['distribution_trust']} | "
            f"{record['delivery']} |"
        )
    if any(record["delivery"] == "re-signing-input" for record in records):
        lines.extend(
            [
                "",
                (
                    "> Artifacts marked `re-signing-input` are not installable public releases. "
                    "Apply the target platform's signing/provisioning process before distribution."
                ),
            ]
        )
    Path(args.report).write_text("\n".join(lines) + "\n", encoding="utf-8")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subcommands = root.add_subparsers(dest="command", required=True)

    write = subcommands.add_parser("write")
    write.add_argument("--output", required=True)
    write.add_argument("--artifact-directory", required=True)
    write.add_argument("--platform", required=True)
    write.add_argument("--architecture", required=True)
    write.add_argument("--native-signing", required=True, choices=sorted(NATIVE_MODES))
    write.add_argument("--distribution-trust", required=True, choices=sorted(TRUST_MODES))
    write.add_argument("--identity", default="")
    write.add_argument("--artifact-signing", default="none", choices=sorted(ARTIFACT_MODES))
    write.add_argument("--artifact-signing-identity", default="")
    write.add_argument("--delivery", required=True, choices=sorted(DELIVERY_MODES))
    write.set_defaults(handler=write_record)

    collect = subcommands.add_parser("aggregate")
    collect.add_argument("--asset-directory", required=True)
    collect.add_argument("--manifest", required=True)
    collect.add_argument("--report", required=True)
    collect.set_defaults(handler=aggregate)
    return root


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
