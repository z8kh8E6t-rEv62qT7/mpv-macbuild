#!/usr/bin/env python3
"""Expire user-owned NuGet packages associated with the current repository."""

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
class ExpiredPackage:
    name: str
    updated_at: datetime
    version_count: int = 0


@dataclass(frozen=True)
class SkippedPackage:
    name: str
    reason: str


@dataclass(frozen=True)
class DeleteFailure:
    package: ExpiredPackage
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


def parse_github_timestamp(value: object, package_name: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"NuGet package {package_name} has no updated_at timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise RuntimeError(
            f"NuGet package {package_name} has invalid updated_at timestamp: {value}"
        ) from exc
    if parsed.tzinfo is None:
        raise RuntimeError(f"NuGet package {package_name} has a timezone-free updated_at timestamp")
    return parsed.astimezone(timezone.utc)


def repository_name(package: dict[str, object]) -> str:
    repository = package.get("repository")
    if not isinstance(repository, dict):
        return ""
    return str(repository.get("full_name") or "")


def select_expired_packages(
    packages: list[dict[str, object]],
    expected_repository: str,
    cutoff: datetime,
) -> tuple[int, list[ExpiredPackage], list[SkippedPackage]]:
    managed_count = 0
    expired: list[ExpiredPackage] = []
    skipped: list[SkippedPackage] = []

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

        updated_at = parse_github_timestamp(package.get("updated_at"), name)
        managed_count += 1
        if updated_at < cutoff:
            expired.append(ExpiredPackage(name=name, updated_at=updated_at))

    expired.sort(key=lambda package: (package.updated_at, package.name))
    skipped.sort(key=lambda package: package.name)
    return managed_count, expired, skipped


def count_expired_versions(
    packages: list[ExpiredPackage],
    owner: str,
    token: str,
    api_url: str,
) -> list[ExpiredPackage]:
    counted: list[ExpiredPackage] = []
    for package in packages:
        encoded_name = urllib.parse.quote(package.name, safe="")
        versions_path = f"/users/{owner}/packages/nuget/{encoded_name}/versions"
        try:
            versions = list_paginated(versions_path, token, api_url)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(
                f"failed to list versions for NuGet package {package.name}: HTTP {exc.code}"
            ) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(
                f"failed to list versions for NuGet package {package.name}: {exc.reason}"
            ) from exc
        counted.append(
            ExpiredPackage(
                name=package.name,
                updated_at=package.updated_at,
                version_count=len(versions),
            )
        )
    return counted


def execute_deletions(
    packages: list[ExpiredPackage],
    owner: str,
    token: str,
    api_url: str,
) -> tuple[list[ExpiredPackage], list[DeleteFailure]]:
    deleted: list[ExpiredPackage] = []
    failures: list[DeleteFailure] = []

    for package in packages:
        encoded_name = urllib.parse.quote(package.name, safe="")
        delete_path = f"/users/{owner}/packages/nuget/{encoded_name}"
        try:
            github_delete(delete_path, token, api_url)
        except urllib.error.HTTPError as exc:
            failures.append(DeleteFailure(package, f"HTTP {exc.code}"))
        except urllib.error.URLError as exc:
            failures.append(DeleteFailure(package, f"network error: {exc.reason}"))
        else:
            deleted.append(package)

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
    expired: list[ExpiredPackage],
    skipped: list[SkippedPackage],
    deleted: list[ExpiredPackage],
    failures: list[DeleteFailure],
) -> None:
    expired_versions = sum(package.version_count for package in expired)
    deleted_versions = sum(package.version_count for package in deleted)
    with summary.open("a", encoding="utf-8") as handle:
        handle.write("## NuGet package expiration\n\n")
        handle.write(f"- action: `{action}`\n")
        handle.write(f"- feed: `{feed_url}`\n")
        handle.write(f"- retention: {MAX_PACKAGE_AGE_DAYS} days from package `updated_at`\n")
        handle.write(f"- cutoff: `{format_timestamp(cutoff)}`\n")
        handle.write(f"- scanned account packages: {scanned_count}\n")
        handle.write(f"- managed repository packages: {managed_count}\n")
        handle.write(f"- retained managed packages: {managed_count - len(expired)}\n")
        handle.write(f"- expired packages: {len(expired)}\n")
        handle.write(f"- expired package versions: {expired_versions}\n")
        handle.write(f"- deleted packages: {len(deleted)}\n")
        handle.write(f"- deleted package versions: {deleted_versions}\n")
        handle.write(f"- failed deletions: {len(failures)}\n")
        handle.write(f"- skipped account packages: {len(skipped)}\n")

        if action == "dry-run":
            handle.write("\n### Expired packages (dry run)\n\n")
            if not expired:
                handle.write("- none\n")
            for package in expired:
                handle.write(
                    f"- `{package.name}`: updated `{format_timestamp(package.updated_at)}`, "
                    f"versions {package.version_count}\n"
                )
        else:
            handle.write("\n### Deleted packages\n\n")
            if not deleted:
                handle.write("- none\n")
            for package in deleted:
                handle.write(
                    f"- `{package.name}`: updated `{format_timestamp(package.updated_at)}`, "
                    f"versions {package.version_count}\n"
                )

        if failures:
            handle.write("\n### Failed deletions\n\n")
            for failure in failures:
                handle.write(f"- `{failure.package.name}`: {failure.detail}\n")

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
        managed_count, expired, skipped = select_expired_packages(
            packages,
            repository,
            cutoff,
        )
        expired = count_expired_versions(expired, owner, token, api_url)
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

    deleted: list[ExpiredPackage] = []
    failures: list[DeleteFailure] = []
    if action == "delete":
        deleted, failures = execute_deletions(expired, owner, token, api_url)

    write_summary(
        summary=summary,
        action=action,
        feed_url=feed_url,
        cutoff=cutoff,
        scanned_count=len(packages),
        managed_count=managed_count,
        expired=expired,
        skipped=skipped,
        deleted=deleted,
        failures=failures,
    )

    print(
        f"NuGet expiration complete: action={action}, scanned={len(packages)}, "
        f"managed={managed_count}, expired={len(expired)}, "
        f"expired_versions={sum(package.version_count for package in expired)}, "
        f"deleted={len(deleted)}, failures={len(failures)}."
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
