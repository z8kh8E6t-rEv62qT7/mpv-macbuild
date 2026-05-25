#!/usr/bin/env python3
"""Delete stale user-owned NuGet package versions for the current repository."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


API_VERSION = "2022-11-28"


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
    return json.loads(payload)


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
        data = github_json(
            "GET",
            path,
            token,
            api_url,
            query,
        )
        if not isinstance(data, list):
            raise RuntimeError(f"Expected list response from {path}, got {type(data).__name__}")
        page_items = [item for item in data if isinstance(item, dict)]
        items.extend(page_items)
        if len(page_items) < 100:
            break
        page += 1
    return items


def version_sort_key(version: dict[str, object]) -> tuple[str, str, int]:
    updated = str(version.get("updated_at") or "")
    created = str(version.get("created_at") or "")
    version_id = int(version.get("id") or 0)
    return (updated, created, version_id)


def main() -> int:
    try:
        token = require_env("GITHUB_TOKEN")
        api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        owner = require_env("GITHUB_REPOSITORY_OWNER")
        repository = require_env("GITHUB_REPOSITORY").split("/", 1)[1]
        mode = require_env("NUGET_CACHE_MODE")
        feed_url = require_env("NUGET_FEED_URL")
        audit_dir = Path(require_env("AUDIT_DIR"))
        summary = Path(require_env("GITHUB_STEP_SUMMARY"))
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if mode != "readwrite":
        print("NuGet cleanup skipped because write mode is disabled.")
        return 0

    repo_fragment = f"/{owner}/{repository}/packages/"
    # This repository currently publishes user-owned NuGet packages, not org-owned ones.
    package_path = f"/users/{owner}/packages"

    try:
        packages = list_paginated_with_query(package_path, token, api_url, {"package_type": "nuget"})
    except urllib.error.HTTPError as exc:
        print(f"error: failed to list NuGet packages: HTTP {exc.code}", file=sys.stderr)
        return 1

    managed_packages = 0
    deleted_versions: list[dict[str, object]] = []
    skipped_packages: list[str] = []

    for package in packages:
        package_name = str(package.get("name") or "")
        if not package_name:
            continue

        versions_path = f"/users/{owner}/packages/nuget/{urllib.parse.quote(package_name, safe='')}/versions"
        try:
            versions = list_paginated(versions_path, token, api_url)
        except urllib.error.HTTPError as exc:
            print(
                f"error: failed to list versions for NuGet package {package_name}: HTTP {exc.code}",
                file=sys.stderr,
            )
            return 1

        if not versions:
            skipped_packages.append(package_name)
            continue

        linked_versions = [
            version
            for version in versions
            if repo_fragment in str(version.get("package_html_url") or "")
            or repo_fragment in str(version.get("html_url") or "")
        ]

        if not linked_versions:
            skipped_packages.append(package_name)
            continue

        managed_packages += 1
        linked_versions.sort(key=version_sort_key, reverse=True)
        keep = linked_versions[0]
        stale_versions = linked_versions[1:]

        for stale in stale_versions:
            version_id = int(stale.get("id") or 0)
            version_name = str(stale.get("name") or "")
            if version_id <= 0:
                continue
            delete_path = (
                f"/users/{owner}/packages/nuget/"
                f"{urllib.parse.quote(package_name, safe='')}/versions/{version_id}"
            )
            try:
                github_delete(delete_path, token, api_url)
            except urllib.error.HTTPError as exc:
                print(
                    f"error: failed to delete NuGet package {package_name} version {version_name}"
                    f" ({version_id}): HTTP {exc.code}",
                    file=sys.stderr,
                )
                return 1
            deleted_versions.append(
                {
                    "package": package_name,
                    "version": version_name,
                    "id": version_id,
                }
            )

    audit_dir.mkdir(parents=True, exist_ok=True)
    report_path = audit_dir / "nuget-cleanup.json"
    report = {
        "mode": mode,
        "feed_url": feed_url,
        "owner": owner,
        "repository": repository,
        "scanned_packages": len(packages),
        "managed_packages": managed_packages,
        "deleted_version_count": len(deleted_versions),
        "deleted_versions": deleted_versions,
        "skipped_package_count": len(skipped_packages),
        "skipped_packages": skipped_packages,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    with summary.open("a", encoding="utf-8") as handle:
        handle.write("## NuGet cleanup\n\n")
        handle.write(f"- mode: `{mode}`\n")
        handle.write(f"- feed: `{feed_url}`\n")
        handle.write(f"- scanned packages: {len(packages)}\n")
        handle.write(f"- managed packages: {managed_packages}\n")
        handle.write(f"- deleted stale versions: {len(deleted_versions)}\n")
        if deleted_versions:
            for item in deleted_versions:
                handle.write(
                    f"- deleted `{item['package']}` version `{item['version']}`"
                    f" (id={item['id']})\n"
                )
        else:
            handle.write("- deleted versions: none\n")

    print(
        f"NuGet cleanup complete: scanned {len(packages)} package(s), managed {managed_packages}, "
        f"deleted {len(deleted_versions)} stale version(s)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
