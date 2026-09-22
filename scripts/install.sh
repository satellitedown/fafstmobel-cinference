#!/usr/bin/env bash
# Install pinned Python tools and runtime source, optionally building the server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'HELP'
Usage: bash scripts/install.sh [--download-only]
Install the locked Python 3.12 tools and pinned Cinference source.
Normally, also install the isolated CUDA SDK and build
runtime/ninfer/build/apps/ninfer-serve. --download-only installs just the
Python tools for menu option 2, without runtime source, CUDA, or compilation.
Run bash setup.sh to install missing system build prerequisites with permission.
A CUDA-compatible NVIDIA driver is required to build and serve, not to download.
HELP
  exit 0
fi
DOWNLOAD_ONLY=0
if [[ $# == 1 && "$1" == --download-only ]]; then
  DOWNLOAD_ONLY=1
elif [[ $# != 0 ]]; then
  fail 'Unexpected arguments; use --help for usage.'
fi
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'This recipe requires Linux x86_64.'


if [[ -x "$ROOT/.tools/bin/uv" ]]; then
  UV="$ROOT/.tools/bin/uv"
elif command -v uv >/dev/null; then
  UV="$(command -v uv)"
else
  fail 'uv is missing. Run bash setup.sh to bootstrap the local tool.'
fi
[[ ! -L "$ROOT/.venv" ]] || fail "Refusing to modify a symlinked installation directory: $ROOT/.venv. Use a repository-local installation."
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  [[ ! -e "$ROOT/.venv" ]] || fail 'An incomplete .venv already exists. Move it aside before installing; no files were removed.'
  "$UV" venv --python 3.12 "$ROOT/.venv"
fi
PYTHON="$ROOT/.venv/bin/python"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else "This recipe requires Python 3.12; move the existing .venv aside and rerun setup.")'
"$UV" pip install --python "$PYTHON" --no-deps -r "$ROOT/requirements.lock"
if [[ "$DOWNLOAD_ONLY" == 1 ]]; then
  printf '\nDownload tools are ready.\n'
  exit 0
fi

command -v git >/dev/null || fail 'Missing git. Install it or run bash setup.sh and choose 1.'
for directory in "$ROOT/runtime" "$ROOT/runtime/ninfer"; do
  [[ ! -L "$directory" ]] || fail "Refusing to modify a symlinked installation directory: $directory. Use a repository-local installation."
done

runtime_config="$("$PYTHON" - "$ROOT/runtime-manifest.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    runtime = json.load(stream)["runtime"]
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", runtime["repo_id"]):
    sys.exit("Invalid runtime repo_id in runtime-manifest.json")
if not re.fullmatch(r"[0-9a-f]{40}", runtime["revision"]):
    sys.exit("The runtime revision must be a full Git commit in runtime-manifest.json")
if (runtime["cuda_architectures"], runtime["cuda_version"], runtime["build_type"], runtime["build_jobs"]) != ("120a", "13.4.92", "Release", 2):
    sys.exit("This recipe requires CUDA 13.4.92, sm_120a, Release, and two build jobs.")
for key in ("repo_id", "revision", "cuda_architectures", "cuda_version", "build_type", "build_jobs"):
    print(runtime[key])
PY
)"
mapfile -t runtime_values <<< "$runtime_config"
REPO_URL="https://github.com/${runtime_values[0]}.git"
REVISION="${runtime_values[1]}"
SOURCE="$ROOT/runtime/ninfer"
BUILD="$SOURCE/build"

# Never reset or clean an existing checkout. A failed fetch can be resumed, while
# local source changes are left untouched rather than silently incorporated.
if [[ ! -e "$SOURCE" ]]; then
  mkdir -p "$ROOT/runtime"
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin "$REPO_URL"
fi
[[ -d "$SOURCE/.git" ]] || fail "Expected an independent Git checkout at $SOURCE. Move the existing directory aside; it was not changed."
[[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)" ]] || fail "Local changes exist in $SOURCE. Save them before rerunning; no reset or cleanup was performed."
if ! git -C "$SOURCE" cat-file -e "$REVISION^{commit}" 2>/dev/null; then
  git -C "$SOURCE" fetch --depth 1 "$REPO_URL" "$REVISION"
fi
if [[ "$(git -C "$SOURCE" rev-parse --verify HEAD 2>/dev/null || true)" != "$REVISION" ]]; then
  git -C "$SOURCE" checkout --detach "$REVISION"
fi


[[ ! -L "$ROOT/.cuda-toolkit" ]] || fail 'Refusing to modify a symlinked .cuda-toolkit directory.'
command -v pkg-config >/dev/null || fail 'Missing pkg-config. Run bash setup.sh and choose 1.'
CC="${CC:-cc}"
CXX="${CXX:-c++}"
CC="$(command -v "$CC")" || fail 'A C compiler is required (CC must name one executable).'
CXX="$(command -v "$CXX")" || fail 'A CUDA-compatible C++20 compiler is required (CXX must name one executable).'
for library in libavformat libavcodec libavutil libswscale; do
  pkg-config --exists "$library" || fail "Missing $library development files. Run bash setup.sh and choose install/build."
done
pkg-config --exists 'libcurl >= 7.85' || fail 'libcurl development files >= 7.85 are required. Run bash setup.sh; older distributions may need a newer libcurl.'

# Link to the installed driver, never to a toolkit stub. A versioned driver library
# also works on distributions that do not ship an unversioned development symlink.
DRIVER_LIBRARY="$("$CXX" -print-file-name=libcuda.so.1)"
if [[ ! -f "$DRIVER_LIBRARY" ]]; then
  DRIVER_LIBRARY="$("$CXX" -print-file-name=libcuda.so)"
fi
[[ -f "$DRIVER_LIBRARY" ]] || fail 'Cannot find the NVIDIA driver library (libcuda.so.1). Make the installed driver user-space libraries available to your compiler; this recipe does not install drivers.'
"$UV" pip install --python "$PYTHON" --target "$ROOT/.cuda-toolkit" \
  --no-deps -r "$ROOT/requirements-cuda.lock"
export CUDA_HOME="$ROOT/.cuda-toolkit/nvidia/cu13"
export PATH="$ROOT/.venv/bin:$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# NVIDIA's wheels omit the linker/layout aliases required by CMake. Keep existing
# correct aliases, and refuse to overwrite unrelated files or symlinks.
ensure_link() {
  local target="$1" link="$2"
  if [[ -e "$link" || -L "$link" ]]; then
    [[ "$link" -ef "$(dirname -- "$link")/$target" ]] || fail "Unexpected CUDA layout at $link. Move it aside and rerun; it was not overwritten."
  else
    ln -s "$target" "$link"
  fi
}
ensure_link lib "$CUDA_HOME/lib64"
ensure_link libcudart.so.13 "$CUDA_HOME/lib/libcudart.so"
for file in bin/nvcc include/cuda.h include/crt/host_config.h include/cccl/cuda/std/version include/nvtx3/nvToolsExt.h nvvm/libdevice/libdevice.10.bc lib/libcudart.so.13; do
  [[ -f "$CUDA_HOME/$file" ]] || fail "Incomplete CUDA SDK: $file is missing. Rerun the locked CUDA package installation."
done
nvcc_version="$("$CUDA_HOME/bin/nvcc" --version)"
[[ "$nvcc_version" == *"V${runtime_values[3]}"* ]] || fail "The isolated nvcc does not match CUDA ${runtime_values[3]}."

# The relative RPATH and the launcher's library path both select this repository's
# SDK. Neither the build nor the executable depends on another Python environment.
if ! "$ROOT/.venv/bin/cmake" -S "$SOURCE" -B "$BUILD" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$ROOT/.venv/bin/ninja" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
  -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
  -DCUDAToolkit_ROOT="$CUDA_HOME" \
  -DCUDA_cuda_driver_LIBRARY="$DRIVER_LIBRARY" \
  -DCMAKE_CUDA_ARCHITECTURES="${runtime_values[2]}" \
  -DCMAKE_BUILD_TYPE="${runtime_values[4]}" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  '-DCMAKE_INSTALL_RPATH=$ORIGIN/../../../../.cuda-toolkit/nvidia/cu13/lib' \
  -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF -DNINFER_BUILD_BENCHMARKS=OFF; then
  fail 'CMake configuration failed. Check the error above, the C++20 compiler/CUDA compatibility, and FFmpeg/libcurl development packages. If this build directory belongs to another toolchain or location, move runtime/ninfer/build aside and rerun; it was not deleted.'
fi
"$ROOT/.venv/bin/cmake" --build "$BUILD" --target ninfer-serve --parallel "${runtime_values[5]}"
printf '\nBuilt the native server.\nNext: .venv/bin/python scripts/download_models.py\nThen: bash scripts/serve.sh\n'
