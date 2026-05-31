#!/usr/bin/env python3
"""Download orphan cleanup for Radarr/Sonarr.

Scans a download directory for media files with hard link count 1 (orphans),
optionally queries the Radarr/Sonarr API for context, and deletes them.
"""

import json
import os
import re
import shutil
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path


LOG_LEVELS = {"debug": 0, "information": 1, "warning": 2, "error": 3, "fatal": 4}
MIN_LOG_LEVEL = LOG_LEVELS.get(os.environ.get("LOG_LEVEL", "information").lower(), 1)


def clef_log(level, message_template, **kwargs):
    """Emit a CLEF-formatted JSON log line to stdout."""
    if LOG_LEVELS.get(level, 1) < MIN_LOG_LEVEL:
        return
    entry = {
        "@t": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "@l": level,
        "@mt": message_template,
    }
    entry.update(kwargs)
    print(json.dumps(entry), flush=True)


def get_config():
    """Read configuration from environment variables."""
    download_dir = os.environ.get("DOWNLOAD_DIR")
    api_url = os.environ.get("API_URL")
    api_key = os.environ.get("API_KEY")
    api_type = os.environ.get("API_TYPE")

    if not download_dir:
        clef_log("fatal", "DOWNLOAD_DIR environment variable is required")
        sys.exit(1)
    if not api_type or api_type not in ("radarr", "sonarr"):
        clef_log("fatal", "API_TYPE must be 'radarr' or 'sonarr'")
        sys.exit(1)

    return {
        "download_dir": download_dir,
        "api_url": api_url.rstrip("/") if api_url else None,
        "api_key": api_key,
        "api_type": api_type,
        "min_age_hours": int(os.environ.get("MIN_AGE_HOURS", "336")),
        "max_deletions": int(os.environ.get("MAX_DELETIONS", "20")),
        "min_file_size_mb": int(os.environ.get("MIN_FILE_SIZE_MB", "500")),
        "media_extensions": os.environ.get(
            "MEDIA_EXTENSIONS", "mkv,avi,mp4,m4v,ts,wmv"
        ).split(","),
        "dry_run": os.environ.get("DRY_RUN", "false").lower() == "true",
    }


def api_request(url, api_key):
    """Make a GET request to the Radarr/Sonarr API. Returns parsed JSON or None."""
    separator = "&" if "?" in url else "?"
    full_url = f"{url}{separator}apikey={api_key}"
    try:
        req = urllib.request.Request(full_url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError):
        return None


def find_media_files(download_dir, extensions, min_size_bytes):
    """Walk the download directory and yield media file paths that pass size/sample filters."""
    download_path = Path(download_dir)
    try:
        entries = list(download_path.iterdir())
    except OSError as e:
        clef_log("error", "Failed to list download directory", path=str(download_path), error=str(e))
        return

    for entry in entries:
        try:
            if entry.is_file():
                if entry.suffix.lstrip(".").lower() in extensions:
                    if _is_main_media_file(entry, min_size_bytes):
                        yield entry
            elif entry.is_dir():
                for media_file in entry.rglob("*"):
                    if media_file.is_file() and media_file.suffix.lstrip(".").lower() in extensions:
                        if _is_main_media_file(media_file, min_size_bytes):
                            yield media_file
        except OSError as e:
            clef_log("warning", "Failed to access entry, skipping", path=str(entry), error=str(e))


def _is_main_media_file(path, min_size_bytes):
    """Check if a media file is a main file (not a sample, and large enough)."""
    try:
        if path.stat().st_size < min_size_bytes:
            return False
    except OSError:
        return False
    path_lower = str(path).lower()
    if "sample" in path_lower:
        return False
    return True


def check_orphan(path, min_age_hours):
    """Check if a file is an orphan. Returns (is_orphan, link_count, age_hours) or None on error."""
    try:
        stat = path.stat()
    except OSError as e:
        clef_log("warning", "Failed to stat file, skipping", path=str(path), error=str(e))
        return None

    link_count = stat.st_nlink
    age_hours = (time.time() - stat.st_mtime) / 3600

    if link_count > 1:
        clef_log("debug", "Skipped file", path=str(path), reason=f"link_count={link_count}")
        return (False, link_count, age_hours)

    if age_hours < min_age_hours:
        clef_log("debug", "Skipped file", path=str(path), reason=f"age={age_hours:.0f}h < {min_age_hours}h")
        return (False, link_count, age_hours)

    return (True, link_count, age_hours)


