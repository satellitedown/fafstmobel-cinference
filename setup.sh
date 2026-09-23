#!/usr/bin/env bash
# Install, download, or start the foreground server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$ROOT/.tools/bin:$PATH"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: bash setup.sh\n\nChoose 1 to install Cinference and download fafstmobel NVFP4/FP8.\nChoose 2 to download or resume the model download.\nChoose 3 to start the server with the manifest profile (bundled DFlash2).\nServing requires Linux x86_64 and an RTX 5090 with working NVIDIA drivers.\nAllow about 23.8 GB for model files, plus software and download working space.\n'
  exit 0
fi
if [[ $# -ne 0 || ! -t 0 ]]; then
  echo "Run bash setup.sh in an interactive terminal (or use --help)." >&2
  exit 2
fi
active_step=""
interrupt_setup() {
  trap '' INT
  if [[ -n "$active_step" ]]; then
    kill -TERM -- "-$active_step" 2>/dev/null || true
    wait "$active_step" 2>/dev/null || true
  fi
  printf '\nInterrupted. Choose 1 to continue installation or 2 to resume the download.\n'
  exit 130
}
trap interrupt_setup INT

run_step() {
  # Keep Bash's interrupt trap responsive and stop all download/build workers.
  setsid "$@" &
  active_step=$!
  local status=0
  wait "$active_step" || status=$?
  active_step=""
  return "$status"
}

check_hardware() {
  if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo "This recipe requires Linux x86_64; Apple, AMD and CPU inference are not supported." >&2
    return 1
  fi
  if ! command -v nvidia-smi >/dev/null; then
    echo "Install your NVIDIA driver first. This menu does not install or change drivers." >&2
    return 1
  fi
  local gpus
  if ! gpus="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"; then
    echo "The NVIDIA driver is not working. Fix it before continuing." >&2
    return 1
  fi
  printf '\nDetected GPU(s):\n%s\n' "$gpus"
  if [[ "$gpus" != *"RTX 5090"* ]]; then
    echo "Warning: this preset targets RTX 5090 32 GB (Blackwell sm_120a); other GPUs are untested."
  fi
}

check_system_tools() {
  local command missing=0
  for command in curl git cc c++ pkg-config setsid; do
    if ! command -v "$command" >/dev/null; then
      printf 'Missing system tool: %s\n' "$command" >&2
      missing=1
    fi
  done
  if command -v pkg-config >/dev/null; then
    if ! pkg-config --exists libavformat libavcodec libavutil libswscale; then
      echo "Missing FFmpeg development libraries." >&2
      missing=1
    fi
    if ! pkg-config --atleast-version=7.85 libcurl; then
      echo "Missing libcurl development files version 7.85 or newer." >&2
      missing=1
    fi
  fi
  return "$missing"
}

ensure_system_tools() {
  if check_system_tools; then
    return 0
  fi
  local answer
  local package_command=() privilege=()
  if command -v apt-get >/dev/null; then
    package_command=(apt-get install -y build-essential git curl pkg-config util-linux libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libcurl4-openssl-dev)
  elif command -v dnf >/dev/null; then
    package_command=(dnf install -y gcc gcc-c++ make git curl pkgconf-pkg-config util-linux ffmpeg-free-devel libcurl-devel)
  elif command -v pacman >/dev/null; then
    package_command=(pacman -S --needed base-devel git curl pkgconf util-linux ffmpeg)
  else
    echo "Install the missing build tools and development libraries, then choose 1 again." >&2
    return 1
  fi
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null; then
      echo "Ask your administrator to install the missing tools, then choose 1 again." >&2
      return 1
    fi
    privilege=(sudo)
  fi
  printf '\nSystem package command: %s\n' "${privilege[*]} ${package_command[*]}"
  echo "On apt-based systems, package lists will also be refreshed first."
  if ! read -r -p "Install these system build tools? [y/N] " answer; then
    return 1
  fi
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "No system packages changed."; return 1 ;;
  esac
  if [[ "${package_command[0]}" == apt-get ]]; then
    "${privilege[@]}" apt-get update || return 1
  fi
  "${privilege[@]}" "${package_command[@]}" || return 1
  check_system_tools
}

ensure_uv() {
  if command -v uv >/dev/null; then
    return 0
  fi
  local installer status
  echo "Installing uv from https://astral.sh/uv/install.sh into .tools/bin (no shell profile changes)."
  installer="$(mktemp)" || return 1
  if ! curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    https://astral.sh/uv/install.sh --output "$installer"; then
    rm -f -- "$installer"
    return 1
  fi
  status=0
  UV_UNMANAGED_INSTALL="$ROOT/.tools/bin" sh "$installer" || status=$?
  rm -f -- "$installer"
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
  command -v uv >/dev/null
}

download_models() {
  local command
  for command in curl setsid; do
    if ! command -v "$command" >/dev/null; then
      printf 'Missing %s. Install it, or choose 1 for system prerequisite setup.\n' "$command" >&2
      return 1
    fi
  done
  ensure_uv || return 1
  run_step bash "$ROOT/scripts/install.sh" --download-only || return 1
  run_step "$ROOT/.venv/bin/python" "$ROOT/scripts/download_models.py"
}

install_everything() {
  check_hardware || return 1
  ensure_system_tools || return 1
  ensure_uv || return 1
  printf '\n[1/2] Installing local tools and building the pinned Cinference runtime...\n'
  run_step bash "$ROOT/scripts/install.sh" || return 1
  printf '\n[2/2] Downloading and verifying fafstmobel and its licenses...\n'
  run_step "$ROOT/.venv/bin/python" "$ROOT/scripts/download_models.py" || return 1
  printf '\nInstallation complete. Choose 3 to start the server.\n'
}

while true; do
  printf '\nfafstmobel - Cinference\n'
  printf 'Swift + Huihui Qwen3.8-27B / RTX 5090, K8V4 KV, bundled DFlash2\n\n'
  printf '  1) Install everything (build + download)\n'
  printf '  2) Download / resume model\n'
  printf '  3) Start the server (Ctrl-C to stop)\n'
  printf '  0) Exit\n\n'
  printf 'Space: ~23.8 GB model files, plus software and download working space.\n'
  if ! read -r -p "Choose an option: " choice; then
    printf '\n'
    exit 0
  fi
  case "$choice" in
    1)
      if ! install_everything; then
        printf '\nSetup did not finish. Fix the error above, then choose 1 again.\n' >&2
      fi
      ;;
    2)
      if ! download_models; then
        printf '\nDownload did not finish. Fix the error above, then retry.\n' >&2
      fi
      ;;
    3)
      if [[ ! -x "$ROOT/runtime/ninfer/build/apps/ninfer-serve" ]]; then
        echo "Choose 1 to build the runtime and download the model first." >&2
      elif check_hardware; then
        exec bash "$ROOT/scripts/serve.sh"
      fi
      ;;
    0|q|Q) exit 0 ;;
    *) echo "Choose 1, 2, 3, or 0." ;;
  esac
done
