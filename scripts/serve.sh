#!/usr/bin/env bash
# One GPU, one request, foreground server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Handle help before checking Python, CUDA, the native binary, or model files.
for argument in "$@"; do
  if [[ "$argument" == --help || "$argument" == -h ]]; then
    cat <<'HELP'
Usage: bash scripts/serve.sh [additional native server arguments]
  MODEL_PATH     v3 .ninfer artifact (default: manifest's models/ location)
  HOST / PORT    Bind address (default: 127.0.0.1 / 8000)
Uses the pinned Huihui NVFP4 / Cinference MTP-10 profile from runtime-manifest.json.
Extra native server arguments follow the profile. Runs in the foreground.
Stop with Ctrl-C. The API has no authentication; keep it on loopback.
HELP
    exit 0
  fi
done

PYTHON="$ROOT/.venv/bin/python"
SERVER="$ROOT/runtime/ninfer/build/apps/ninfer-serve"
if [[ ! -x "$PYTHON" || ! -x "$SERVER" ]]; then
  printf 'The native server is not installed. Run bash setup.sh and choose 1.\n' >&2
  exit 1
fi
export CUDA_HOME="$ROOT/.cuda-toolkit/nvidia/cu13"
if [[ ! -f "$CUDA_HOME/lib/libcudart.so.13" ]]; then
  printf 'The isolated CUDA runtime is missing. Run bash scripts/install.sh.\n' >&2
  exit 1
fi
export PATH="$ROOT/.venv/bin:$CUDA_HOME/bin:$PATH"
# Never put CUDA driver stubs on the runtime library path.
export LD_LIBRARY_PATH="$CUDA_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

profile="$("$PYTHON" - "$ROOT/runtime-manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = json.load(stream)
target = manifest["models"]["target"]
serving = manifest["serving"]
print(f'{target["directory"]}/{target["filename"]}')
print(serving["host"])
print(serving["port"])
for key in (
    "model_id", "max_context", "kv_dtype", "max_concurrency", "pending_timeout_ms",
    "prefill_chunk", "spec", "draft_tokens", "default_max_tokens",
):
    print("--" + key.replace("_", "-"))
    print(serving[key])
for key in ("lm_head_draft", "preserve_thinking"):
    if serving[key]:
        print("--" + key.replace("_", "-"))
PY
)"
mapfile -t profile_args <<< "$profile"
MODEL_PATH="${MODEL_PATH:-$ROOT/models/${profile_args[0]}}"
HOST="${HOST:-${profile_args[1]}}"
PORT="${PORT:-${profile_args[2]}}"
if [[ ! -f "$MODEL_PATH" || ! -r "$MODEL_PATH" ]]; then
  printf 'Model is missing or unreadable: %s\nRun bash setup.sh and choose 2 to download, or set MODEL_PATH to a v3 artifact.\n' "$MODEL_PATH" >&2
  exit 1
fi

exec "$SERVER" "$MODEL_PATH" --host "$HOST" --port "$PORT" \
  "${profile_args[@]:3}" "$@"