def get_api_context(config, file_path):
    """Try to match a file to a movie/series via the API and get upgrade history."""
    if not config["api_url"] or not config["api_key"]:
        return None, "API not configured"

    try:
        if config["api_type"] == "radarr":
            return _get_radarr_context(config, file_path)
        else:
            return _get_sonarr_context(config, file_path)
    except Exception as e:
        return None, str(e)


def _get_radarr_context(config, file_path):
    """Match a file to a Radarr movie and get history."""
    movies = api_request(f"{config['api_url']}/api/v3/movie", config["api_key"])
    if movies is None:
        return None, "API unreachable"

    folder_name = file_path.parent.name if file_path.parent != Path(config["download_dir"]) else file_path.stem
    match = _fuzzy_match_title(folder_name, movies, "title")
    if not match:
        return None, "No matching movie found"

    history = api_request(
        f"{config['api_url']}/api/v3/history/movie?movieId={match['id']}", config["api_key"]
    )
    reason = _extract_upgrade_reason(history)
    return match["title"], reason


def _get_sonarr_context(config, file_path):
    """Match a file to a Sonarr series and get history."""
    series_list = api_request(f"{config['api_url']}/api/v3/series", config["api_key"])
    if series_list is None:
        return None, "API unreachable"

    folder_name = file_path.parent.name if file_path.parent != Path(config["download_dir"]) else file_path.stem
    match = _fuzzy_match_title(folder_name, series_list, "title")
    if not match:
        return None, "No matching series found"

    history = api_request(
        f"{config['api_url']}/api/v3/history?seriesId={match['id']}", config["api_key"]
    )
    if history and isinstance(history, dict):
        history = history.get("records", [])
    reason = _extract_upgrade_reason(history)
    return match["title"], reason


def _fuzzy_match_title(folder_name, items, title_key):
    """Fuzzy match: normalize and find the best word-boundary substring match."""
    normalized = _normalize(folder_name)
    words = normalized.split()
    best_match = None
    best_score = 0
    for item in items:
        title = _normalize(item.get(title_key, ""))
        if not title or len(title) < 3:
            continue
        title_words = title.split()
        # Check if all words in the title appear in the folder name
        if all(w in words for w in title_words):
            score = len(title_words)
            if score > best_score:
                best_score = score
                best_match = item
    return best_match


def _normalize(s):
    """Normalize a string for fuzzy matching."""
    s = s.lower()
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    for term in ["2160p", "1080p", "720p", "uhd", "bluray", "blu ray", "webrip",
                 "webdl", "web dl", "remux", "x264", "x265", "h264", "h265",
                 "dts", "hd ma", "truehd", "atmos", "hevc", "aac", "dd5", "dd7",
                 "hdr", "hdr10", "dovi", "dv", "imax", "proper", "remastered"]:
        s = s.replace(term, "")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _extract_upgrade_reason(history):
    """Extract the most recent upgrade reason from history records."""
    if not history:
        return "No history available"
    for record in history:
        if record.get("eventType") == "downloadFolderImported":
            quality = record.get("quality", {}).get("quality", {}).get("name", "unknown")
            date = record.get("date", "unknown")[:10]
            source = record.get("sourceTitle", "unknown")[:60]
            return f"Replaced with {quality} ({source}) on {date}"
    return "No import event found in history"


def check_directory_all_orphaned(directory, config):
    """For season packs: check if ALL media files in a directory are orphaned."""
    download_path = Path(config["download_dir"])
    if directory == download_path:
        return True

    for media_file in directory.rglob("*"):
        if not media_file.is_file():
            continue
        if media_file.suffix.lstrip(".").lower() not in config["media_extensions"]:
            continue
        if not _is_main_media_file(media_file, config["min_file_size_mb"] * 1024 * 1024):
            continue
        result = check_orphan(media_file, config["min_age_hours"])
        if result is None:
            return False
        is_orphan, _, _ = result
        if not is_orphan:
            return False
    return True


