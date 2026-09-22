#!/usr/bin/env python3
"""Download pinned Huihui NVFP4 files and prepare a CPU-only NInfer v3 artifact."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = "upgrade-receipt.json"
OWNER = "preparation.json"


def require_file(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular, non-symlink file: {path}")


def sha256(path):
    require_file(path)
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_file(path, expected):
    actual = sha256(path)
    if actual != expected:
        raise ValueError(
            f"SHA-256 mismatch: {path}\nExpected {expected}; got {actual}.\n"
            "Move the damaged or unrelated file aside and retry; it was not overwritten."
        )


def ensure_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError(f"Refusing a symlink or non-directory at {path}")
    path.mkdir(parents=True, exist_ok=True)


def artifact_identity(path, version):
    require_file(path)
    header_size = 16 if version == 2 else 32
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(header_size)
        if len(header) != header_size or header[:8] != b"NINFER\0" + bytes([version]):
            raise ValueError(f"Expected NInfer v{version}: {path}")
        count = struct.unpack_from("<Q", header, 8)[0]
        if not 0 < count <= min(64 * 1024 * 1024, size - header_size):
            raise ValueError(f"Invalid NInfer directory length: {path}")
        directory = json.loads(stream.read(count))
    if version == 2:
        return directory["identity"]
    if directory["files"] != [{"path": None, "payload_bytes": size - header_size - count}]:
        raise ValueError(f"Expected a complete, single-file v3 artifact: {path}")
    return {
        "uuid": str(uuid.UUID(bytes=header[16:32])),
        "upgraded_from": directory["provenance"]["upgraded_from"],
    }


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def read_json(path):
    require_file(path)
    return json.loads(path.read_text(encoding="utf-8"))


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def output_identity(path):
    return {
        "filename": path.name,
        "size_bytes": path.stat().st_size,
        "format_version": 3,
        "identity": artifact_identity(path, 3),
        "sha256": sha256(path),
    }


def verify_prepared(directory, expected, basename):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Refusing an unrelated preparation path: {directory}")
    receipt = read_json(directory / RECEIPT)
    if {key: receipt.get(key) for key in expected} != expected:
        raise ValueError(f"Preparation receipt does not match the pinned input/tools: {directory}")
    print(f"Verifying prepared v3 artifact: {directory / basename}", flush=True)
    if receipt.get("output") != output_identity(directory / basename):
        raise ValueError(f"Prepared artifact differs from its receipt: {directory}")
    for name, digest in expected["publisher_licenses"].items():
        verify_file(directory / name, digest)


def remove_incomplete(stage, basename):
    # Only delete this recipe's known files in a directory with a matching owner
    # record. Refuse extra files, subdirectories and symlinks, even in our staging.
    allowed = {OWNER, RECEIPT, RECEIPT + ".tmp", basename, "LICENSE", "NOTICE"}
    entries = list(stage.iterdir())
    for entry in entries:
        require_file(entry)
        if entry.name not in allowed and not (
            entry.name.startswith(f".{basename}.") and entry.name.endswith(".tmp")
        ):
            raise ValueError(f"Unrecognized staging file left untouched: {entry}")
    # Keep ownership until the end so another attempt can recover from interruption.
    for entry in entries:
        if entry.name != OWNER:
            entry.unlink()
    (stage / OWNER).unlink()
    stage.rmdir()


def publish(stage, final):
    if final.exists() or final.is_symlink():
        raise ValueError(f"Refusing to replace an existing path: {final}")
    sync_directory(stage)
    stage.rename(final)
    sync_directory(final.parent)


def prepare_model(destination, model, runtime, lock_fd):
    source = destination / model["source_filename"]
    relative = Path(model["filename"])
    if relative.parent != Path("v3") or relative.name != model["source_filename"]:
        raise ValueError("The prepared artifact must use v3/ and the original basename.")
    if (model["source_format_version"], model["format_version"]) != (2, 3):
        raise ValueError("This recipe prepares NInfer v2 inputs as v3.")
    if source.stat().st_size != model["size_bytes"]:
        raise ValueError(f"Unexpected source size: {source}")
    upgrader = ROOT / "runtime/ninfer/tools/upgrade_ninfer_v2_to_v3.py"
    template = upgrader.parent / "chat_templates/qwen3_8.jinja"
    if not upgrader.is_file() or not template.is_file():
        raise ValueError("The pinned upgrader/templates are missing. Run bash setup.sh and choose 2.")
    expected = {
        "schema": "cinference.model-upgrade",
        "schema_version": 1,
        "input": {
            "repo_id": model["repo_id"],
            "revision": model["revision"],
            "filename": model["source_filename"],
            "size_bytes": model["size_bytes"],
            "format_version": 2,
            "identity": artifact_identity(source, 2),
            "sha256": model["files"][model["source_filename"]],
        },
        "upgrader": {
            "repo_id": runtime["repo_id"],
            "revision": runtime["revision"],
            "script": "tools/upgrade_ninfer_v2_to_v3.py",
            "sha256": sha256(upgrader),
            "chat_template_sha256": sha256(template),
        },
        "publisher_licenses": {name: model["files"][name] for name in ("LICENSE", "NOTICE")},
        "statement_of_changes": (
            "NInfer v2 container upgraded to v3 by Cinference's standard-library tool. "
            "Weight bytes preserved; the maintained Qwen3.8 chat template is installed. "
            "The publisher's original artifact and attribution files are retained unchanged."
        ),
    }
    final = destination / "v3"
    basename = relative.name
    if final.exists() or final.is_symlink():
        verify_prepared(final, expected, basename)
        print("Reusing the verified v3 conversion.", flush=True)
        return

    for stage in sorted(destination.glob(".v3-prepare-*")):
        # An unmarked directory is not ours to modify. A crash before writing the
        # owner record can leave an empty one; a fresh unique stage is safe.
        if stage.is_symlink() or not stage.is_dir() or not (stage / OWNER).exists():
            continue
        if read_json(stage / OWNER) != expected:
            raise ValueError(f"Staging belongs to different inputs/tools; move it aside: {stage}")
        if (stage / RECEIPT).exists():
            verify_prepared(stage, expected, basename)
            publish(stage, final)
            print("Published the previously completed v3 conversion.", flush=True)
            return
        print(f"Removing only recognized incomplete conversion files: {stage}", flush=True)
        remove_incomplete(stage, basename)

    if shutil.disk_usage(destination).free < model["size_bytes"] + 16 * 1024 * 1024:
        raise ValueError("Preparation needs about 21.5 GB of free space in addition to the retained source.")
    stage = Path(tempfile.mkdtemp(prefix=".v3-prepare-", dir=destination))
    write_json(stage / (OWNER + ".tmp"), expected)
    (stage / (OWNER + ".tmp")).rename(stage / OWNER)
    sync_directory(stage)
    print("Preparing v3 on the CPU; weights are never loaded onto the GPU...", flush=True)
    # Keep the lock alive in the child even if the parent is killed. A later
    # attempt cannot remove staging while the upgrader is still writing to it.
    subprocess.run(
        [sys.executable, str(upgrader), str(source), str(stage / basename)],
        check=True,
        pass_fds=(lock_fd,),
    )
    output = output_identity(stage / basename)
    identity = expected["input"]["identity"]
    if output["identity"]["upgraded_from"] != {
        "version": 2, "model_id": identity["model_id"], "weights_id": identity["weights_id"]
    }:
        raise ValueError("The upgraded artifact has unexpected input provenance.")
    for name, digest in expected["publisher_licenses"].items():
        with (stage / name).open("xb") as stream:
            stream.write((destination / name).read_bytes())
            stream.flush()
            os.fsync(stream.fileno())
        verify_file(stage / name, digest)
    write_json(stage / (RECEIPT + ".tmp"), {**expected, "output": output})
    (stage / (RECEIPT + ".tmp")).rename(stage / RECEIPT)
    publish(stage, final)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "models")
    args = parser.parse_args()
    manifest = read_json(ROOT / "runtime-manifest.json")
    model = manifest["models"]["target"]
    ensure_directory(args.models_dir)
    destination = args.models_dir / model["directory"]
    ensure_directory(destination)
    fd = os.open(destination / ".cinference-prepare.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("The preparation lock must be a regular file.")
        print("Waiting for exclusive download/preparation access...", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print(f"Huihui NVFP4: {model['repo_id']} @ {model['revision']}", flush=True)
        print("Verifying artifact, publisher licenses, and provenance checksums...", flush=True)
        missing = []
        for name, digest in model["files"].items():
            path = destination / name
            if path.exists() or path.is_symlink():
                verify_file(path, digest)
                print(f"Verified: {name}", flush=True)
            else:
                missing.append(name)
        if missing:
            from huggingface_hub import snapshot_download

            # Never redownload over an existing unrelated file. The hub's local
            # cache retains partial downloads for files that are still missing.
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
        prepare_model(destination, model, manifest["runtime"], lock.fileno())
    print(f"Ready: {destination / model['filename']}", flush=True)
    print("Download and preparation complete. No model has been started.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Preparation failed: {error}\nNo existing v3 directory was overwritten.") from error
