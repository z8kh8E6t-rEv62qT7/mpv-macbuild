#!/usr/bin/env python3
"""Expire user-owned NuGet package versions associated with the current repository."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path


API_VERSION = "2022-11-28"
MAX_PACKAGE_AGE_DAYS = 30
VALID_CLEANUP_ACTIONS = {"dry-run", "delete"}


@dataclass(frozen=True)
class PackageVersion:
    package_name: str
    version_id: int
    version_name: str
    created_at: datetime


@dataclass(frozen=True)
class SkippedPackage:
    name: str
    reason: str


@dataclass(frozen=True)
class DeleteFailure:
    version: PackageVersion
    detail: str


def require_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is not set")
    return value


def github_request(
    method: str,
    path: str,
    token: str,
    api_url: str,
    query: dict[str, str] | None = None,
) -> urllib.request.urlopen:
    url = f"{api_url.rstrip('/')}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
        },
    )
    return urllib.request.urlopen(request)


def github_json(
    method: str,
    path: str,
    token: str,
    api_url: str,
    query: dict[str, str] | None = None,
) -> object:
    with github_request(method, path, token, api_url, query) as response:
        payload = response.read().decode("utf-8")
    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"GitHub API returned invalid JSON for {path}") from exc


def github_delete(path: str, token: str, api_url: str) -> None:
    with github_request("DELETE", path, token, api_url):
        return


def list_paginated(path: str, token: str, api_url: str) -> list[dict[str, object]]:
    return list_paginated_with_query(path, token, api_url, {})


def list_paginated_with_query(
    path: str,
    token: str,
    api_url: str,
    base_query: dict[str, str],
) -> list[dict[str, object]]:
    page = 1
    items: list[dict[str, object]] = []
    while True:
        query = dict(base_query)
        query.update({"per_page": "100", "page": str(page)})
        data = github_json("GET", path, token, api_url, query)
        if not isinstance(data, list):
            raise RuntimeError(f"expected list response from {path}, got {type(data).__name__}")
        if any(not isinstance(item, dict) for item in data):
            raise RuntimeError(f"expected object entries in list response from {path}")
        items.extend(data)
        if len(data) < 100:
            break
        page += 1
    return items


def parse_github_timestamp(value: object, subject: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"{subject} has no created_at timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise RuntimeError(f"{subject} has invalid created_at timestamp: {value}") from exc
    if parsed.tzinfo is None:
        raise RuntimeError(f"{subject} has a timezone-free created_at timestamp")
    return parsed.astimezone(timezone.utc)


def repository_name(package: dict[str, object]) -> str:
    repository = package.get("repository")
    if not isinstance(repository, dict):
        return ""
    return str(repository.get("full_name") or "")


def select_managed_packages(
    packages: list[dict[str, object]],
    expected_repository: str,
) -> tuple[list[str], list[SkippedPackage]]:
    managed: list[str] = []
    skipped: list[SkippedPackage] = []
    seen_names: set[str] = set()

    for package in packages:
        name = str(package.get("name") or "")
        linked_repository = repository_name(package)
        display_name = name or "<unnamed>"

        if linked_repository != expected_repository:
            reason = (
                f"linked to {linked_repository}"
                if linked_repository
                else "missing repository metadata"
            )
            skipped.append(SkippedPackage(display_name, reason))
            continue
        if not name:
            skipped.append(SkippedPackage(display_name, "missing package name"))
            continue

        if name in seen_names:
            raise RuntimeError(f"GitHub API returned duplicate NuGet package {name}")
        seen_names.add(name)
        managed.append(name)

    managed.sort()
    skipped.sort(key=lambda package: package.name)
    return managed, skipped


def collect_package_versions(
    package_names: list[str],
    owner: str,
    token: str,
    api_url: str,
) -> list[PackageVersion]:
    collected: list[PackageVersion] = []
    seen_versions: set[tuple[str, int]] = set()

    for package_name in package_names:
        encoded_name = urllib.parse.quote(package_name, safe="")
        versions_path = f"/users/{owner}/packages/nuget/{encoded_name}/versions"
        try:
            versions = list_paginated(versions_path, token, api_url)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(
                f"failed to list versions for NuGet package {package_name}: HTTP {exc.code}"
            ) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(
                f"failed to list versions for NuGet package {package_name}: {exc.reason}"
            ) from exc

        for version in versions:
            version_name = str(version.get("name") or "")
            display_name = version_name or "<unnamed>"
            subject = f"NuGet package version {package_name}@{display_name}"
            version_id = version.get("id")
            if (
                not isinstance(version_id, int)
                or isinstance(version_id, bool)
                or version_id <= 0
            ):
                raise RuntimeError(f"{subject} has invalid id: {version_id!r}")
            if not version_name:
                raise RuntimeError(f"NuGet package {package_name} has a version with no name")

            version_key = (package_name, version_id)
            if version_key in seen_versions:
                raise RuntimeError(
                    f"GitHub API returned duplicate NuGet package version "
                    f"{package_name}@{version_name} ({version_id})"
                )
            seen_versions.add(version_key)
            collected.append(
                PackageVersion(
                    package_name=package_name,
                    version_id=version_id,
                    version_name=version_name,
                    created_at=parse_github_timestamp(version.get("created_at"), subject),
                )
            )

    collected.sort(
        key=lambda version: (
            version.created_at,
            version.package_name,
            version.version_name,
            version.version_id,
        )
    )
    return collected


def select_expired_versions(
    versions: list[PackageVersion],
    cutoff: datetime,
) -> list[PackageVersion]:
    return [version for version in versions if version.created_at < cutoff]


def execute_deletions(
    versions: list[PackageVersion],
    owner: str,
    token: str,
    api_url: str,
) -> tuple[list[PackageVersion], list[DeleteFailure]]:
    deleted: list[PackageVersion] = []
    failures: list[DeleteFailure] = []

    for version in versions:
        encoded_name = urllib.parse.quote(version.package_name, safe="")
        delete_path = (
            f"/users/{owner}/packages/nuget/{encoded_name}/versions/{version.version_id}"
        )
        try:
            github_delete(delete_path, token, api_url)
        except urllib.error.HTTPError as exc:
            failures.append(DeleteFailure(version, f"HTTP {exc.code}"))
        except urllib.error.URLError as exc:
            failures.append(DeleteFailure(version, f"network error: {exc.reason}"))
        else:
            deleted.append(version)

    return deleted, failures


def format_timestamp(value: datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def write_summary(
    summary: Path,
    action: str,
    feed_url: str,
    cutoff: datetime,
    scanned_count: int,
    managed_count: int,
    scanned_versions: int,
    expired: list[PackageVersion],
    skipped: list[SkippedPackage],
    deleted: list[PackageVersion],
    failures: list[DeleteFailure],
) -> None:
    with summary.open("a", encoding="utf-8") as handle:
        handle.write("## NuGet package expiration\n\n")
        handle.write(f"- action: `{action}`\n")
        handle.write(f"- feed: `{feed_url}`\n")
        handle.write(
            f"- retention: {MAX_PACKAGE_AGE_DAYS} days from package version `created_at`\n"
        )
        handle.write(f"- cutoff: `{format_timestamp(cutoff)}`\n")
        handle.write(f"- scanned account packages: {scanned_count}\n")
        handle.write(f"- managed repository packages: {managed_count}\n")
        handle.write(f"- scanned managed package versions: {scanned_versions}\n")
        handle.write(
            f"- retained managed package versions: {scanned_versions - len(expired)}\n"
        )
        handle.write(f"- expired package versions: {len(expired)}\n")
        handle.write(f"- deleted package versions: {len(deleted)}\n")
        handle.write(f"- failed deletions: {len(failures)}\n")
        handle.write(f"- skipped account packages: {len(skipped)}\n")

        if action == "dry-run":
            handle.write("\n### Expired package versions (dry run)\n\n")
            if not expired:
                handle.write("- none\n")
            for version in expired:
                handle.write(
                    f"- `{version.package_name}@{version.version_name}`: "
                    f"created `{format_timestamp(version.created_at)}`, "
                    f"id `{version.version_id}`\n"
                )
        else:
            handle.write("\n### Deleted package versions\n\n")
            if not deleted:
                handle.write("- none\n")
            for version in deleted:
                handle.write(
                    f"- `{version.package_name}@{version.version_name}`: "
                    f"created `{format_timestamp(version.created_at)}`, "
                    f"id `{version.version_id}`\n"
                )

        if failures:
            handle.write("\n### Failed deletions\n\n")
            for failure in failures:
                handle.write(
                    f"- `{failure.version.package_name}@{failure.version.version_name}` "
                    f"(id `{failure.version.version_id}`): {failure.detail}\n"
                )

        if skipped:
            handle.write("\n### Skipped account packages\n\n")
            for package in skipped:
                handle.write(f"- `{package.name}`: {package.reason}\n")


def write_error_summary(summary: Path, action: str, detail: str) -> None:
    with summary.open("a", encoding="utf-8") as handle:
        handle.write("## NuGet package expiration\n\n")
        handle.write(f"- action: `{action}`\n")
        handle.write(f"- error: {detail}\n")


def main() -> int:
    summary: Path | None = None
    action = os.environ.get("NUGET_CLEANUP_ACTION", "")
    try:
        summary = Path(require_env("GITHUB_STEP_SUMMARY"))
        token = require_env("GITHUB_TOKEN")
        api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        owner = require_env("GITHUB_REPOSITORY_OWNER")
        repository = require_env("GITHUB_REPOSITORY")
        mode = require_env("NUGET_CACHE_MODE")
        feed_url = require_env("NUGET_FEED_URL")
        action = require_env("NUGET_CLEANUP_ACTION")
        if action not in VALID_CLEANUP_ACTIONS:
            raise RuntimeError(f"unsupported NuGet cleanup action: {action}")
        if not repository.startswith(f"{owner}/"):
            raise RuntimeError(
                f"GITHUB_REPOSITORY {repository} is not owned by GITHUB_REPOSITORY_OWNER {owner}"
            )
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        if summary is not None:
            write_error_summary(summary, action or "unknown", str(exc))
        return 1

    if mode != "readwrite":
        print("NuGet cleanup skipped because write mode is disabled.")
        return 0

    cutoff = datetime.now(timezone.utc) - timedelta(days=MAX_PACKAGE_AGE_DAYS)
    package_path = f"/users/{owner}/packages"

    try:
        packages = list_paginated_with_query(
            package_path,
            token,
            api_url,
            {"package_type": "nuget"},
        )
        managed_packages, skipped = select_managed_packages(
            packages,
            repository,
        )
        versions = collect_package_versions(managed_packages, owner, token, api_url)
        expired = select_expired_versions(versions, cutoff)
    except urllib.error.HTTPError as exc:
        detail = f"GitHub API request failed with HTTP {exc.code}"
        print(f"error: {detail}", file=sys.stderr)
        write_error_summary(summary, action, detail)
        return 1
    except urllib.error.URLError as exc:
        detail = f"GitHub API request failed: {exc.reason}"
        print(f"error: {detail}", file=sys.stderr)
        write_error_summary(summary, action, detail)
        return 1
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        write_error_summary(summary, action, str(exc))
        return 1

    deleted: list[PackageVersion] = []
    failures: list[DeleteFailure] = []
    if action == "delete":
        deleted, failures = execute_deletions(expired, owner, token, api_url)

    write_summary(
        summary=summary,
        action=action,
        feed_url=feed_url,
        cutoff=cutoff,
        scanned_count=len(packages),
        managed_count=len(managed_packages),
        scanned_versions=len(versions),
        expired=expired,
        skipped=skipped,
        deleted=deleted,
        failures=failures,
    )

    print(
        f"NuGet expiration complete: action={action}, scanned={len(packages)}, "
        f"managed_packages={len(managed_packages)}, scanned_versions={len(versions)}, "
        f"retained_versions={len(versions) - len(expired)}, "
        f"expired_versions={len(expired)}, "
        f"deleted_versions={len(deleted)}, failures={len(failures)}."
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