def _get_release_dir(file_path, download_path):
    """Walk up from file_path to find the immediate child of download_path."""
    current = file_path.parent
    while current.parent != download_path:
        if current.parent == current:
            return None
        current = current.parent
    return current


def delete_orphan(file_path, config):
    """Delete an orphan file or its parent release directory."""
    download_path = Path(config["download_dir"])

    if file_path.parent != download_path:
        release_dir = _get_release_dir(file_path, download_path)
        if release_dir is None:
            clef_log("error", "Could not determine release directory", path=str(file_path))
            return False, 0

        if not check_directory_all_orphaned(release_dir, config):
            clef_log(
                "information",
                "Skipped directory with partial orphans",
                path=str(release_dir),
            )
            return False, 0

        target = release_dir
        try:
            size = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
        except OSError:
            size = 0

        if config["dry_run"]:
            return True, size

        try:
            shutil.rmtree(str(target))
            return True, size
        except OSError as e:
            clef_log("error", "Failed to delete directory", path=str(target), error=str(e))
            return False, 0
    else:
        try:
            size = file_path.stat().st_size
        except OSError:
            size = 0

        if config["dry_run"]:
            return True, size

        try:
            file_path.unlink()
            return True, size
        except OSError as e:
            clef_log("error", "Failed to delete file", path=str(file_path), error=str(e))
            return False, 0


def main():
    config = get_config()

    clef_log(
        "information",
        "Starting download cleanup scan",
        download_dir=config["download_dir"],
        api_type=config["api_type"],
        min_age_hours=config["min_age_hours"],
        max_deletions=config["max_deletions"],
        dry_run=config["dry_run"],
    )

    min_size_bytes = config["min_file_size_mb"] * 1024 * 1024
    candidates = []
    skipped = 0
    already_seen_dirs = set()

    for media_file in find_media_files(config["download_dir"], config["media_extensions"], min_size_bytes):
        result = check_orphan(media_file, config["min_age_hours"])
        if result is None:
            skipped += 1
            continue

        is_orphan, link_count, age_hours = result
        if not is_orphan:
            skipped += 1
            continue

        download_path = Path(config["download_dir"])
        if media_file.parent != download_path:
            release_dir = _get_release_dir(media_file, download_path)
            dir_key = str(release_dir) if release_dir else str(media_file)
        else:
            dir_key = str(media_file)
        if dir_key in already_seen_dirs:
            continue
        already_seen_dirs.add(dir_key)

        try:
            size = media_file.stat().st_size
        except OSError:
            size = 0

        candidates.append({
            "file": media_file,
            "size": size,
            "link_count": link_count,
            "age_hours": age_hours,
        })

    candidates.sort(key=lambda c: c["size"], reverse=True)
    candidates = candidates[: config["max_deletions"]]

    deleted = 0
    total_freed = 0

    for candidate in candidates:
        media_file = candidate["file"]

        api_match, reason = get_api_context(config, media_file)

        success, freed_bytes = delete_orphan(media_file, config)
        if not success:
            continue

        deleted += 1
        total_freed += freed_bytes
        freed_gb = freed_bytes / (1024 ** 3)

        download_path = Path(config["download_dir"])
        release_dir = _get_release_dir(media_file, download_path) if media_file.parent != download_path else None
        delete_path = str(release_dir) if release_dir else str(media_file)
        action = "Would delete orphan" if config["dry_run"] else "Deleted orphan"

        if api_match:
            clef_log(
                "information",
                action,
                path=delete_path,
                size_gb=round(freed_gb, 1),
                age_hours=round(candidate["age_hours"]),
                link_count=candidate["link_count"],
                api_match=api_match,
                reason=reason,
            )
        else:
            clef_log(
                "warning",
                action + " without API match",
                path=delete_path,
                size_gb=round(freed_gb, 1),
                age_hours=round(candidate["age_hours"]),
                link_count=candidate["link_count"],
                api_error=reason,
            )

    clef_log(
        "information",
        "Cleanup complete",
        deleted=deleted,
        skipped=skipped,
        total_freed_gb=round(total_freed / (1024 ** 3), 1),
        dry_run=config["dry_run"],
    )


if __name__ == "__main__":
    main()
