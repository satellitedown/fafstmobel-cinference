#!/usr/bin/env python3
"""Download and verify the pinned fafstmobel NInfer v3 model and metadata."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import time

ROOT = Path(__file__).resolve().parents[1]
# Free space required beyond the artifact itself: the metadata files and filesystem overhead.
SPACE_MARGIN = 64 << 20


def require_file(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular, non-symlink file: {path}")


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_file(path, expected):
    require_file(path)
    actual = file_digest(path)
    if actual != expected:
        raise ValueError(
            f"SHA-256 mismatch: {path}\nExpected {expected}; got {actual}.\n"
            "Move the damaged, outdated, or unrelated file aside and retry (bash setup.sh --update "
            "moves such files aside for you); it was not overwritten."
        )


def file_matches(path, expected):
    return not path.is_symlink() and path.is_file() and file_digest(path) == expected


def previous_directory(destination):
    """Create a new sibling folder for files that no longer match the pin."""
    stem = f"{destination.name}.previous-{time.strftime('%Y%m%d-%H%M%S')}"
    for attempt in range(1, 100):
        candidate = destination.with_name(stem if attempt == 1 else f"{stem}-{attempt}")
        try:
            candidate.mkdir()
        except FileExistsError:
            continue
        return candidate
    raise ValueError(f"Could not create a folder for the previous files next to {destination}.")


def set_aside(path, target):
    ensure_directory(target.parent)
    try:
        path.rename(target)
    except OSError as error:
        raise ValueError(
            f"Could not move {path} to {target}: {error}.\n"
            "Move it out of the model folder yourself and retry."
        ) from error


def require_space(destination, needed, previous):
    free = shutil.disk_usage(destination).free
    if free < needed + SPACE_MARGIN:
        raise ValueError(
            f"The pinned model needs {needed / 1e9:.1f} GB of free space; {free / 1e9:.1f} GB is "
            f"free.\nThe files it replaces were moved to {previous}. Delete that folder if you no "
            "longer need it, then run the update again."
        )


def ensure_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError(f"Refusing a symlink or non-directory at {path}")
    path.mkdir(parents=True, exist_ok=True)


def verify_artifact(path, expected_size):
    require_file(path)
    if path.stat().st_size != expected_size:
        raise ValueError(f"Unexpected artifact size: {path}; expected {expected_size} bytes.")
    with path.open("rb") as stream:
        header = stream.read(32)
    if len(header) != 32 or header[:8] != b"NINFER\0\x03":
        raise ValueError(f"Expected a NInfer v3 artifact: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "models")
    parser.add_argument(
        "--set-aside-mismatched",
        action="store_true",
        help="move existing files that do not match the pinned checksums to "
        "<model folder>.previous-<time>/ and download the pinned files instead of stopping; "
        "nothing is deleted (bash setup.sh --update uses this)",
    )
    args = parser.parse_args()
    manifest_path = ROOT / "runtime-manifest.json"
    require_file(manifest_path)
    model = json.loads(manifest_path.read_text(encoding="utf-8"))["models"]["target"]
    if model["format_version"] != 3 or model["filename"] not in model["files"]:
        raise ValueError("The manifest must pin a published v3 artifact and its checksum.")
    for name in (model["directory"], *model["files"]):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not relative.name:
            raise ValueError(f"Expected a relative manifest path: {name}")
    ensure_directory(args.models_dir)
    destination = args.models_dir
    for part in Path(model["directory"]).parts:
        destination /= part
        ensure_directory(destination)
    fd = os.open(destination / ".cinference-download.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("The download lock must be a regular file.")
        print("Waiting for exclusive download access...", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print(f"fafstmobel: {model['repo_id']} @ {model['revision']}", flush=True)
        print("Verifying model file checksums...", flush=True)
        missing = []
        set_aside_names = []
        previous = None
        for name, digest in model["files"].items():
            parent = destination
            for part in Path(name).parent.parts:
                parent /= part
                ensure_directory(parent)
            path = destination / name
            if path.exists() or path.is_symlink():
                if not args.set_aside_mismatched:
                    verify_file(path, digest)
                elif not file_matches(path, digest):
                    previous = previous or previous_directory(destination)
                    set_aside(path, previous / name)
                    print(f"Moved aside (does not match this pin): {name}", flush=True)
                    set_aside_names.append(name)
                    missing.append(name)
                    continue
                print(f"Verified: {name}", flush=True)
            else:
                missing.append(name)
        # The replaced artifact stays on disk, so its successor needs room beside it.
        if model["filename"] in set_aside_names:
            require_space(destination, model["size_bytes"], previous)
        if missing:
            from huggingface_hub import snapshot_download

            # The local cache retains partial downloads. Existing files are
            # verified above and excluded so unrelated data is not overwritten.
            for directory in (destination / ".cache", destination / ".cache/huggingface"):
                ensure_directory(directory)
            snapshot_download(
                repo_id=model["repo_id"],
                revision=model["revision"],
                local_dir=destination,
                allow_patterns=missing,
            )
            for name in missing:
                verify_file(destination / name, model["files"][name])
                print(f"Verified: {name}", flush=True)
        verify_artifact(destination / model["filename"], model["size_bytes"])
    print(f"Ready: {destination / model['filename']}", flush=True)
    for kept in sorted(destination.parent.glob(f"{destination.name}.previous-*")):
        print(f"Earlier model files are kept in {kept}; delete it once the new model works.",
              flush=True)
    print("Download complete.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f"Download failed: {error}") from error
