#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# RunPod AI Stack - Production-style single-GPU service controller
# ==============================================================================
#
# Public gateway:
#   0.0.0.0:8000
#
# Internal services:
#   Ollama daemon: 127.0.0.1:11434
#   Qwen3-TTS:     127.0.0.1:8880
#   SDXL image API: 127.0.0.1:8189
#   HunyuanVideo-1.5 video API:   127.0.0.1:8190
#
# GPU modes are mutually exclusive:
#   off -> no large GPU workload loaded
#   llm -> Ollama model loaded; TTS stopped
#   tts   -> Ollama/image unloaded; TTS running
#   image -> Ollama/TTS/video stopped; SDXL image model active
#   video -> Ollama/TTS/image stopped; HunyuanVideo-1.5 image-to-video active
#
# Control API:
#   GET  /health
#   GET  /resources
#   GET  /control/status
#   POST /control/llm/start
#   POST /control/llm/stop
#   POST /control/tts/start
#   POST /control/tts/stop
#   POST /control/image/start
#   POST /control/image/stop
#   POST /control/video/start
#   POST /control/video/stop
#   POST /control/off
#   POST /control/restart
#
# Proxies:
#   /ollama/... -> Ollama API, only while LLM mode is active
#   /v1/...     -> Qwen3-TTS OpenAI-compatible routes, only in TTS mode
#   /tts/...    -> Qwen3-TTS native routes, only in TTS mode
#   /v1/images/generations -> SDXL text-to-image, only in image mode
#   /files/generated/...         -> generated PNG files
#   /v1/videos/generations      -> image + prompt to one MP4
#   /files/generated/videos/... -> generated MP4 files
#
# IMPORTANT:
#   Port 8000 is public through RunPod's proxy. Anyone with the proxy URL can
#   call these endpoints and consume GPU resources.
#
# Supported overrides:
#   WORKSPACE=/workspace
#   OLLAMA_MODEL=qwen3:32b
#   OLLAMA_CONTEXT_LENGTH=4096
#   OLLAMA_KEEP_ALIVE=30m
#   AI_START_MODE=off              # off | llm | tts
#   OLLAMA_PREFLIGHT=true          # verify real model inference during setup
#   LLM_ENABLED=false              # disabled for the MCP image/video deployment
#   TTS_MODEL_NAME=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
#   TTS_BACKEND=official
#   TTS_LAZY_LOAD=true
#   TTS_PREFLIGHT=true             # synthesize a short WAV during setup
#   MCP_REPO_URL=https://github.com/OWNER/REPO.git
#   MCP_ENABLED=true
#   MCP_BRANCH=main
#   MCP_PORT=8787
#   MCP_PUBLIC_GATEWAY_URL=https://POD_ID-8000.proxy.runpod.net
#
# ==============================================================================

SCRIPT_VERSION="11.0.2"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WORKSPACE="${WORKSPACE:-/workspace}"
STACK_DIR="$WORKSPACE/ai-stack"
GATEWAY_DIR="$STACK_DIR/gateway"
GATEWAY_VENV="$GATEWAY_DIR/.venv"
IMAGE_DIR="$STACK_DIR/image-service"
IMAGE_VENV="$IMAGE_DIR/.venv"
VIDEO_DIR="$STACK_DIR/video-service"
VIDEO_VENV="${VIDEO_VENV:-/root/.cache/ai-stack/video-venv}"
GENERATED_VIDEO_DIR="$WORKSPACE/generated/videos"
GENERATED_DIR="$WORKSPACE/generated/images"
TTS_DIR="$WORKSPACE/Qwen3-TTS-Openai-Fastapi"
TTS_VENV="$TTS_DIR/.venv"
LOG_DIR="$WORKSPACE/logs"
RUN_DIR="$STACK_DIR/run"
CONFIG_FILE="$STACK_DIR/config.json"
STATE_FILE="$STACK_DIR/state.json"
MODE_SCRIPT="$STACK_DIR/ai-mode"

STARTUP_LOG="$LOG_DIR/startup.log"
OLLAMA_LOG="$LOG_DIR/ollama.log"
GATEWAY_LOG="$LOG_DIR/gateway.log"
TTS_LOG="$LOG_DIR/qwen3tts.log"
IMAGE_LOG="$LOG_DIR/image-service.log"
VIDEO_LOG="$LOG_DIR/video-service.log"
CONTROL_LOG="$LOG_DIR/service-control.log"
MCP_LOG="$LOG_DIR/mcp-server.log"
INSTALL_LOG="$LOG_DIR/install.log"
PREFLIGHT_LOG="$LOG_DIR/preflight.log"

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:32b}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
OLLAMA_PREFLIGHT="${OLLAMA_PREFLIGHT:-true}"
LLM_ENABLED="${LLM_ENABLED:-false}"
AI_START_MODE="${AI_START_MODE:-off}"

TTS_MODEL_NAME="${TTS_MODEL_NAME:-Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice}"
TTS_BACKEND="${TTS_BACKEND:-official}"
TTS_LAZY_LOAD="${TTS_LAZY_LOAD:-true}"
TTS_PREFLIGHT="${TTS_PREFLIGHT:-true}"
TTS_AUTOCHUNK="${TTS_AUTOCHUNK:-false}"
# Default SDXL model is public/ungated: no Hugging Face auth token required.
# Default SDXL model is public and ungated; no Hugging Face authentication token is required.
IMAGE_MODEL="${IMAGE_MODEL:-stabilityai/stable-diffusion-xl-base-1.0}"
IMAGE_PORT="${IMAGE_PORT:-8189}"
IMAGE_PREFLIGHT="false"
IMAGE_DEFAULT_WIDTH="${IMAGE_DEFAULT_WIDTH:-1024}"
IMAGE_DEFAULT_HEIGHT="${IMAGE_DEFAULT_HEIGHT:-1024}"
IMAGE_DEFAULT_STEPS="${IMAGE_DEFAULT_STEPS:-30}"
# Isolated HunyuanVideo-1.5 image-to-video service. No internal dependency on LLM/TTS/SDXL.
VIDEO_MODEL="${VIDEO_MODEL:-hunyuanvideo-community/HunyuanVideo-1.5-Diffusers-480p_i2v_step_distilled}"
VIDEO_PORT="${VIDEO_PORT:-8190}"
VIDEO_PREFLIGHT="${VIDEO_PREFLIGHT:-true}"
VIDEO_DEFAULT_WIDTH="${VIDEO_DEFAULT_WIDTH:-480}"
VIDEO_DEFAULT_HEIGHT="${VIDEO_DEFAULT_HEIGHT:-832}"
VIDEO_DEFAULT_FRAMES="${VIDEO_DEFAULT_FRAMES:-121}"
VIDEO_DEFAULT_FPS="${VIDEO_DEFAULT_FPS:-24}"
VIDEO_DEFAULT_STEPS="${VIDEO_DEFAULT_STEPS:-12}"
VIDEO_DEFAULT_GUIDANCE="${VIDEO_DEFAULT_GUIDANCE:-1.0}"
VIDEO_HF_HOME="${VIDEO_HF_HOME:-/root/.cache/huggingface/hunyuan15-i2v}"
VIDEO_HF_HUB_CACHE="${VIDEO_HF_HUB_CACHE:-$VIDEO_HF_HOME/hub}"
VIDEO_TRANSFORMERS_CACHE="${VIDEO_TRANSFORMERS_CACHE:-$VIDEO_HF_HOME/transformers}"
HF_HOME="${HF_HOME:-/root/.cache/huggingface/shared}"
CONTAINER_CACHE_ROOT="${CONTAINER_CACHE_ROOT:-/root/.cache}"
CLEAN_LEGACY_WORKSPACE_CACHES="${CLEAN_LEGACY_WORKSPACE_CACHES:-true}"
MCP_ENABLED="${MCP_ENABLED:-true}"
MCP_REPO_URL="${MCP_REPO_URL:-}"
MCP_BRANCH="${MCP_BRANCH:-main}"
MCP_PORT="${MCP_PORT:-8787}"
MCP_DIR="${MCP_DIR:-$SCRIPT_DIR}"
MCP_PUBLIC_GATEWAY_URL="${MCP_PUBLIC_GATEWAY_URL:-}"
MCP_PUBLIC_BASE_URL="${MCP_PUBLIC_BASE_URL:-}"
AUDIO_OUTPUT_DIR="${AUDIO_OUTPUT_DIR:-$WORKSPACE/generated/audio}"

# Heavy model/cache data must never live on the 50 GB /workspace volume.
OLLAMA_MODELS_DEFAULT="$WORKSPACE/.ollama/models"
OLLAMA_MODELS="${OLLAMA_MODELS:-$OLLAMA_MODELS_DEFAULT}"


mkdir -p "$(dirname "$VIDEO_VENV")"
mkdir -p "$CONTAINER_CACHE_ROOT" "$HF_HOME" "$VIDEO_HF_HOME" "$VIDEO_HF_HUB_CACHE" "$VIDEO_TRANSFORMERS_CACHE" "$OLLAMA_MODELS_DEFAULT"
mkdir -p "$STACK_DIR" "$GATEWAY_DIR" "$IMAGE_DIR" "$VIDEO_DIR" "$GENERATED_DIR" "$GENERATED_VIDEO_DIR" "$LOG_DIR" "$RUN_DIR"
touch "$STARTUP_LOG" "$OLLAMA_LOG" "$GATEWAY_LOG" "$TTS_LOG" "$IMAGE_LOG" "$VIDEO_LOG" \
      "$CONTROL_LOG" "$MCP_LOG" "$INSTALL_LOG" "$PREFLIGHT_LOG"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %-7s %s\n' "$(timestamp)" "INFO" "$*" | tee -a "$STARTUP_LOG"
}

warn() {
  printf '[%s] %-7s %s\n' "$(timestamp)" "WARN" "$*" | tee -a "$STARTUP_LOG" >&2
}

fatal() {
  printf '[%s] %-7s %s\n' "$(timestamp)" "ERROR" "$*" | tee -a "$STARTUP_LOG" >&2
  exit 1
}

section() {
  printf '\n[%s] ===== %s =====\n' "$(timestamp)" "$*" | tee -a "$STARTUP_LOG"
}

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-unknown}"
  local command="${BASH_COMMAND:-unknown}"
  printf '[%s] ERROR   Setup failed (exit=%s line=%s command=%q)\n' \
    "$(timestamp)" "$exit_code" "$line_no" "$command" | tee -a "$STARTUP_LOG" >&2
  printf '[%s] ERROR   Review: %s, %s, %s\n' \
    "$(timestamp)" "$STARTUP_LOG" "$INSTALL_LOG" "$OLLAMA_LOG" \
    | tee -a "$STARTUP_LOG" >&2
  exit "$exit_code"
}
trap on_error ERR

run_logged() {
  local name="$1"
  shift
  log "$name"
  "$@" >>"$INSTALL_LOG" 2>&1 || {
    local rc=$?
    warn "$name failed with exit code $rc. Last 80 log lines:"
    tail -n 80 "$INSTALL_LOG" >&2 || true
    return "$rc"
  }
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local timeout_seconds="${3:-120}"
  local start now
  start="$(date +%s)"

  while true; do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      log "$label is responding: $url"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      warn "$label did not respond within ${timeout_seconds}s: $url"
      return 1
    fi
    sleep 2
  done
}

port_listening() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

kill_matching() {
  local pattern="$1"
  pkill -f "$pattern" >/dev/null 2>&1 || true
}

export DEBIAN_FRONTEND=noninteractive

section "RunPod AI Stack $SCRIPT_VERSION"
log "Workspace: $WORKSPACE"
log "Logs: $LOG_DIR"

section "System dependencies"
run_logged "Updating apt package metadata..." apt-get update -qq
run_logged "Installing base packages..." \
  apt-get install -y --no-install-recommends \
    ca-certificates curl git ffmpeg sox libsox-fmt-all jq procps iproute2 \
    python3 python3-venv python3-pip \
    libnss3 libnspr4 libatk-bridge2.0-0 libatk1.0-0 libgtk-3-0 \
    libxkbcommon0 libgbm1 libasound2t64

command -v nvidia-smi >/dev/null 2>&1 \
  || fatal "nvidia-smi is unavailable. Start this script on an NVIDIA GPU pod."

section "Removing retired LLM and SDXL services"
kill_matching "ollama serve"
kill_matching "llama-server"
kill_matching "$IMAGE_DIR"
rm -rf --one-file-system \
  "$WORKSPACE/.ollama" \
  "$IMAGE_DIR" \
  "$GENERATED_DIR" \
  /usr/lib/ollama \
  /usr/local/lib/ollama
log "Removed Ollama models/runtime and the SDXL service/output directories."

GPU_NAME="$(
  nvidia-smi --query-gpu=name --format=csv,noheader \
    | head -n 1 | xargs
)"
GPU_MEMORY_MB="$(
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
    | head -n 1 | tr -d ' '
)"
DRIVER_VERSION="$(
  nvidia-smi --query-gpu=driver_version --format=csv,noheader \
    | head -n 1 | xargs
)"

[[ "$GPU_MEMORY_MB" =~ ^[0-9]+$ ]] \
  || fatal "Could not determine GPU memory."

if [[ -n "${OLLAMA_CONTEXT_LENGTH:-}" ]]; then
  DEFAULT_CONTEXT="$OLLAMA_CONTEXT_LENGTH"
elif (( GPU_MEMORY_MB < 30000 )); then
  DEFAULT_CONTEXT=2048
elif (( GPU_MEMORY_MB < 48000 )); then
  DEFAULT_CONTEXT=8192
else
  DEFAULT_CONTEXT=16384
fi

log "GPU: $GPU_NAME"
log "GPU memory: ${GPU_MEMORY_MB} MiB"
log "NVIDIA driver: $DRIVER_VERSION"
log "Default Ollama context: $DEFAULT_CONTEXT"
log "HF_HOME: $HF_HOME"
log "Container cache root: $CONTAINER_CACHE_ROOT"

# Recover space from older script versions that placed large model caches under
# /workspace. This is safe for this disposable-pod architecture because the new
# canonical locations are on the container filesystem and models will be
# downloaded there as needed.
if [[ "$CLEAN_LEGACY_WORKSPACE_CACHES" == "true" ]]; then
  LEGACY_HF_CACHE="$WORKSPACE/.cache/huggingface"
  LEGACY_OLLAMA_MODELS="$WORKSPACE/.ollama/models"

  if [[ "$LEGACY_HF_CACHE" != "$HF_HOME" && -d "$LEGACY_HF_CACHE" ]]; then
    LEGACY_HF_SIZE="$(du -sh "$LEGACY_HF_CACHE" 2>/dev/null | awk '{print $1}' || true)"
    warn "Removing legacy Hugging Face cache from /workspace (${LEGACY_HF_SIZE:-unknown}): $LEGACY_HF_CACHE"
    rm -rf --one-file-system "$LEGACY_HF_CACHE"
  fi

  if [[ "$LEGACY_OLLAMA_MODELS" != "$OLLAMA_MODELS_DEFAULT" && -d "$LEGACY_OLLAMA_MODELS" ]]; then
    LEGACY_OLLAMA_SIZE="$(du -sh "$LEGACY_OLLAMA_MODELS" 2>/dev/null | awk '{print $1}' || true)"
    warn "Removing legacy Ollama model cache from /workspace (${LEGACY_OLLAMA_SIZE:-unknown}): $LEGACY_OLLAMA_MODELS"
    rm -rf --one-file-system "$LEGACY_OLLAMA_MODELS"
  fi

  # Remove empty legacy cache directories only; do not remove code/logs.
  rmdir "$WORKSPACE/.cache" 2>/dev/null || true
  rmdir "$WORKSPACE/.ollama" 2>/dev/null || true
fi

# /workspace is reserved for lightweight runtime state. Fail early if it remains
# critically full after legacy cleanup.
WORKSPACE_FREE_MB="$(df -Pk "$WORKSPACE" | awk 'NR==2 {printf "%.0f", $4/1024}')"
WORKSPACE_USE_PCT="$(df -Pk "$WORKSPACE" | awk 'NR==2 {gsub("%","",$5); print $5}')"
log "/workspace free space after cleanup: ${WORKSPACE_FREE_MB:-unknown} MiB; usage ${WORKSPACE_USE_PCT:-unknown}%"

if [[ "${WORKSPACE_FREE_MB:-0}" =~ ^[0-9]+$ ]] && (( WORKSPACE_FREE_MB < 2048 )); then
  df -h "$WORKSPACE" / "$CONTAINER_CACHE_ROOT" >&2 || true
  du -xhd1 "$WORKSPACE" 2>/dev/null | sort -h | tail -30 >&2 || true
  fatal "/workspace has less than 2 GiB free after cache cleanup. Heavy caches must not be stored there."
fi

CONTAINER_FREE_GB="$(df -Pk "$CONTAINER_CACHE_ROOT" | awk 'NR==2 {printf "%.0f", $4/1024/1024}')"
log "Container cache filesystem free space: ${CONTAINER_FREE_GB:-unknown} GiB"

if [[ "${CONTAINER_FREE_GB:-0}" =~ ^[0-9]+$ ]] && (( CONTAINER_FREE_GB < 45 )); then
  df -h / "$CONTAINER_CACHE_ROOT" >&2 || true
  fatal "Container filesystem has less than 45 GiB free before model installation."
fi
if [[ -n "${HF_HUB_ENABLE_HF_TRANSFER:-}" ]]; then
  warn "Inherited HF_HUB_ENABLE_HF_TRANSFER=${HF_HUB_ENABLE_HF_TRANSFER}; TTS subprocess will remove it."
fi

# ------------------------------------------------------------------------------
# Ollama
# ------------------------------------------------------------------------------

if [[ "$LLM_ENABLED" == "true" ]]; then
section "Ollama installation and integrity"

export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="${OLLAMA_MODELS:-$OLLAMA_MODELS_DEFAULT}"
export OLLAMA_CONTEXT_LENGTH="$DEFAULT_CONTEXT"
export OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE"
mkdir -p "$OLLAMA_MODELS"
log "Ollama model storage: $OLLAMA_MODELS"
df -h "$OLLAMA_MODELS" | tee -a "$STARTUP_LOG" || true

# Stop any previous daemon before reinstalling. The official installer is
# intentionally run every time: it is also Ollama's supported Linux update
# mechanism and repairs incomplete CLI/runtime installations.
kill_matching "ollama serve"
kill_matching "llama-server"
sleep 2

log "Installing/updating Ollama using the official Linux installer..."
if ! curl -fsSL https://ollama.com/install.sh \
    | sh >>"$INSTALL_LOG" 2>&1; then
  tail -n 120 "$INSTALL_LOG" >&2 || true
  fatal "Official Ollama installation failed."
fi

command -v ollama >/dev/null 2>&1 \
  || fatal "Ollama installer completed but 'ollama' is not in PATH."

log "Ollama executable: $(command -v ollama)"
log "Ollama version: $(ollama --version 2>&1 | head -n 1)"

# Runtime integrity diagnostics. Current packages may place runners under
# different lib directories, so this is informational; the functional preflight
# below is the authoritative check.
{
  echo "=== $(timestamp) Ollama runtime file scan ==="
  find /usr/lib/ollama /usr/local/lib/ollama \
    -maxdepth 5 -type f \
    \( -name 'llama-server' -o -name 'llama-server*' \) \
    -print 2>/dev/null || true
} >>"$PREFLIGHT_LOG"

log "Starting Ollama daemon..."
nohup env \
  OLLAMA_HOST="$OLLAMA_HOST" \
  OLLAMA_MODELS="$OLLAMA_MODELS" \
  OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH" \
  OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
  ollama serve >>"$OLLAMA_LOG" 2>&1 &
echo $! >"$RUN_DIR/ollama.pid"

if ! wait_for_http "http://127.0.0.1:11434/api/tags" "Ollama daemon" 120; then
  tail -n 120 "$OLLAMA_LOG" >&2 || true
  fatal "Ollama daemon failed to start."
fi

log "Checking model availability: $OLLAMA_MODEL"
if ! ollama list | awk 'NR>1 {print $1}' | grep -Fxq "$OLLAMA_MODEL"; then
  log "Pulling model $OLLAMA_MODEL (this can take several minutes)..."
  if ! ollama pull "$OLLAMA_MODEL" 2>&1 | tee -a "$INSTALL_LOG"; then
    tail -n 120 "$INSTALL_LOG" >&2 || true
    fatal "Failed to pull Ollama model: $OLLAMA_MODEL"
  fi
else
  log "Model already present: $OLLAMA_MODEL"
fi

# A real inference preflight catches the exact class of failure where the Ollama
# API daemon starts and models pull successfully but the llama-server runtime is
# missing or broken.
if [[ "$OLLAMA_PREFLIGHT" == "true" ]]; then
  section "Ollama functional preflight"
  log "Running a minimal real inference test with $OLLAMA_MODEL..."
  PREFLIGHT_JSON="$RUN_DIR/ollama-preflight.json"
  PREFLIGHT_HTTP_CODE="$(
    curl -sS \
      --connect-timeout 10 \
      --max-time 600 \
      -o "$PREFLIGHT_JSON" \
      -w '%{http_code}' \
      http://127.0.0.1:11434/api/generate \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc \
        --arg model "$OLLAMA_MODEL" \
        '{
          model:$model,
          prompt:"Reply only with OK",
          stream:false,
          think:false,
          keep_alive:"0",
          options:{
            num_ctx:512,
            num_predict:2,
            temperature:0
          }
        }'
      )" || true
  )"

  {
    echo "=== $(timestamp) Ollama inference preflight ==="
    echo "HTTP status: $PREFLIGHT_HTTP_CODE"
    cat "$PREFLIGHT_JSON" 2>/dev/null || true
    echo
  } >>"$PREFLIGHT_LOG"

  if [[ "$PREFLIGHT_HTTP_CODE" != "200" ]]; then
    warn "Ollama inference preflight failed with HTTP $PREFLIGHT_HTTP_CODE."
    warn "Attempting one clean Ollama repair/reinstall before failing."

    kill_matching "ollama serve"
    kill_matching "llama-server"
    sleep 2

    # Remove only runtime libraries, never model storage.
    rm -rf /usr/lib/ollama /usr/local/lib/ollama 2>/dev/null || true

    if ! curl -fsSL https://ollama.com/install.sh \
        | sh >>"$INSTALL_LOG" 2>&1; then
      tail -n 120 "$INSTALL_LOG" >&2 || true
      fatal "Ollama repair installation failed."
    fi

    nohup env \
      OLLAMA_HOST="$OLLAMA_HOST" \
      OLLAMA_MODELS="$OLLAMA_MODELS" \
      OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH" \
      OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
      ollama serve >>"$OLLAMA_LOG" 2>&1 &
    echo $! >"$RUN_DIR/ollama.pid"

    wait_for_http "http://127.0.0.1:11434/api/tags" "Repaired Ollama daemon" 120 \
      || fatal "Ollama failed after repair."

    PREFLIGHT_HTTP_CODE="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 600 \
        -o "$PREFLIGHT_JSON" \
        -w '%{http_code}' \
        http://127.0.0.1:11434/api/generate \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
          --arg model "$OLLAMA_MODEL" \
          '{
            model:$model,
            prompt:"Reply only with OK",
            stream:false,
            think:false,
            keep_alive:"0",
            options:{
              num_ctx:512,
              num_predict:2,
              temperature:0
            }
          }'
        )" || true
    )"

    if [[ "$PREFLIGHT_HTTP_CODE" != "200" ]]; then
      {
        echo "=== $(timestamp) Ollama repair preflight failed ==="
        echo "HTTP status: $PREFLIGHT_HTTP_CODE"
        cat "$PREFLIGHT_JSON" 2>/dev/null || true
        echo
        echo "=== Last 200 Ollama log lines ==="
        tail -n 200 "$OLLAMA_LOG" 2>/dev/null || true
      } >>"$PREFLIGHT_LOG"

      tail -n 100 "$PREFLIGHT_LOG" >&2 || true
      fatal "Ollama daemon is reachable but real inference is broken. See $PREFLIGHT_LOG and $OLLAMA_LOG."
    fi
  fi

  log "Ollama real inference preflight passed."
else
  warn "OLLAMA_PREFLIGHT=false: skipping real model inference verification."
fi

# Ensure no model remains loaded after setup.
curl -fsS --max-time 30 \
  http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg model "$OLLAMA_MODEL" \
    '{model:$model,prompt:"",stream:false,keep_alive:0}')" \
  >/dev/null 2>&1 || true
elif [[ "$LLM_ENABLED" == "false" ]]; then
  section "Ollama/LLM disabled"
  log "Skipping Ollama installation, model download, daemon startup, and LLM preflight."
  kill_matching "ollama serve"
  kill_matching "llama-server"
else
  fatal "LLM_ENABLED must be true or false."
fi

# ------------------------------------------------------------------------------
# Qwen3-TTS
# ------------------------------------------------------------------------------

section "Qwen3-TTS installation"
log "Qwen3-TTS Hugging Face cache: $HF_HOME"

if [[ ! -d "$TTS_DIR/.git" ]]; then
  log "Cloning Qwen3-TTS OpenAI-compatible server..."
  rm -rf "$TTS_DIR"
  if ! git clone --depth 1 \
      https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi.git \
      "$TTS_DIR" >>"$INSTALL_LOG" 2>&1; then
    tail -n 100 "$INSTALL_LOG" >&2 || true
    fatal "Failed to clone Qwen3-TTS repository."
  fi
else
  log "Qwen3-TTS repository already exists; preserving current checkout."
fi

if [[ ! -x "$TTS_VENV/bin/python" ]]; then
  log "Creating Qwen3-TTS virtual environment..."
  python3 -m venv --system-site-packages "$TTS_VENV"
fi

run_logged "Updating Qwen3-TTS packaging tools..." \
  "$TTS_VENV/bin/python" -m pip install --upgrade pip setuptools wheel

run_logged "Installing/updating Qwen3-TTS API dependencies..." \
  "$TTS_VENV/bin/python" -m pip install -e "$TTS_DIR[api]"

run_logged "Installing Hugging Face transfer helpers..." \
  "$TTS_VENV/bin/python" -m pip install -U hf_transfer hf-xet

log "Validating Hugging Face transfer runtime..."
if ! env -u HF_HUB_ENABLE_HF_TRANSFER \
  HF_XET_HIGH_PERFORMANCE=1 \
  HF_HOME="$HF_HOME" \
  "$TTS_VENV/bin/python" - <<'PY' >>"$PREFLIGHT_LOG" 2>&1
import os
import huggingface_hub
print("huggingface_hub:", huggingface_hub.__version__)
print("HF_HUB_ENABLE_HF_TRANSFER:", os.getenv("HF_HUB_ENABLE_HF_TRANSFER"))
print("HF_XET_HIGH_PERFORMANCE:", os.getenv("HF_XET_HIGH_PERFORMANCE"))
import hf_transfer
print("hf_transfer: available")
import hf_xet
print("hf_xet: available")
PY
then
  tail -n 100 "$PREFLIGHT_LOG" >&2 || true
  fatal "Hugging Face transfer runtime validation failed."
fi

log "Validating Qwen3-TTS Python entry point..."
if ! (
  cd "$TTS_DIR"
  "$TTS_VENV/bin/python" - <<'PY'
import importlib.util
import sys

spec = importlib.util.find_spec("api.main")
if spec is None:
    print("api.main could not be located", file=sys.stderr)
    raise SystemExit(1)
print("api.main import target found:", spec.origin)
PY
) >>"$PREFLIGHT_LOG" 2>&1; then
  tail -n 80 "$PREFLIGHT_LOG" >&2 || true
  fatal "Qwen3-TTS API entry point validation failed."
fi

# ------------------------------------------------------------------------------
# Gateway environment
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# SDXL text-to-image service
# ------------------------------------------------------------------------------

if false; then
section "SDXL text-to-image installation"
log "SDXL Hugging Face cache: $HF_HOME"

if [[ ! -x "$IMAGE_VENV/bin/python" ]]; then
  log "Creating isolated image-service virtual environment..."
  python3 -m venv --system-site-packages "$IMAGE_VENV"
fi

run_logged "Updating image-service packaging tools..." \
  "$IMAGE_VENV/bin/python" -m pip install --upgrade pip setuptools wheel

# Keep image dependencies isolated from the known-good LLM and TTS environments.
run_logged "Installing SDXL/Diffusers image dependencies..." \
  "$IMAGE_VENV/bin/python" -m pip install -U \
    fastapi uvicorn diffusers transformers accelerate safetensors \
    sentencepiece protobuf pillow huggingface_hub hf-xet

log "Validating image-service Python dependencies..."
if ! env -u HF_HUB_ENABLE_HF_TRANSFER \
  HF_XET_HIGH_PERFORMANCE=1 \
  HF_HOME="$HF_HOME" \
  "$IMAGE_VENV/bin/python" - <<'PY' >>"$PREFLIGHT_LOG" 2>&1
import torch
import diffusers
import transformers
import accelerate
from PIL import Image

print("torch:", torch.__version__)
print("cuda_available:", torch.cuda.is_available())
print("diffusers:", diffusers.__version__)
print("transformers:", transformers.__version__)
print("accelerate:", accelerate.__version__)

if not torch.cuda.is_available():
    raise RuntimeError("CUDA is not available to the image-service environment.")
PY
then
  tail -n 100 "$PREFLIGHT_LOG" >&2 || true
  fatal "Image-service dependency validation failed."
fi

cat >"$IMAGE_DIR/app.py" <<'PY'
from __future__ import annotations

import gc
import json
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any

import torch
from diffusers import StableDiffusionXLPipeline
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

MODEL_ID = os.getenv("IMAGE_MODEL", "stabilityai/stable-diffusion-xl-base-1.0")
OUTPUT_DIR = Path(os.getenv("IMAGE_OUTPUT_DIR", "/workspace/generated/images"))
HF_HOME = os.getenv("HF_HOME", "/root/.cache/huggingface/shared")
DEFAULT_WIDTH = int(os.getenv("IMAGE_DEFAULT_WIDTH", "1024"))
DEFAULT_HEIGHT = int(os.getenv("IMAGE_DEFAULT_HEIGHT", "1024"))
DEFAULT_STEPS = int(os.getenv("IMAGE_DEFAULT_STEPS", "30"))

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("HF_HOME", HF_HOME)
os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
os.environ.pop("HF_HUB_ENABLE_HF_TRANSFER", None)

APP = FastAPI(
    title="RunPod SDXL Image Service",
    version="1.0.0",
)

_pipeline: StableDiffusionXLPipeline | None = None
_model_lock = threading.Lock()
_generation_lock = threading.Lock()
_loaded_at: float | None = None


class ImageRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    width: int = Field(default=DEFAULT_WIDTH, ge=256, le=1536, multiple_of=16)
    height: int = Field(default=DEFAULT_HEIGHT, ge=256, le=1536, multiple_of=16)
    steps: int = Field(default=DEFAULT_STEPS, ge=1, le=100)
    guidance_scale: float = Field(default=7.0, ge=0.0, le=20.0)
    seed: int | None = Field(default=None, ge=0, le=2**63 - 1)


def load_pipeline() -> StableDiffusionXLPipeline:
    global _pipeline, _loaded_at

    if _pipeline is not None:
        return _pipeline

    with _model_lock:
        if _pipeline is not None:
            return _pipeline

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is unavailable.")

        # SDXL 1.0 is ungated and can run fully locally after download.
        # float16 is broadly compatible on NVIDIA GPUs and works well on the
        # tested L40 48 GB. The service is mutually exclusive with LLM/TTS.
        pipe = StableDiffusionXLPipeline.from_pretrained(
            MODEL_ID,
            torch_dtype=torch.float16,
            use_safetensors=True,
            cache_dir=HF_HOME,
        )
        pipe.to("cuda")

        # Keep VAE memory bounded for 1024+ images.
        if hasattr(pipe, "vae"):
            try:
                pipe.vae.enable_tiling()
            except Exception:
                pass
            try:
                pipe.vae.enable_slicing()
            except Exception:
                pass

        _pipeline = pipe
        _loaded_at = time.time()
        return pipe


@APP.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": MODEL_ID,
        "model_loaded": _pipeline is not None,
        "loaded_at": _loaded_at,
        "cuda_available": torch.cuda.is_available(),
    }


@APP.get("/status")
def image_status() -> dict[str, Any]:
    memory = {}
    if torch.cuda.is_available():
        free_bytes, total_bytes = torch.cuda.mem_get_info()
        memory = {
            "gpu_free_mb": int(free_bytes / 1024 / 1024),
            "gpu_total_mb": int(total_bytes / 1024 / 1024),
        }
    return {
        "state": "loaded" if _pipeline is not None else "ready",
        "model": MODEL_ID,
        **memory,
    }


@APP.post("/generate")
def generate(req: ImageRequest):
    if not _generation_lock.acquire(blocking=False):
        raise HTTPException(status_code=409, detail="An image generation is already running.")

    try:
        pipe = load_pipeline()

        seed = req.seed if req.seed is not None else secrets.randbits(63)
        generator = torch.Generator(device="cpu").manual_seed(seed)

        started = time.time()
        result = pipe(
            prompt=req.prompt,
            width=req.width,
            height=req.height,
            num_inference_steps=req.steps,
            guidance_scale=req.guidance_scale,
            generator=generator,
        )

        if not result.images:
            raise RuntimeError("SDXL returned no image.")

        filename = f"{int(time.time())}-{secrets.token_hex(8)}.png"
        path = OUTPUT_DIR / filename
        result.images[0].save(path, format="PNG", optimize=True)

        return {
            "created": int(time.time()),
            "model": MODEL_ID,
            "seed": seed,
            "width": req.width,
            "height": req.height,
            "steps": req.steps,
            "generation_seconds": round(time.time() - started, 3),
            "filename": filename,
        }
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=f"{type(exc).__name__}: {exc}",
        ) from exc
    finally:
        _generation_lock.release()
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()


@APP.get("/files/{filename}")
def file(filename: str):
    safe = Path(filename).name
    path = OUTPUT_DIR / safe
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Image not found")
    return FileResponse(path, media_type="image/png", filename=safe)
PY

"$IMAGE_VENV/bin/python" - <<PY
import py_compile
py_compile.compile(r"$IMAGE_DIR/app.py", cfile="/tmp/image-service-app.pyc", doraise=True)
print("image-service app.py compile: OK")
PY
fi


# ------------------------------------------------------------------------------
# HunyuanVideo-1.5 public 480p I2V step-distilled service
# Fully public Diffusers-compatible checkpoint; no gated FLUX/Gemma dependency.
# ------------------------------------------------------------------------------

section "HunyuanVideo-1.5 public 480p I2V step-distilled installation"

HUNYUAN_MODEL_ID="hunyuanvideo-community/HunyuanVideo-1.5-Diffusers-480p_i2v_step_distilled"
HUNYUAN_MODEL_DIR="$VIDEO_HF_HOME/model"
VIDEO_JOB_DIR="$RUN_DIR/video-jobs"
VIDEO_INPUT_DIR="$RUN_DIR/video-inputs"

mkdir -p "$VIDEO_HF_HOME" "$HUNYUAN_MODEL_DIR" "$VIDEO_JOB_DIR" "$VIDEO_INPUT_DIR"

# Recover disk from obsolete video backends.
for OLD_VIDEO_CACHE in \
  "/root/.cache/huggingface/hunyuan15-i2v" \
  "/root/.cache/huggingface/ltx23"
do
  if [[ -d "$OLD_VIDEO_CACHE" && "$OLD_VIDEO_CACHE" != "$VIDEO_HF_HOME" ]]; then
    OLD_SIZE="$(du -sh "$OLD_VIDEO_CACHE" 2>/dev/null | awk '{print $1}' || true)"
    warn "Removing obsolete video cache (${OLD_SIZE:-unknown}): $OLD_VIDEO_CACHE"
    rm -rf --one-file-system "$OLD_VIDEO_CACHE"
  fi
done

log "HunyuanVideo-1.5 cache root: $VIDEO_HF_HOME"
df -h / "$VIDEO_HF_HOME" "$WORKSPACE" 2>/dev/null | tee -a "$STARTUP_LOG" || true

if [[ ! -x "$VIDEO_VENV/bin/python" ]]; then
  log "Creating isolated HunyuanVideo video virtual environment..."
  python3 -m venv --system-site-packages "$VIDEO_VENV"
fi

run_logged "Updating HunyuanVideo video packaging tools..." \
  "$VIDEO_VENV/bin/python" -m pip install --upgrade pip setuptools wheel

# Isolated package set. Keep Transformers below v5 to avoid unrelated future breaks.
run_logged "Installing HunyuanVideo-1.5 Diffusers runtime..." \
  "$VIDEO_VENV/bin/python" -m pip install -U \
    "diffusers==0.39.0" \
    "transformers>=4.49,<5" \
    "accelerate>=1.2" \
    "huggingface_hub>=0.34,<1.0" \
    safetensors sentencepiece protobuf \
    fastapi uvicorn python-multipart \
    pillow imageio imageio-ffmpeg psutil packaging

log "Validating HunyuanVideo-1.5 runtime imports..."
if ! env -u HF_HUB_ENABLE_HF_TRANSFER \
  HF_HOME="$VIDEO_HF_HOME" \
  "$VIDEO_VENV/bin/python" - <<'PY2' >>"$PREFLIGHT_LOG" 2>&1
import torch
import diffusers
import transformers
from diffusers import HunyuanVideo15ImageToVideoPipeline
from diffusers.utils import export_to_video
import inspect

call_params = inspect.signature(HunyuanVideo15ImageToVideoPipeline.__call__).parameters
required = {"image", "prompt", "num_frames", "num_inference_steps", "generator"}
missing = sorted(required - set(call_params))
if missing:
    raise RuntimeError(f"Unexpected HunyuanVideo15 I2V API; missing parameters: {missing}")

if "height" in call_params or "width" in call_params:
    print("NOTE: height/width are exposed by this installed version, but service intentionally derives size from normalized input image.")
else:
    print("HunyuanVideo15 I2V spatial sizing: derived from conditioning image (no height/width kwargs).")

print("HunyuanVideo15ImageToVideoPipeline __call__ contract: OK")
print("Attention backend policy: Diffusers default PyTorch SDPA-compatible path")
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("cuda_available:", torch.cuda.is_available())
print("diffusers:", diffusers.__version__)
print("transformers:", transformers.__version__)
print("HunyuanVideo15ImageToVideoPipeline import: OK")

if not torch.cuda.is_available():
    raise RuntimeError("CUDA is unavailable.")
PY2
then
  tail -n 180 "$PREFLIGHT_LOG" >&2 || true
  fatal "HunyuanVideo-1.5 runtime import validation failed."
fi

# Verify the exact public model can be accessed WITHOUT a token before large download.
log "Validating authorization-free access to public HunyuanVideo-1.5 checkpoint..."
if ! env -u HF_TOKEN -u HUGGING_FACE_HUB_TOKEN -u HF_HUB_ENABLE_HF_TRANSFER \
  HF_HOME="$VIDEO_HF_HOME" \
  "$VIDEO_VENV/bin/python" - <<'PY2' >>"$PREFLIGHT_LOG" 2>&1
from huggingface_hub import hf_hub_download

repo_id = "hunyuanvideo-community/HunyuanVideo-1.5-Diffusers-480p_i2v_step_distilled"
path = hf_hub_download(repo_id=repo_id, filename="model_index.json", token=False)
print("Public model_index download: OK", path)
PY2
then
  tail -n 160 "$PREFLIGHT_LOG" >&2 || true
  fatal "Public HunyuanVideo-1.5 checkpoint access failed without authentication."
fi

HUNYUAN_DOWNLOAD_COMPLETE="$HUNYUAN_MODEL_DIR/.download-complete"
if [[ ! -f "$HUNYUAN_DOWNLOAD_COMPLETE" ]]; then
  log "Downloading public HunyuanVideo-1.5 480p I2V step-distilled pipeline..."
  rm -f "$HUNYUAN_DOWNLOAD_COMPLETE"

  env -u HF_TOKEN -u HUGGING_FACE_HUB_TOKEN -u HF_HUB_ENABLE_HF_TRANSFER \
    HF_HOME="$VIDEO_HF_HOME" \
    "$VIDEO_VENV/bin/python" - <<PY2 >>"$INSTALL_LOG" 2>&1
from pathlib import Path
from huggingface_hub import snapshot_download

target = Path(r"$HUNYUAN_MODEL_DIR")
target.mkdir(parents=True, exist_ok=True)

snapshot_download(
    repo_id="$HUNYUAN_MODEL_ID",
    local_dir=str(target),
    token=False,
)

required = [
    target / "model_index.json",
    target / "transformer",
    target / "vae",
]
missing = [str(p) for p in required if not p.exists()]
if missing:
    raise RuntimeError(f"Incomplete HunyuanVideo download; missing: {missing}")

(target / ".download-complete").write_text("ok\n")
print("HunyuanVideo-1.5 public pipeline download complete.")
PY2
else
  log "HunyuanVideo-1.5 completion marker found; reusing downloaded model."
fi

[[ -f "$HUNYUAN_DOWNLOAD_COMPLETE" ]] || fatal "HunyuanVideo-1.5 download did not complete."

# Validate local-only pipeline metadata before launching service.
log "Validating HunyuanVideo local pipeline structure..."
if ! env \
  HF_HOME="$VIDEO_HF_HOME" \
  HF_HUB_OFFLINE=1 \
  TRANSFORMERS_OFFLINE=1 \
  "$VIDEO_VENV/bin/python" - <<PY2 >>"$PREFLIGHT_LOG" 2>&1
from pathlib import Path
import json

root = Path(r"$HUNYUAN_MODEL_DIR")
idx = json.loads((root / "model_index.json").read_text())
print("pipeline class:", idx.get("_class_name"))
print("model root:", root)
assert (root / "transformer").is_dir()
assert (root / "vae").is_dir()
print("Local pipeline structure: OK")
PY2
then
  tail -n 180 "$PREFLIGHT_LOG" >&2 || true
  fatal "HunyuanVideo local pipeline structure validation failed."
fi

cat >"$VIDEO_DIR/app.py" <<'PY2'
from __future__ import annotations

import gc
import io
import json
import os
import secrets
import threading
import time
import traceback
from pathlib import Path
from typing import Any

import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageOps

from diffusers import HunyuanVideo15ImageToVideoPipeline
from diffusers.utils import export_to_video

MODEL_ID = os.getenv(
    "VIDEO_MODEL",
    "hunyuanvideo-community/HunyuanVideo-1.5-Diffusers-480p_i2v_step_distilled",
)
MODEL_DIR = Path(
    os.getenv("HUNYUAN_MODEL_DIR", "/root/.cache/huggingface/hunyuan15-i2v/model")
)
OUTPUT_DIR = Path(os.getenv("VIDEO_OUTPUT_DIR", "/workspace/generated/videos"))
JOB_DIR = Path(os.getenv("VIDEO_JOB_DIR", "/workspace/ai-stack/run/video-jobs"))
INPUT_DIR = Path(os.getenv("VIDEO_INPUT_DIR", "/workspace/ai-stack/run/video-inputs"))
LOG_DIR = Path(os.getenv("LOG_DIR", "/workspace/logs"))

DEFAULT_WIDTH = int(os.getenv("VIDEO_DEFAULT_WIDTH", "480"))
DEFAULT_HEIGHT = int(os.getenv("VIDEO_DEFAULT_HEIGHT", "832"))
DEFAULT_FRAMES = int(os.getenv("VIDEO_DEFAULT_FRAMES", "121"))
DEFAULT_FPS = int(os.getenv("VIDEO_DEFAULT_FPS", "24"))
DEFAULT_STEPS = int(os.getenv("VIDEO_DEFAULT_STEPS", "12"))

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
JOB_DIR.mkdir(parents=True, exist_ok=True)
INPUT_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)

APP = FastAPI(
    title="RunPod HunyuanVideo-1.5 Public Step-Distilled Async Video Service",
    version="1.0.0",
)

_jobs_lock = threading.Lock()
_worker_lock = threading.Lock()
_pipeline_lock = threading.Lock()

_PIPE = None
_PIPELINE_LOADING = False
_PIPELINE_ERROR: str | None = None
_PIPELINE_LOADED_AT: int | None = None


def job_path(job_id: str) -> Path:
    return JOB_DIR / f"{job_id}.json"


def read_job(job_id: str) -> dict[str, Any] | None:
    path = job_path(job_id)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def write_job(job: dict[str, Any]) -> None:
    path = job_path(job["job_id"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, indent=2))
    tmp.replace(path)


def update_job(job_id: str, **changes: Any) -> dict[str, Any]:
    with _jobs_lock:
        job = read_job(job_id)
        if job is None:
            raise RuntimeError(f"Job disappeared: {job_id}")
        job.update(changes)
        job["updated_at"] = int(time.time())
        write_job(job)
        return job


def normalize_image(raw: bytes, destination: Path, width: int, height: int) -> None:
    try:
        with Image.open(io.BytesIO(raw)) as source:
            source = source.convert("RGB")
            normalized = ImageOps.fit(
                source,
                (width, height),
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
            normalized.save(destination, format="PNG", optimize=True)
    except Exception as exc:
        raise ValueError(f"Invalid or unsupported input image: {exc}") from exc

    if not destination.is_file() or destination.stat().st_size < 512:
        raise ValueError("Normalized input image was not created correctly.")


def ensure_pipeline():
    global _PIPE, _PIPELINE_LOADING, _PIPELINE_ERROR, _PIPELINE_LOADED_AT

    if _PIPE is not None:
        return _PIPE

    with _pipeline_lock:
        if _PIPE is not None:
            return _PIPE

        _PIPELINE_LOADING = True
        try:
            pipe = HunyuanVideo15ImageToVideoPipeline.from_pretrained(
                str(MODEL_DIR),
                torch_dtype=torch.bfloat16,
                local_files_only=True,
            )

            # Official memory-safe path. L40 46GB may not fit the whole 8B pipeline
            # together with all text encoders without offload.
            pipe.enable_model_cpu_offload()
            pipe.vae.enable_tiling()

            # Do not force FlashAttention here. HunyuanVideo-1.5 I2V passes
            # an attention mask during transformer inference, while the
            # FlashAttention-2 backend rejects attn_mask. Keep Diffusers'
            # compatible default attention backend.
            try:
                if hasattr(pipe.transformer, "reset_attention_backend"):
                    pipe.transformer.reset_attention_backend()
            except Exception:
                # Freshly loaded Diffusers models already use their default
                # attention backend, so reset failure is non-fatal.
                pass

            _PIPE = pipe
            _PIPELINE_LOADED_AT = int(time.time())
            _PIPELINE_ERROR = None
            return pipe
        except Exception as exc:
            _PIPELINE_ERROR = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            _PIPELINE_LOADING = False


def warm_pipeline() -> None:
    try:
        ensure_pipeline()
    except Exception:
        pass


def run_generation(job_id: str) -> None:
    with _worker_lock:
        job = read_job(job_id)
        if job is None:
            return

        input_path = Path(job["input_path"])
        output_path = Path(job["output_path"])
        log_path = LOG_DIR / f"video-job-{job_id}.log"

        update_job(
            job_id,
            status="processing",
            stage="loading_model",
            started_at=int(time.time()),
            log=str(log_path),
        )

        try:
            load_started = time.time()
            pipe = ensure_pipeline()
            model_load_seconds = round(time.time() - load_started, 3)

            update_job(
                job_id,
                stage="generating",
                model_load_seconds=model_load_seconds,
                persistent_pipeline=True,
            )

            with Image.open(input_path) as src:
                image = src.convert("RGB")

            generator = torch.Generator(device="cuda").manual_seed(job["seed"])
            started = time.time()

            # HunyuanVideo15ImageToVideoPipeline derives spatial dimensions
            # from the conditioning image. The uploaded image has already been
            # normalized to the configured portrait canvas (480x832), so do not
            # pass unsupported height/width kwargs here.
            result = pipe(
                prompt=job["prompt"],
                image=image,
                num_frames=job["num_frames"],
                num_inference_steps=job["steps"],
                generator=generator,
            )

            frames = result.frames[0]
            generation_seconds = round(time.time() - started, 3)

            update_job(job_id, stage="encoding")
            output_path.parent.mkdir(parents=True, exist_ok=True)
            export_to_video(frames, str(output_path), fps=job["fps"])

            del result, frames
            gc.collect()
            torch.cuda.empty_cache()

            if not output_path.is_file() or output_path.stat().st_size < 1024:
                raise RuntimeError("Generation completed but no valid MP4 was produced.")

            update_job(
                job_id,
                status="completed",
                stage="completed",
                finished_at=int(time.time()),
                url=f"/files/generated/videos/{output_path.name}",
                duration_seconds=round(job["num_frames"] / job["fps"], 3),
                generation_seconds=generation_seconds,
                model_load_seconds=model_load_seconds,
                bytes=output_path.stat().st_size,
                persistent_pipeline=True,
            )
        except Exception as exc:
            try:
                log_path.write_text(traceback.format_exc())
            except Exception:
                pass
            update_job(
                job_id,
                status="failed",
                stage="failed",
                finished_at=int(time.time()),
                error=f"{type(exc).__name__}: {exc}",
                error_tail=traceback.format_exc()[-10000:],
            )
        finally:
            try:
                input_path.unlink(missing_ok=True)
            except Exception:
                pass


@APP.on_event("startup")
def startup_event() -> None:
    # Warm model as soon as video mode starts.
    threading.Thread(target=warm_pipeline, daemon=True).start()


@APP.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": MODEL_ID,
        "backend": "diffusers.HunyuanVideo15ImageToVideoPipeline",
        "step_distilled": True,
        "public_ungated_checkpoint": True,
        "async_jobs": True,
        "persistent_pipeline": True,
        "pipeline_loading": _PIPELINE_LOADING,
        "pipeline_loaded": _PIPE is not None,
        "pipeline_loaded_at": _PIPELINE_LOADED_AT,
        "pipeline_error": _PIPELINE_ERROR,
        "width": DEFAULT_WIDTH,
        "height": DEFAULT_HEIGHT,
        "frames": DEFAULT_FRAMES,
        "fps": DEFAULT_FPS,
        "default_steps": DEFAULT_STEPS,
        "attention_backend": "diffusers-default-sdpa",
    }


@APP.get("/status")
def service_status() -> dict[str, Any]:
    jobs = []
    for path in sorted(
        JOB_DIR.glob("*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:10]:
        try:
            jobs.append(json.loads(path.read_text()))
        except Exception:
            pass

    active = [j for j in jobs if j.get("status") in {"queued", "processing"}]
    state = "busy" if active else ("ready" if _PIPE is not None else "loading")

    return {
        "state": state,
        "model": MODEL_ID,
        "persistent_pipeline": True,
        "pipeline_loading": _PIPELINE_LOADING,
        "pipeline_loaded": _PIPE is not None,
        "pipeline_error": _PIPELINE_ERROR,
        "active_jobs": len(active),
        "recent_jobs": jobs[:5],
    }


@APP.post("/generate")
async def generate(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    width: int = Form(DEFAULT_WIDTH),
    height: int = Form(DEFAULT_HEIGHT),
    num_frames: int = Form(DEFAULT_FRAMES),
    fps: int = Form(DEFAULT_FPS),
    steps: int = Form(DEFAULT_STEPS),
    guidance_scale: float = Form(1.0),
    seed: int | None = Form(None),
):
    if not prompt.strip():
        raise HTTPException(status_code=422, detail="prompt is required")

    # 480p portrait preset. Multiples of 16 keep VAE/latent geometry safe.
    if width != DEFAULT_WIDTH or height != DEFAULT_HEIGHT:
        raise HTTPException(
            status_code=422,
            detail=f"Fast portrait preset requires {DEFAULT_WIDTH}x{DEFAULT_HEIGHT}.",
        )
    if num_frames < 25 or num_frames > 121 or (num_frames - 1) % 4 != 0:
        raise HTTPException(
            status_code=422,
            detail="num_frames must be between 25 and 121 and follow 4n + 1.",
        )
    if fps < 8 or fps > 24:
        raise HTTPException(
            status_code=422,
            detail="fps must be between 8 and 24.",
        )
    if steps not in {4, 8, 12}:
        raise HTTPException(
            status_code=422,
            detail="Step-distilled model supports practical presets of 4, 8, or 12 steps.",
        )

    raw = await image.read()
    if not raw:
        raise HTTPException(status_code=422, detail="Uploaded image is empty.")

    job_id = secrets.token_hex(16)
    input_path = INPUT_DIR / f"{job_id}.png"
    output_path = OUTPUT_DIR / f"{int(time.time())}-{job_id}.mp4"

    try:
        normalize_image(raw, input_path, width, height)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    actual_seed = int(seed) if seed is not None else secrets.randbits(31)

    job = {
        "job_id": job_id,
        "status": "queued",
        "stage": "queued",
        "created_at": int(time.time()),
        "updated_at": int(time.time()),
        "model": MODEL_ID,
        "backend": "diffusers.HunyuanVideo15ImageToVideoPipeline",
        "step_distilled": True,
        "prompt": prompt.strip(),
        "width": width,
        "height": height,
        "num_frames": num_frames,
        "fps": fps,
        "steps": steps,
        "guidance_scale": 1.0,
        "seed": actual_seed,
        "input_path": str(input_path),
        "output_path": str(output_path),
        "persistent_pipeline": True,
        "attention_backend": "diffusers-default-sdpa",
    }
    write_job(job)

    threading.Thread(target=run_generation, args=(job_id,), daemon=True).start()

    return JSONResponse(
        status_code=202,
        content={
            "accepted": True,
            "job_id": job_id,
            "status": "queued",
            "model": MODEL_ID,
            "backend": "HunyuanVideo-1.5 step-distilled",
            "status_url": f"/v1/videos/jobs/{job_id}",
        },
    )


@APP.get("/jobs/{job_id}")
def get_job(job_id: str):
    if not (len(job_id) == 32 and all(c in "0123456789abcdef" for c in job_id)):
        raise HTTPException(status_code=400, detail="Invalid job id.")

    job = read_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Video job not found.")

    return {
        k: v
        for k, v in job.items()
        if k not in {"input_path", "output_path"}
    }


@APP.get("/files/{filename}")
def file(filename: str):
    safe = Path(filename).name
    path = OUTPUT_DIR / safe
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Video not found.")
    return FileResponse(path, media_type="video/mp4", filename=safe)
PY2

"$VIDEO_VENV/bin/python" - <<PY
import py_compile
py_compile.compile(r"$VIDEO_DIR/app.py", cfile="/tmp/video-service-app.pyc", doraise=True)
print("video-service app.py compile: OK")
PY

log "Validating generated Hunyuan I2V service call contract..."
if grep -nE '^[[:space:]]*(height|width)=job\[' "$VIDEO_DIR/app.py" >>"$PREFLIGHT_LOG" 2>&1; then
  fatal "Generated Hunyuan I2V service incorrectly passes height/width into pipeline.__call__."
fi
log "Generated Hunyuan I2V call contract validated."

log "Validating Hunyuan attention backend policy..."
if grep -nE 'set_attention_backend.*flash' "$VIDEO_DIR/app.py" >>"$PREFLIGHT_LOG" 2>&1; then
  fatal "Generated Hunyuan service contains a forced FlashAttention backend."
fi
log "Hunyuan attention backend policy validated: no forced FlashAttention."

section "Gateway installation"

if [[ ! -x "$GATEWAY_VENV/bin/python" ]]; then
  log "Creating gateway virtual environment..."
  python3 -m venv "$GATEWAY_VENV"
fi

run_logged "Updating gateway packaging tools..." \
  "$GATEWAY_VENV/bin/python" -m pip install --upgrade pip setuptools wheel

run_logged "Installing gateway dependencies..." \
  "$GATEWAY_VENV/bin/python" -m pip install -U \
    fastapi uvicorn httpx psutil pydantic python-multipart

log "Validating gateway Python dependencies..."
if ! "$GATEWAY_VENV/bin/python" - <<'PY' >>"$PREFLIGHT_LOG" 2>&1
import fastapi
import uvicorn
import httpx
import psutil
import pydantic
import multipart

print("fastapi:", fastapi.__version__)
print("uvicorn:", uvicorn.__version__)
print("httpx:", httpx.__version__)
print("psutil:", psutil.__version__)
print("pydantic:", pydantic.__version__)
print("python-multipart: available")
PY
then
  tail -n 120 "$PREFLIGHT_LOG" >&2 || true
  fatal "Gateway dependency validation failed."
fi

cat >"$CONFIG_FILE" <<JSON
{
  "version": "$SCRIPT_VERSION",
  "workspace": "$WORKSPACE",
  "stack_dir": "$STACK_DIR",
  "log_dir": "$LOG_DIR",
  "run_dir": "$RUN_DIR",
  "tts_dir": "$TTS_DIR",
  "tts_python": "$TTS_VENV/bin/python",
  "tts_model_name": "$TTS_MODEL_NAME",
  "tts_backend": "$TTS_BACKEND",
  "tts_lazy_load": "$TTS_LAZY_LOAD",
  "tts_preflight": "$TTS_PREFLIGHT",
  "tts_autochunk": "$TTS_AUTOCHUNK",
  "hf_home": "$HF_HOME",
  "llm_enabled": $LLM_ENABLED,
  "ollama_model": "$OLLAMA_MODEL",
  "ollama_context": $DEFAULT_CONTEXT,
  "ollama_keep_alive": "$OLLAMA_KEEP_ALIVE",
  "gpu_memory_mb": $GPU_MEMORY_MB,
  "image_dir": "$IMAGE_DIR",
  "image_python": "$IMAGE_VENV/bin/python",
  "image_model": "$IMAGE_MODEL",
  "image_port": $IMAGE_PORT,
  "image_output_dir": "$GENERATED_DIR",
  "image_default_width": $IMAGE_DEFAULT_WIDTH,
  "image_default_height": $IMAGE_DEFAULT_HEIGHT,
  "image_default_steps": $IMAGE_DEFAULT_STEPS,
  "video_dir": "$VIDEO_DIR",
  "video_python": "$VIDEO_VENV/bin/python",
  "video_model": "$VIDEO_MODEL",
  "video_port": $VIDEO_PORT,
  "video_output_dir": "$GENERATED_VIDEO_DIR",
  "video_default_width": $VIDEO_DEFAULT_WIDTH,
  "video_default_height": $VIDEO_DEFAULT_HEIGHT,
  "video_default_frames": $VIDEO_DEFAULT_FRAMES,
  "video_default_fps": $VIDEO_DEFAULT_FPS,
  "video_default_steps": $VIDEO_DEFAULT_STEPS,
  "video_default_guidance": $VIDEO_DEFAULT_GUIDANCE,
  "video_hf_home": "$VIDEO_HF_HOME",
  "video_hf_hub_cache": "$VIDEO_HF_HUB_CACHE",
  "video_transformers_cache": "$VIDEO_TRANSFORMERS_CACHE"
}
JSON

cat >"$STATE_FILE" <<'JSON'
{
  "active_mode": "off",
  "transitioning": false,
  "target_mode": null,
  "stage": "idle",
  "operation_id": null,
  "last_error": null,
  "last_transition_started_at": null,
  "last_transition_finished_at": null
}
JSON

# ------------------------------------------------------------------------------
# FastAPI gateway
# ------------------------------------------------------------------------------

cat >"$GATEWAY_DIR/app.py" <<'PY'
from __future__ import annotations

import asyncio
import json
import os
import secrets
import socket
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
import psutil
from fastapi import Body, FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import JSONResponse, RedirectResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

CONFIG_FILE = Path(os.getenv("AI_STACK_CONFIG", "/workspace/ai-stack/config.json"))
STATE_FILE = Path(os.getenv("AI_STACK_STATE", "/workspace/ai-stack/state.json"))

CONFIG = json.loads(CONFIG_FILE.read_text())
LLM_ENABLED = bool(CONFIG.get("llm_enabled", False))

LOG_DIR = Path(CONFIG["log_dir"])
RUN_DIR = Path(CONFIG["run_dir"])
TTS_DIR = Path(CONFIG["tts_dir"])
TTS_PYTHON = CONFIG["tts_python"]
HF_HOME = str(CONFIG.get("hf_home", "/root/.cache/huggingface/shared"))
IMAGE_DIR = Path(CONFIG["image_dir"])
IMAGE_PYTHON = CONFIG["image_python"]
IMAGE_MODEL = CONFIG["image_model"]
IMAGE_PORT = int(CONFIG["image_port"])
IMAGE_OUTPUT_DIR = Path(CONFIG["image_output_dir"])
IMAGE_DEFAULT_WIDTH = int(CONFIG.get("image_default_width", 1024))
IMAGE_DEFAULT_HEIGHT = int(CONFIG.get("image_default_height", 1024))
IMAGE_DEFAULT_STEPS = int(CONFIG.get("image_default_steps", 30))
VIDEO_DIR = Path(CONFIG["video_dir"])
VIDEO_PYTHON = CONFIG["video_python"]
VIDEO_MODEL = CONFIG["video_model"]
VIDEO_PORT = int(CONFIG["video_port"])
VIDEO_OUTPUT_DIR = Path(CONFIG["video_output_dir"])
VIDEO_DEFAULT_WIDTH = int(CONFIG.get("video_default_width", 480))
VIDEO_DEFAULT_HEIGHT = int(CONFIG.get("video_default_height", 832))
VIDEO_DEFAULT_FRAMES = int(CONFIG.get("video_default_frames", 121))
VIDEO_DEFAULT_FPS = int(CONFIG.get("video_default_fps", 24))
VIDEO_DEFAULT_STEPS = int(CONFIG.get("video_default_steps", 12))
VIDEO_DEFAULT_GUIDANCE = float(CONFIG.get("video_default_guidance", 1.0))
VIDEO_HF_HOME = str(CONFIG.get("video_hf_home", "/root/.cache/huggingface/hunyuan15-i2v"))
VIDEO_HF_HUB_CACHE = str(CONFIG.get("video_hf_hub_cache", f"{VIDEO_HF_HOME}/hub"))
VIDEO_TRANSFORMERS_CACHE = str(CONFIG.get("video_transformers_cache", f"{VIDEO_HF_HOME}/transformers"))

DEFAULT_MODEL = CONFIG["ollama_model"]
DEFAULT_CONTEXT = int(CONFIG["ollama_context"])
DEFAULT_KEEP_ALIVE = CONFIG["ollama_keep_alive"]

OLLAMA_BASE = "http://127.0.0.1:11434"
TTS_BASE = "http://127.0.0.1:8880"
IMAGE_BASE = f"http://127.0.0.1:{IMAGE_PORT}"
VIDEO_BASE = f"http://127.0.0.1:{VIDEO_PORT}"
MCP_BASE = "http://127.0.0.1:8787"

TTS_PID_FILE = RUN_DIR / "tts.pid"
IMAGE_PID_FILE = RUN_DIR / "image.pid"
VIDEO_PID_FILE = RUN_DIR / "video.pid"
CONTROL_LOG = LOG_DIR / "service-control.log"
OLLAMA_LOG = LOG_DIR / "ollama.log"
TTS_LOG = LOG_DIR / "qwen3tts.log"
IMAGE_LOG = LOG_DIR / "image-service.log"
VIDEO_LOG = LOG_DIR / "video-service.log"

APP = FastAPI(
    title="RunPod AI Gateway",
    description="Single-GPU Qwen3-TTS and HunyuanVideo controller and proxy",
    version=str(CONFIG.get("version", "3")),
    docs_url="/gateway/docs",
    openapi_url="/gateway/openapi.json",
)

transition_lock = asyncio.Lock()
transition_task: asyncio.Task | None = None

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


class LLMStartRequest(BaseModel):
    model: str | None = None
    context: int | None = Field(default=None, ge=512, le=262144)
    keep_alive: str | None = None
    warmup: bool = True


class RestartRequest(BaseModel):
    warmup: bool = True


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log_control(message: str) -> None:
    CONTROL_LOG.parent.mkdir(parents=True, exist_ok=True)
    with CONTROL_LOG.open("a") as handle:
        handle.write(f"[{time.strftime('%F %T')}] {message}\n")


def read_state() -> dict[str, Any]:
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {
            "active_mode": "off",
            "transitioning": False,
            "target_mode": None,
            "stage": "state_read_error",
            "operation_id": None,
            "last_error": "Unable to read state file",
        }


def write_state(**changes: Any) -> dict[str, Any]:
    state = read_state()
    state.update(changes)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2))
    temporary.replace(STATE_FILE)
    return state


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def read_pid(path: Path) -> int | None:
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def process_alive(pid: int | None) -> bool:
    return bool(pid and psutil.pid_exists(pid))


def process_matches(fragment: str) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    for proc in psutil.process_iter(["pid", "name", "cmdline"]):
        try:
            command = " ".join(proc.info.get("cmdline") or [])
            name = proc.info.get("name") or ""
            if fragment in command or fragment in name:
                matches.append(
                    {
                        "pid": proc.info["pid"],
                        "name": name,
                        "command": command[:500],
                    }
                )
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return matches


def terminate_process_tree(pid: int, timeout: float = 20.0) -> None:
    try:
        parent = psutil.Process(pid)
    except psutil.NoSuchProcess:
        return

    try:
        processes = parent.children(recursive=True)
        for proc in reversed(processes):
            try:
                proc.terminate()
            except psutil.NoSuchProcess:
                pass
        parent.terminate()

        _, alive = psutil.wait_procs(processes + [parent], timeout=timeout)
        for proc in alive:
            try:
                proc.kill()
            except psutil.NoSuchProcess:
                pass
    except psutil.NoSuchProcess:
        pass


async def wait_until(predicate, timeout: float, interval: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(interval)
    return bool(predicate())


async def ollama_request(
    method: str,
    path: str,
    *,
    json_body: dict[str, Any] | None = None,
    timeout: float | None = 60,
) -> httpx.Response:
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await client.request(
            method,
            f"{OLLAMA_BASE}{path}",
            json=json_body,
        )


async def ollama_models() -> list[dict[str, Any]]:
    try:
        response = await ollama_request("GET", "/api/ps", timeout=5)
        response.raise_for_status()
        return response.json().get("models", [])
    except Exception:
        return []


async def unload_all_ollama_models() -> None:
    models = await ollama_models()

    for entry in models:
        model = entry.get("name") or entry.get("model")
        if not model:
            continue

        try:
            response = await ollama_request(
                "POST",
                "/api/generate",
                json_body={
                    "model": model,
                    "prompt": "",
                    "stream": False,
                    "keep_alive": 0,
                },
                timeout=60,
            )
            if response.status_code >= 400:
                log_control(
                    f"unload model={model} http={response.status_code} "
                    f"body={response.text[:1000]}"
                )
        except Exception as exc:
            log_control(f"unload model={model} exception={type(exc).__name__}: {exc}")
            subprocess.run(
                ["ollama", "stop", model],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    await wait_until(lambda: not process_matches("llama-server"), timeout=90)


def stop_tts_sync() -> None:
    pid = read_pid(TTS_PID_FILE)
    if process_alive(pid):
        terminate_process_tree(pid)

    # Clean up an untracked TTS process left by an earlier installer/run.
    for proc in process_matches(str(TTS_DIR)):
        command = proc["command"]
        if "api.main" in command or "uvicorn" in command:
            terminate_process_tree(proc["pid"])

    TTS_PID_FILE.unlink(missing_ok=True)


def start_tts_sync() -> int:
    stop_tts_sync()

    env = os.environ.copy()
    env.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
    env.update(
        {
            "HF_HOME": HF_HOME,
            "HF_XET_HIGH_PERFORMANCE": "1",
            "HOST": "127.0.0.1",
            "PORT": "8880",
            "WORKERS": "1",
            "TTS_BACKEND": str(CONFIG["tts_backend"]),
            "TTS_MODEL_NAME": str(CONFIG["tts_model_name"]),
            "TTS_LAZY_LOAD": str(CONFIG["tts_lazy_load"]).lower(),
            "TTS_AUTOCHUNK": str(CONFIG["tts_autochunk"]).lower(),
        }
    )

    handle = TTS_LOG.open("ab", buffering=0)
    proc = subprocess.Popen(
        [TTS_PYTHON, "-m", "api.main"],
        cwd=TTS_DIR,
        env=env,
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    TTS_PID_FILE.write_text(str(proc.pid))
    return proc.pid



def stop_image_sync() -> None:
    pid = read_pid(IMAGE_PID_FILE)
    if process_alive(pid):
        terminate_process_tree(pid)

    # Clean up untracked image-service processes left by an earlier run.
    for proc in process_matches(str(IMAGE_DIR)):
        command = proc["command"]
        if "uvicorn" in command and "8189" in command:
            terminate_process_tree(proc["pid"])

    IMAGE_PID_FILE.unlink(missing_ok=True)


def start_image_sync() -> int:
    stop_image_sync()

    env = os.environ.copy()
    env.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
    env.update(
        {
            "HF_HOME": HF_HOME,
            "HF_XET_HIGH_PERFORMANCE": "1",
            "IMAGE_MODEL": IMAGE_MODEL,
            "IMAGE_OUTPUT_DIR": str(IMAGE_OUTPUT_DIR),
            "IMAGE_DEFAULT_WIDTH": str(IMAGE_DEFAULT_WIDTH),
            "IMAGE_DEFAULT_HEIGHT": str(IMAGE_DEFAULT_HEIGHT),
            "IMAGE_DEFAULT_STEPS": str(IMAGE_DEFAULT_STEPS),
        }
    )

    IMAGE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    handle = IMAGE_LOG.open("ab", buffering=0)
    proc = subprocess.Popen(
        [
            IMAGE_PYTHON,
            "-m",
            "uvicorn",
            "app:APP",
            "--app-dir",
            str(IMAGE_DIR),
            "--host",
            "127.0.0.1",
            "--port",
            str(IMAGE_PORT),
        ],
        cwd=IMAGE_DIR,
        env=env,
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    IMAGE_PID_FILE.write_text(str(proc.pid))
    return proc.pid


def stop_video_sync() -> None:
    pid = read_pid(VIDEO_PID_FILE)
    if process_alive(pid):
        terminate_process_tree(pid)

    for proc in process_matches(str(VIDEO_DIR)):
        command = proc["command"]
        if "uvicorn" in command and str(VIDEO_PORT) in command:
            terminate_process_tree(proc["pid"])

    VIDEO_PID_FILE.unlink(missing_ok=True)


def start_video_sync() -> int:
    stop_video_sync()

    env = os.environ.copy()
    env.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
    env.update(
        {
            "HF_HOME": VIDEO_HF_HOME,
            "HF_HUB_CACHE": VIDEO_HF_HUB_CACHE,
            "HUGGINGFACE_HUB_CACHE": VIDEO_HF_HUB_CACHE,
            "TRANSFORMERS_CACHE": VIDEO_TRANSFORMERS_CACHE,
            "HF_XET_HIGH_PERFORMANCE": "1",
            "VIDEO_MODEL": VIDEO_MODEL,
            "HUNYUAN_MODEL_DIR": str(Path(VIDEO_HF_HOME) / "model"),
            "VIDEO_PYTHON": VIDEO_PYTHON,
            "VIDEO_JOB_DIR": str(RUN_DIR / "video-jobs"),
            "VIDEO_INPUT_DIR": str(RUN_DIR / "video-inputs"),
            "LOG_DIR": str(LOG_DIR),
            "VIDEO_OUTPUT_DIR": str(VIDEO_OUTPUT_DIR),
            "VIDEO_DEFAULT_WIDTH": str(VIDEO_DEFAULT_WIDTH),
            "VIDEO_DEFAULT_HEIGHT": str(VIDEO_DEFAULT_HEIGHT),
            "VIDEO_DEFAULT_FRAMES": str(VIDEO_DEFAULT_FRAMES),
            "VIDEO_DEFAULT_FPS": str(VIDEO_DEFAULT_FPS),
            "VIDEO_DEFAULT_STEPS": str(VIDEO_DEFAULT_STEPS),
            "VIDEO_DEFAULT_GUIDANCE": str(VIDEO_DEFAULT_GUIDANCE),
        }
    )

    VIDEO_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    handle = VIDEO_LOG.open("ab", buffering=0)
    proc = subprocess.Popen(
        [
            VIDEO_PYTHON,
            "-m",
            "uvicorn",
            "app:APP",
            "--app-dir",
            str(VIDEO_DIR),
            "--host",
            "127.0.0.1",
            "--port",
            str(VIDEO_PORT),
        ],
        cwd=VIDEO_DIR,
        env=env,
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    VIDEO_PID_FILE.write_text(str(proc.pid))
    return proc.pid


async def warm_llm(
    model: str,
    context: int,
    keep_alive: str,
) -> dict[str, Any]:
    response = await ollama_request(
        "POST",
        "/api/generate",
        json_body={
            "model": model,
            "prompt": "Reply only with ready",
            "stream": False,
            "think": False,
            "keep_alive": keep_alive,
            "options": {
                "num_ctx": context,
                "num_predict": 4,
                "temperature": 0,
            },
        },
        timeout=None,
    )

    if response.status_code >= 400:
        body = response.text[:4000]
        log_control(
            f"LLM warmup failed model={model} context={context} "
            f"http={response.status_code} body={body}"
        )
        raise RuntimeError(
            f"Ollama warmup failed with HTTP {response.status_code}: {body}"
        )

    return response.json()


async def actual_mode() -> str:
    tts_running = port_open(8880)
    image_running = port_open(IMAGE_PORT)
    video_running = port_open(VIDEO_PORT)
    loaded = await ollama_models()

    active_count = (
        int(bool(tts_running))
        + int(bool(image_running))
        + int(bool(video_running))
        + int(bool(loaded))
    )
    if active_count > 1:
        return "conflict"
    if video_running:
        return "video"
    if image_running:
        return "image"
    if tts_running:
        return "tts"
    if loaded:
        return "llm"
    return "off"


async def switch_off(operation_id: str) -> None:
    write_state(stage="stopping_video")
    await asyncio.to_thread(stop_video_sync)

    write_state(stage="stopping_image")
    await asyncio.to_thread(stop_image_sync)

    write_state(stage="stopping_tts")
    await asyncio.to_thread(stop_tts_sync)

    write_state(stage="unloading_llm")
    await unload_all_ollama_models()

    write_state(
        active_mode="off",
        transitioning=False,
        target_mode=None,
        stage="idle",
        operation_id=operation_id,
        last_error=None,
        last_transition_finished_at=now_iso(),
    )


async def switch_llm(
    operation_id: str,
    *,
    model: str,
    context: int,
    keep_alive: str,
    warmup: bool,
) -> None:
    write_state(stage="stopping_video")
    await asyncio.to_thread(stop_video_sync)
    if not await wait_until(lambda: not port_open(VIDEO_PORT), timeout=90):
        raise RuntimeError("Video service did not stop before LLM startup.")

    write_state(stage="stopping_image")
    await asyncio.to_thread(stop_image_sync)
    if not await wait_until(lambda: not port_open(IMAGE_PORT), timeout=60):
        raise RuntimeError("Image service did not stop before LLM startup.")

    write_state(stage="stopping_tts")
    await asyncio.to_thread(stop_tts_sync)

    if not await wait_until(lambda: not port_open(8880), timeout=45):
        raise RuntimeError("TTS port 8880 did not close.")

    write_state(stage="unloading_existing_llm")
    await unload_all_ollama_models()

    if warmup:
        write_state(stage="loading_llm")
        await warm_llm(model, context, keep_alive)

    write_state(
        active_mode="llm",
        transitioning=False,
        target_mode=None,
        stage="idle",
        operation_id=operation_id,
        last_error=None,
        llm_model=model,
        llm_context=context,
        llm_keep_alive=keep_alive,
        last_transition_finished_at=now_iso(),
    )


async def switch_tts(operation_id: str) -> None:
    write_state(stage="stopping_video")
    await asyncio.to_thread(stop_video_sync)
    if not await wait_until(lambda: not port_open(VIDEO_PORT), timeout=90):
        raise RuntimeError("Video service did not stop before TTS startup.")

    write_state(stage="stopping_image")
    await asyncio.to_thread(stop_image_sync)
    if not await wait_until(lambda: not port_open(IMAGE_PORT), timeout=60):
        raise RuntimeError("Image service did not stop before TTS startup.")

    write_state(stage="unloading_llm")
    await unload_all_ollama_models()

    if process_matches("llama-server"):
        raise RuntimeError("llama-server did not exit before TTS startup.")

    write_state(stage="starting_tts")
    await asyncio.to_thread(start_tts_sync)

    if not await wait_until(lambda: port_open(8880), timeout=240):
        raise RuntimeError(
            f"TTS did not open port 8880. Review {TTS_LOG}"
        )

    write_state(
        active_mode="tts",
        transitioning=False,
        target_mode=None,
        stage="idle",
        operation_id=operation_id,
        last_error=None,
        last_transition_finished_at=now_iso(),
    )



async def switch_image(operation_id: str) -> None:
    write_state(stage="stopping_video")
    await asyncio.to_thread(stop_video_sync)
    if not await wait_until(lambda: not port_open(VIDEO_PORT), timeout=90):
        raise RuntimeError("Video service did not stop before image startup.")

    # Preserve the already-proven LLM/TTS behavior by using the same orderly
    # shutdown sequence before starting the isolated image service.
    write_state(stage="stopping_tts")
    await asyncio.to_thread(stop_tts_sync)
    if not await wait_until(lambda: not port_open(8880), timeout=60):
        raise RuntimeError("TTS did not stop before image startup.")

    write_state(stage="unloading_llm")
    await unload_all_ollama_models()
    if process_matches("llama-server"):
        raise RuntimeError("llama-server did not exit before image startup.")

    write_state(stage="starting_image")
    await asyncio.to_thread(start_image_sync)

    if not await wait_until(lambda: port_open(IMAGE_PORT), timeout=180):
        raise RuntimeError(
            f"Image service did not open port {IMAGE_PORT}. Review {IMAGE_LOG}"
        )

    # Service is ready; the SDXL model itself lazy-loads on the first generation.
    write_state(
        active_mode="image",
        transitioning=False,
        target_mode=None,
        stage="idle",
        operation_id=operation_id,
        last_error=None,
        image_model=IMAGE_MODEL,
        last_transition_finished_at=now_iso(),
    )


async def switch_video(operation_id: str) -> None:
    # Video is isolated. The controller only frees the shared GPU and starts
    # the dedicated HunyuanVideo-1.5 service. No automatic chaining to LLM/TTS/SDXL occurs.
    write_state(stage="stopping_image")
    await asyncio.to_thread(stop_image_sync)
    if not await wait_until(lambda: not port_open(IMAGE_PORT), timeout=90):
        raise RuntimeError("Image service did not stop before video startup.")

    write_state(stage="stopping_tts")
    await asyncio.to_thread(stop_tts_sync)
    if not await wait_until(lambda: not port_open(8880), timeout=90):
        raise RuntimeError("TTS did not stop before video startup.")

    write_state(stage="unloading_llm")
    await unload_all_ollama_models()
    if process_matches("llama-server"):
        raise RuntimeError("llama-server did not exit before video startup.")

    write_state(stage="starting_video")
    await asyncio.to_thread(start_video_sync)

    if not await wait_until(lambda: port_open(VIDEO_PORT), timeout=180):
        raise RuntimeError(
            f"Video service did not open port {VIDEO_PORT}. Review {VIDEO_LOG}"
        )

    write_state(
        active_mode="video",
        transitioning=False,
        target_mode=None,
        stage="idle",
        operation_id=operation_id,
        last_error=None,
        video_model=VIDEO_MODEL,
        last_transition_finished_at=now_iso(),
    )


async def run_transition(
    operation_id: str,
    target: str,
    *,
    model: str,
    context: int,
    keep_alive: str,
    warmup: bool,
) -> None:
    global transition_task

    async with transition_lock:
        try:
            log_control(
                f"operation={operation_id} target={target} "
                f"model={model} context={context} started"
            )

            if target == "off":
                await switch_off(operation_id)
            elif target == "tts":
                await switch_tts(operation_id)
            elif target == "video":
                await switch_video(operation_id)
            else:
                raise RuntimeError(f"Unsupported mode: {target}")

            log_control(f"operation={operation_id} target={target} completed")
        except Exception as exc:
            log_control(
                f"operation={operation_id} target={target} FAILED "
                f"{type(exc).__name__}: {exc}"
            )

            # Determine real state instead of blindly claiming "off".
            real_mode = await actual_mode()
            write_state(
                active_mode=real_mode if real_mode != "conflict" else "error",
                transitioning=False,
                target_mode=None,
                stage="failed",
                operation_id=operation_id,
                last_error=f"{type(exc).__name__}: {exc}",
                last_transition_finished_at=now_iso(),
            )
        finally:
            transition_task = None


async def schedule_transition(
    target: str,
    *,
    model: str = DEFAULT_MODEL,
    context: int = DEFAULT_CONTEXT,
    keep_alive: str = DEFAULT_KEEP_ALIVE,
    warmup: bool = True,
) -> dict[str, Any]:
    global transition_task

    # Prevent duplicate clicks/requests from launching concurrent model loads.
    if transition_task is not None and not transition_task.done():
        state = read_state()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": "A service transition is already running",
                "operation_id": state.get("operation_id"),
                "target_mode": state.get("target_mode"),
                "stage": state.get("stage"),
            },
        )

    real_mode = await actual_mode()

    if target == "llm" and real_mode == "llm":
        return {
            "accepted": False,
            "already_running": True,
            "target_mode": "llm",
            "state": "ready",
        }

    if target == "tts" and real_mode == "tts":
        return {
            "accepted": False,
            "already_running": True,
            "target_mode": "tts",
            "state": "ready",
        }

    if target == "image" and real_mode == "image":
        return {
            "accepted": False,
            "already_running": True,
            "target_mode": "image",
            "state": "ready",
        }

    if target == "video" and real_mode == "video":
        return {
            "accepted": False,
            "already_running": True,
            "target_mode": "video",
            "state": "ready",
        }

    if target == "off" and real_mode == "off":
        write_state(
            active_mode="off",
            transitioning=False,
            target_mode=None,
            stage="idle",
            last_error=None,
        )
        return {
            "accepted": False,
            "already_running": True,
            "target_mode": "off",
            "state": "ready",
        }

    operation_id = uuid.uuid4().hex
    write_state(
        transitioning=True,
        target_mode=target,
        stage="queued",
        operation_id=operation_id,
        last_error=None,
        last_transition_started_at=now_iso(),
    )

    transition_task = asyncio.create_task(
        run_transition(
            operation_id,
            target,
            model=model,
            context=context,
            keep_alive=keep_alive,
            warmup=warmup,
        )
    )

    return {
        "accepted": True,
        "operation_id": operation_id,
        "target_mode": target,
        "state": "starting",
    }


def gpu_status() -> dict[str, Any]:
    try:
        raw = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total,memory.used,memory.free,"
                "utilization.gpu,temperature.gpu,power.draw",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            timeout=5,
        ).strip().splitlines()[0]

        values = [part.strip() for part in raw.split(",")]
        return {
            "name": values[0],
            "memory_total_mb": int(float(values[1])),
            "memory_used_mb": int(float(values[2])),
            "memory_free_mb": int(float(values[3])),
            "utilization_percent": int(float(values[4])),
            "temperature_c": int(float(values[5])),
            "power_draw_w": float(values[6]),
        }
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}


async def full_status() -> dict[str, Any]:
    state = read_state()
    tts_pid = read_pid(TTS_PID_FILE)
    memory = psutil.virtual_memory()

    real_mode = await actual_mode()
    if not state.get("transitioning") and state.get("stage") != "failed":
        state["active_mode"] = real_mode

    return {
        **state,
        "actual_mode": real_mode,
        "services": {
            "gateway": {
                "state": "running",
                "port": 8000,
            },
            "tts": {
                "state": "running" if port_open(8880) else "stopped",
                "port": 8880,
                "pid": tts_pid if process_alive(tts_pid) else None,
            },
            "video": {
                "state": "running" if port_open(VIDEO_PORT) else "stopped",
                "port": VIDEO_PORT,
                "pid": read_pid(VIDEO_PID_FILE) if process_alive(read_pid(VIDEO_PID_FILE)) else None,
                "model": VIDEO_MODEL,
            },
        },
        "gpu": gpu_status(),
        "cpu": {
            "utilization_percent": psutil.cpu_percent(interval=0.1),
        },
        "ram": {
            "used_mb": int(memory.used / 1024 / 1024),
            "total_mb": int(memory.total / 1024 / 1024),
        },
        "logs": {
            "gateway": str(LOG_DIR / "gateway.log"),
            "tts": str(TTS_LOG),
            "video": str(VIDEO_LOG),
            "control": str(CONTROL_LOG),
            "startup": str(LOG_DIR / "startup.log"),
            "preflight": str(LOG_DIR / "preflight.log"),
        },
    }


def filtered_headers(headers: httpx.Headers) -> dict[str, str]:
    return {
        key: value
        for key, value in headers.items()
        if key.lower() not in HOP_BY_HOP
    }


def normalize_ollama_payload(payload: dict[str, Any]) -> dict[str, Any]:
    # Default to hidden reasoning for all Ollama requests unless the caller
    # explicitly supplies a 'think' field.
    payload.setdefault("think", False)
    return payload


def strip_reasoning_fields(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: strip_reasoning_fields(item)
            for key, item in value.items()
            if key not in {"thinking", "reasoning", "reasoning_content"}
        }
    if isinstance(value, list):
        return [strip_reasoning_fields(item) for item in value]
    return value


async def generic_proxy(
    request: Request,
    base_url: str,
    upstream_path: str,
):
    target = f"{base_url}/{upstream_path.lstrip('/')}"
    body = await request.body()

    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in HOP_BY_HOP
    }

    client = httpx.AsyncClient(timeout=None)
    upstream = client.build_request(
        request.method,
        target,
        params=request.query_params,
        headers=headers,
        content=body,
    )
    response = await client.send(upstream, stream=True)

    async def iterator() -> AsyncIterator[bytes]:
        try:
            async for chunk in response.aiter_raw():
                yield chunk
        finally:
            await response.aclose()
            await client.aclose()

    return StreamingResponse(
        iterator(),
        status_code=response.status_code,
        headers=filtered_headers(response.headers),
        media_type=response.headers.get("content-type"),
    )


@APP.get("/")
async def root():
    return RedirectResponse("/gateway/docs")


@APP.api_route("/mcp", methods=["GET", "POST", "DELETE", "OPTIONS"])
async def mcp_proxy(request: Request):
    # RunPod's proxy can inconsistently reject POST requests sent directly to
    # a secondary exposed port. Carry MCP over the primary FastAPI HTTP port
    # and forward it to the local Node transport instead.
    return await generic_proxy(request, MCP_BASE, "/mcp")


@APP.api_route("/connector", methods=["GET", "POST", "DELETE", "OPTIONS"])
async def connector_proxy(request: Request):
    # Neutral public alias for proxies that reserve or filter the literal
    # "/mcp" path. The local Node service still receives standard MCP traffic.

@APP.api_route("/files/generated/remotion/{path:path}", methods=["GET"])
async def remotion_files_proxy(request: Request, path: str):
    return await generic_proxy(request, MCP_BASE, f"/files/generated/remotion/{path}")

    return await generic_proxy(request, MCP_BASE, "/mcp")


@APP.get("/health")
async def health():
    state = read_state()
    return {
        "status": "ok",
        "gateway": "running",
        "active_mode": state.get("active_mode", "unknown"),
        "transitioning": state.get("transitioning", False),
    }


@APP.get("/resources")
async def resources():
    status_data = await full_status()
    return {
        "gpu": status_data["gpu"],
        "cpu": status_data["cpu"],
        "ram": status_data["ram"],
    }


@APP.get("/control/status")
async def control_status():
    return await full_status()


@APP.post("/control/llm/start", status_code=status.HTTP_202_ACCEPTED)
async def control_llm_start(
    payload: LLMStartRequest = Body(default=LLMStartRequest()),
):
    if not LLM_ENABLED:
        raise HTTPException(status_code=404, detail="LLM service is disabled on this deployment.")
    return await schedule_transition(
        "llm",
        model=payload.model or DEFAULT_MODEL,
        context=payload.context or DEFAULT_CONTEXT,
        keep_alive=payload.keep_alive or DEFAULT_KEEP_ALIVE,
        warmup=payload.warmup,
    )


@APP.post("/control/llm/stop", status_code=status.HTTP_202_ACCEPTED)
async def control_llm_stop():
    return await schedule_transition("off")


@APP.post("/control/tts/start", status_code=status.HTTP_202_ACCEPTED)
async def control_tts_start():
    return await schedule_transition("tts")


@APP.post("/control/tts/stop", status_code=status.HTTP_202_ACCEPTED)
async def control_tts_stop():
    # Because modes are mutually exclusive, stopping TTS means "off".
    return await schedule_transition("off")


@APP.post("/control/image/start", status_code=status.HTTP_202_ACCEPTED)
async def control_image_start():
    return await schedule_transition("image")


@APP.post("/control/image/stop", status_code=status.HTTP_202_ACCEPTED)
async def control_image_stop():
    return await schedule_transition("off")


@APP.post("/control/video/start", status_code=status.HTTP_202_ACCEPTED)
async def control_video_start():
    return await schedule_transition("video")


@APP.post("/control/video/stop", status_code=status.HTTP_202_ACCEPTED)
async def control_video_stop():
    return await schedule_transition("off")


@APP.post("/control/off", status_code=status.HTTP_202_ACCEPTED)
async def control_off():
    return await schedule_transition("off")


@APP.post("/control/restart", status_code=status.HTTP_202_ACCEPTED)
async def control_restart(
    payload: RestartRequest = Body(default=RestartRequest()),
):
    state = read_state()
    current = await actual_mode()

    if current == "llm":
        return await schedule_transition(
            "llm",
            model=state.get("llm_model", DEFAULT_MODEL),
            context=int(state.get("llm_context", DEFAULT_CONTEXT)),
            keep_alive=state.get("llm_keep_alive", DEFAULT_KEEP_ALIVE),
            warmup=payload.warmup,
        )
    if current == "tts":
        return await schedule_transition("tts")
    if current == "image":
        return await schedule_transition("image")
    if current == "video":
        return await schedule_transition("video")

    return await schedule_transition("off")


@APP.api_route(
    "/ollama/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)
async def ollama_proxy(path: str, request: Request):
    real_mode = await actual_mode()
    state = read_state()

    if real_mode != "llm" or state.get("transitioning"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="LLM mode is not ready. Call POST /control/llm/start and poll /control/status.",
        )

    content_type = request.headers.get("content-type", "")
    if (
        request.method not in {"POST", "PUT", "PATCH"}
        or "application/json" not in content_type
    ):
        return await generic_proxy(request, OLLAMA_BASE, path)

    try:
        payload = await request.json()
    except Exception:
        return await generic_proxy(request, OLLAMA_BASE, path)

    if not isinstance(payload, dict):
        return await generic_proxy(request, OLLAMA_BASE, path)

    payload = normalize_ollama_payload(payload)
    target = f"{OLLAMA_BASE}/{path.lstrip('/')}"

    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in HOP_BY_HOP
    }

    streaming = bool(payload.get("stream", True))

    if streaming:
        client = httpx.AsyncClient(timeout=None)
        upstream = client.build_request(
            request.method,
            target,
            params=request.query_params,
            headers=headers,
            json=payload,
        )
        response = await client.send(upstream, stream=True)

        async def iterator() -> AsyncIterator[bytes]:
            try:
                async for chunk in response.aiter_raw():
                    yield chunk
            finally:
                await response.aclose()
                await client.aclose()

        return StreamingResponse(
            iterator(),
            status_code=response.status_code,
            headers=filtered_headers(response.headers),
            media_type=response.headers.get("content-type"),
        )

    async with httpx.AsyncClient(timeout=None) as client:
        response = await client.request(
            request.method,
            target,
            params=request.query_params,
            headers=headers,
            json=payload,
        )

    content_type = response.headers.get("content-type", "")
    if "application/json" not in content_type:
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=filtered_headers(response.headers),
            media_type=content_type or None,
        )

    try:
        cleaned = strip_reasoning_fields(response.json())
        return JSONResponse(
            content=cleaned,
            status_code=response.status_code,
            headers=filtered_headers(response.headers),
        )
    except Exception:
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=filtered_headers(response.headers),
            media_type=content_type,
        )



@APP.post("/v1/videos/generations")
async def video_generation(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    width: int = Form(VIDEO_DEFAULT_WIDTH),
    height: int = Form(VIDEO_DEFAULT_HEIGHT),
    num_frames: int = Form(VIDEO_DEFAULT_FRAMES),
    fps: int = Form(VIDEO_DEFAULT_FPS),
    steps: int = Form(VIDEO_DEFAULT_STEPS),
    guidance_scale: float = Form(VIDEO_DEFAULT_GUIDANCE),
    seed: int | None = Form(None),
):
    real_mode = await actual_mode()
    state = read_state()

    if real_mode != "video" or state.get("transitioning"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Video mode is not ready. Call POST /control/video/start and poll /control/status.",
        )

    raw = await image.read()
    if not raw:
        raise HTTPException(status_code=422, detail="Uploaded image is empty.")

    files = {
        "image": (
            image.filename or "input.jpg",
            raw,
            image.content_type or "application/octet-stream",
        )
    }
    data = {
        "prompt": prompt,
        "width": str(width),
        "height": str(height),
        "num_frames": str(num_frames),
        "fps": str(fps),
        "steps": str(steps),
        "guidance_scale": str(guidance_scale),
    }
    if seed is not None:
        data["seed"] = str(seed)

    # The backend queues the GPU job and returns 202 immediately, avoiding
    # RunPod/Cloudflare long-request 524 timeouts.
    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(
            f"{VIDEO_BASE}/generate",
            files=files,
            data=data,
        )

    try:
        payload = response.json()
    except Exception:
        return Response(
            content=response.content,
            status_code=response.status_code,
            media_type=response.headers.get("content-type"),
        )

    if response.status_code == 202 and payload.get("job_id"):
        payload["status_url"] = f"/v1/videos/jobs/{payload['job_id']}"

    return JSONResponse(content=payload, status_code=response.status_code)


@APP.get("/v1/videos/jobs/{job_id}")
async def video_job_status(job_id: str):
    real_mode = await actual_mode()
    if real_mode != "video":
        # Completed job metadata is still queryable while video mode is active.
        # If mode was stopped/restarted, backend job state is no longer guaranteed.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Video mode is not active.",
        )

    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get(f"{VIDEO_BASE}/jobs/{job_id}")

    try:
        payload = response.json()
    except Exception:
        return Response(
            content=response.content,
            status_code=response.status_code,
            media_type=response.headers.get("content-type"),
        )

    return JSONResponse(content=payload, status_code=response.status_code)


@APP.get("/files/generated/videos/{filename}")
async def generated_video(filename: str):
    safe = Path(filename).name
    path = VIDEO_OUTPUT_DIR / safe
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Generated video not found.")
    return Response(
        content=path.read_bytes(),
        media_type="video/mp4",
        headers={"Content-Disposition": f'inline; filename="{safe}"'},
    )


@APP.post("/v1/images/generations")
async def image_generation(request: Request):
    real_mode = await actual_mode()
    state = read_state()

    if real_mode != "image" or state.get("transitioning"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Image mode is not ready. Call POST /control/image/start and poll /control/status.",
        )

    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc

    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise HTTPException(status_code=422, detail="'prompt' is required.")

    internal = {
        "prompt": prompt,
        "width": int(payload.get("width", IMAGE_DEFAULT_WIDTH)),
        "height": int(payload.get("height", IMAGE_DEFAULT_HEIGHT)),
        "steps": int(payload.get("steps", IMAGE_DEFAULT_STEPS)),
        "guidance_scale": float(payload.get("guidance_scale", 7.0)),
    }
    if payload.get("seed") is not None:
        internal["seed"] = int(payload["seed"])

    async with httpx.AsyncClient(timeout=None) as client:
        response = await client.post(f"{IMAGE_BASE}/generate", json=internal)

    if response.status_code >= 400:
        raise HTTPException(
            status_code=response.status_code,
            detail=response.text[:4000],
        )

    result = response.json()
    filename = result["filename"]

    # Return one image only, using a relative URL that remains valid regardless
    # of the RunPod public proxy hostname/port.
    return {
        "created": result["created"],
        "model": result["model"],
        "data": [
            {
                "url": f"/files/generated/{filename}",
                "width": result["width"],
                "height": result["height"],
                "seed": result["seed"],
                "generation_seconds": result["generation_seconds"],
            }
        ],
    }


@APP.get("/files/generated/{filename}")
async def generated_image(filename: str):
    safe = Path(filename).name
    path = IMAGE_OUTPUT_DIR / safe
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Generated image not found.")
    return Response(
        content=path.read_bytes(),
        media_type="image/png",
        headers={"Content-Disposition": f'inline; filename="{safe}"'},
    )


@APP.api_route(
    "/v1/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)
async def tts_openai_proxy(path: str, request: Request):
    real_mode = await actual_mode()
    state = read_state()

    if real_mode != "tts" or state.get("transitioning"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="TTS mode is not ready. Call POST /control/tts/start and poll /control/status.",
        )

    return await generic_proxy(request, TTS_BASE, f"v1/{path}")


@APP.api_route(
    "/tts/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)
async def tts_native_proxy(path: str, request: Request):
    real_mode = await actual_mode()
    state = read_state()

    if real_mode != "tts" or state.get("transitioning"):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="TTS mode is not ready. Call POST /control/tts/start and poll /control/status.",
        )

    return await generic_proxy(request, TTS_BASE, path)


# The production surface intentionally contains only TTS, video, status,
# health, resources, and MCP. Remove legacy Ollama/LLM and SDXL routes from
# both request routing and generated OpenAPI documentation.
_REMOVED_EXACT_PATHS = {
    "/control/llm/start",
    "/control/llm/stop",
    "/control/image/start",
    "/control/image/stop",
    "/v1/images/generations",
    "/files/generated/{filename}",
}
APP.router.routes = [
    route
    for route in APP.router.routes
    if getattr(route, "path", "") not in _REMOVED_EXACT_PATHS
    and not getattr(route, "path", "").startswith("/ollama/")
]
PY

"$GATEWAY_VENV/bin/python" - <<PY
import py_compile
py_compile.compile(r"$GATEWAY_DIR/app.py", cfile="/tmp/gateway-app.pyc", doraise=True)
print("gateway app.py compile: OK")
PY

# ------------------------------------------------------------------------------
# Local CLI
# ------------------------------------------------------------------------------

cat >"$MODE_SCRIPT" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"


def request(method: str, path: str, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        BASE + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        print(body or str(exc), file=sys.stderr)
        raise SystemExit(1)


def pretty(value):
    print(json.dumps(value, indent=2))


if len(sys.argv) < 2:
    print("Usage: ai-mode status|tts|video|off|restart")
    raise SystemExit(2)

command = sys.argv[1].lower()

if command == "status":
    pretty(request("GET", "/control/status"))
elif command == "tts":
    pretty(request("POST", "/control/tts/start", {}))
elif command == "video":
    pretty(request("POST", "/control/video/start", {}))
elif command == "off":
    pretty(request("POST", "/control/off", {}))
elif command == "restart":
    pretty(request("POST", "/control/restart", {"warmup": True}))
else:
    print(f"Unknown command: {command}", file=sys.stderr)
    raise SystemExit(2)
PY

chmod +x "$MODE_SCRIPT"
ln -sf "$MODE_SCRIPT" /usr/local/bin/ai-mode

# ------------------------------------------------------------------------------
# Start gateway cleanly
# ------------------------------------------------------------------------------

section "Starting gateway"

# Clean up older versions.
kill_matching "uvicorn service_manager:app"
kill_matching "uvicorn app:APP.*--port 8000"
sleep 2

log "Starting FastAPI gateway on 0.0.0.0:8000..."
nohup env \
  AI_STACK_CONFIG="$CONFIG_FILE" \
  AI_STACK_STATE="$STATE_FILE" \
  "$GATEWAY_VENV/bin/python" -m uvicorn app:APP \
    --app-dir "$GATEWAY_DIR" \
    --host 0.0.0.0 \
    --port 8000 \
    >>"$GATEWAY_LOG" 2>&1 &
echo $! >"$RUN_DIR/gateway.pid"

if ! wait_for_http "http://127.0.0.1:8000/health" "Gateway" 90; then
  tail -n 120 "$GATEWAY_LOG" >&2 || true
  fatal "Gateway failed to start."
fi

# ------------------------------------------------------------------------------
# Install/update and start the MCP adapter
# ------------------------------------------------------------------------------

if [[ "$MCP_ENABLED" == "true" ]]; then
  section "RunPod MCP server"

  if [[ -z "$MCP_REPO_URL" && ! -f "$MCP_DIR/package.json" ]]; then
    warn "No local MCP project was found and MCP_REPO_URL is empty; skipping MCP deployment."
  else
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 20 ]]; then
      log "Installing Node.js 22 for the MCP server..."
      NODE_SETUP="$RUN_DIR/nodesource-setup.sh"
      curl -fsSL https://deb.nodesource.com/setup_22.x -o "$NODE_SETUP"
      bash "$NODE_SETUP" >>"$INSTALL_LOG" 2>&1
      apt-get install -y --no-install-recommends nodejs >>"$INSTALL_LOG" 2>&1
    fi

    if [[ -d "$MCP_DIR/.git" && -n "$MCP_REPO_URL" ]]; then
      log "Updating MCP repository branch '$MCP_BRANCH'..."
      git -C "$MCP_DIR" fetch --depth 1 origin "$MCP_BRANCH" >>"$INSTALL_LOG" 2>&1
      git -C "$MCP_DIR" checkout "$MCP_BRANCH" >>"$INSTALL_LOG" 2>&1
      git -C "$MCP_DIR" merge --ff-only "origin/$MCP_BRANCH" >>"$INSTALL_LOG" 2>&1
    elif [[ -f "$MCP_DIR/package.json" ]]; then
      log "Using the MCP project containing this startup script: $MCP_DIR"
    elif [[ -e "$MCP_DIR" ]]; then
      fatal "MCP_DIR exists but does not contain the MCP project: $MCP_DIR"
    else
      log "Cloning MCP repository branch '$MCP_BRANCH'..."
      git clone --depth 1 --branch "$MCP_BRANCH" "$MCP_REPO_URL" "$MCP_DIR" >>"$INSTALL_LOG" 2>&1
    fi

    log "Installing and building the MCP server..."
    npm --prefix "$MCP_DIR" ci >>"$INSTALL_LOG" 2>&1
    npm --prefix "$MCP_DIR" run build >>"$INSTALL_LOG" 2>&1

    if [[ -z "$MCP_PUBLIC_GATEWAY_URL" && -n "${RUNPOD_POD_ID:-}" ]]; then
      MCP_PUBLIC_GATEWAY_URL="https://${RUNPOD_POD_ID}-8000.proxy.runpod.net"
    fi
    if [[ -z "$MCP_PUBLIC_GATEWAY_URL" ]]; then
      fatal "Set MCP_PUBLIC_GATEWAY_URL because RUNPOD_POD_ID is unavailable."
    fi
    if [[ -z "$MCP_PUBLIC_BASE_URL" && -n "${RUNPOD_POD_ID:-}" ]]; then
      MCP_PUBLIC_BASE_URL="https://${RUNPOD_POD_ID}-${MCP_PORT}.proxy.runpod.net"
    fi
    if [[ -z "$MCP_PUBLIC_BASE_URL" ]]; then
      fatal "Set MCP_PUBLIC_BASE_URL because RUNPOD_POD_ID is unavailable."
    fi

    kill_matching "$MCP_DIR/dist/server.js"
    sleep 1

    log "Starting MCP server on 0.0.0.0:$MCP_PORT..."
    nohup env \
      NODE_ENV=production \
      PORT="$MCP_PORT" \
      RUNPOD_BASE_URL="http://127.0.0.1:8000" \
      RUNPOD_PUBLIC_BASE_URL="$MCP_PUBLIC_GATEWAY_URL" \
      MCP_PUBLIC_BASE_URL="$MCP_PUBLIC_BASE_URL" \
      AUDIO_OUTPUT_DIR="$AUDIO_OUTPUT_DIR" \
      VIDEO_JOB_DIR="$VIDEO_JOB_DIR" \
      node "$MCP_DIR/dist/server.js" \
      >>"$MCP_LOG" 2>&1 &
    echo $! >"$RUN_DIR/mcp-server.pid"

    if ! wait_for_http "http://127.0.0.1:$MCP_PORT/" "MCP server" 60; then
      tail -n 120 "$MCP_LOG" >&2 || true
      fatal "MCP server failed to start."
    fi
  fi
elif [[ "$MCP_ENABLED" != "false" ]]; then
  fatal "MCP_ENABLED must be true or false."
fi

# Start clean: no TTS and no loaded LLM model.
log "Ensuring initial clean GPU state..."
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -d '{}' \
  http://127.0.0.1:8000/control/off >/dev/null 2>&1 || true

OFF_DEADLINE=$(( $(date +%s) + 300 ))
while true; do
  STATUS_JSON="$(curl -fsS http://127.0.0.1:8000/control/status)"
  STAGE="$(printf '%s' "$STATUS_JSON" | jq -r '.stage // "unknown"')"
  MODE="$(printf '%s' "$STATUS_JSON" | jq -r '.actual_mode // .active_mode // "unknown"')"
  TRANSITIONING="$(printf '%s' "$STATUS_JSON" | jq -r '.transitioning // false')"
  ERROR_TEXT="$(printf '%s' "$STATUS_JSON" | jq -r '.last_error // empty')"

  if [[ "$STAGE" == "failed" ]]; then
    printf '%s\n' "$STATUS_JSON" >>"$PREFLIGHT_LOG"
    fatal "Could not establish the initial clean GPU state: ${ERROR_TEXT:-unknown error}"
  fi

  [[ "$MODE" == "off" && "$TRANSITIONING" == "false" ]] && break

  if (( $(date +%s) >= OFF_DEADLINE )); then
    printf '%s\n' "$STATUS_JSON" >>"$PREFLIGHT_LOG"
    fatal "GPU did not reach the initial clean off state within 300 seconds."
  fi
  sleep 2
done

if [[ "$TTS_PREFLIGHT" == "true" ]]; then
  section "TTS functional preflight"
  log "Starting TTS for real synthesis verification..."

  curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    http://127.0.0.1:8000/control/tts/start \
    >>"$PREFLIGHT_LOG"

  TTS_DEADLINE=$(( $(date +%s) + 300 ))
  while true; do
    STATUS_JSON="$(curl -fsS http://127.0.0.1:8000/control/status)"
    STAGE="$(printf '%s' "$STATUS_JSON" | jq -r '.stage // "unknown"')"
    MODE="$(printf '%s' "$STATUS_JSON" | jq -r '.actual_mode // .active_mode // "unknown"')"
    ERROR_TEXT="$(printf '%s' "$STATUS_JSON" | jq -r '.last_error // empty')"

    if [[ "$STAGE" == "failed" ]]; then
      printf '%s\n' "$STATUS_JSON" >>"$PREFLIGHT_LOG"
      tail -n 200 "$TTS_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "TTS failed to start during preflight: ${ERROR_TEXT:-unknown error}"
    fi

    [[ "$MODE" == "tts" && "$STAGE" == "idle" ]] && break

    if (( $(date +%s) >= TTS_DEADLINE )); then
      printf '%s\n' "$STATUS_JSON" >>"$PREFLIGHT_LOG"
      tail -n 200 "$TTS_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "TTS did not become ready within 300 seconds."
    fi
    sleep 2
  done

  log "Generating a short WAV. The first run may download/load the TTS model..."
  TTS_TEST_WAV="$RUN_DIR/tts-preflight.wav"
  TTS_HTTP_CODE="$(
    curl -sS \
      --connect-timeout 15 \
      --max-time 1800 \
      -o "$TTS_TEST_WAV" \
      -w '%{http_code}' \
      http://127.0.0.1:8000/v1/audio/speech \
      -H 'Content-Type: application/json' \
      -d '{"model":"tts-1","voice":"Ryan","input":"RunPod TTS preflight successful.","response_format":"wav","speed":1.0}' \
      || true
  )"

  TTS_SIZE="$(stat -c '%s' "$TTS_TEST_WAV" 2>/dev/null || echo 0)"
  {
    echo "=== $(timestamp) TTS synthesis preflight ==="
    echo "HTTP status: $TTS_HTTP_CODE"
    echo "Output bytes: $TTS_SIZE"
    file "$TTS_TEST_WAV" 2>/dev/null || true
  } >>"$PREFLIGHT_LOG"

  if [[ "$TTS_HTTP_CODE" != "200" || "$TTS_SIZE" -lt 1000 ]]; then
    tail -n 250 "$TTS_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
    tail -n 120 "$PREFLIGHT_LOG" >&2 || true
    fatal "TTS synthesis preflight failed. See $PREFLIGHT_LOG and $TTS_LOG."
  fi

  log "TTS synthesis preflight passed (${TTS_SIZE} bytes)."
  log "Returning GPU to clean off state..."

  curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    http://127.0.0.1:8000/control/off >/dev/null

  OFF_DEADLINE=$(( $(date +%s) + 180 ))
  while true; do
    OFF_JSON="$(curl -fsS http://127.0.0.1:8000/control/status)"
    OFF_STAGE="$(printf '%s' "$OFF_JSON" | jq -r '.stage // "unknown"')"
    OFF_MODE="$(printf '%s' "$OFF_JSON" | jq -r '.actual_mode // .active_mode // "unknown"')"

    [[ "$OFF_MODE" == "off" && "$OFF_STAGE" == "idle" ]] && break

    if [[ "$OFF_STAGE" == "failed" || $(date +%s) -ge $OFF_DEADLINE ]]; then
      printf '%s\n' "$OFF_JSON" >>"$PREFLIGHT_LOG"
      fatal "Failed to return to off mode after TTS preflight."
    fi
    sleep 2
  done

  log "TTS preflight cleanup completed."
else
  warn "TTS_PREFLIGHT=false: skipping real TTS synthesis verification."
fi


# ------------------------------------------------------------------------------
# SDXL image functional preflight
# ------------------------------------------------------------------------------
if [[ "$IMAGE_PREFLIGHT" == "true" ]]; then
  section "SDXL image functional preflight"
  log "Starting isolated image mode for one real generation test..."

  curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    http://127.0.0.1:8000/control/image/start \
    >>"$PREFLIGHT_LOG"

  IMAGE_DEADLINE=$(( $(date +%s) + 300 ))
  while true; do
    IMAGE_STATUS="$(curl -fsS http://127.0.0.1:8000/control/status)"
    IMAGE_STAGE="$(printf '%s' "$IMAGE_STATUS" | jq -r '.stage // "unknown"')"
    IMAGE_MODE="$(printf '%s' "$IMAGE_STATUS" | jq -r '.actual_mode // .active_mode // "unknown"')"
    IMAGE_ERROR="$(printf '%s' "$IMAGE_STATUS" | jq -r '.last_error // empty')"

    if [[ "$IMAGE_STAGE" == "failed" ]]; then
      printf '%s\n' "$IMAGE_STATUS" >>"$PREFLIGHT_LOG"
      tail -n 250 "$IMAGE_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "Image service failed during preflight: ${IMAGE_ERROR:-unknown error}"
    fi

    [[ "$IMAGE_MODE" == "image" && "$IMAGE_STAGE" == "idle" ]] && break

    if (( $(date +%s) >= IMAGE_DEADLINE )); then
      printf '%s\n' "$IMAGE_STATUS" >>"$PREFLIGHT_LOG"
      tail -n 250 "$IMAGE_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "Image service did not become ready within 300 seconds."
    fi
    sleep 2
  done

  log "Generating one 512x512 SDXL preflight image. First run may download model files..."
  IMAGE_PREFLIGHT_JSON="$RUN_DIR/image-preflight.json"
  IMAGE_HTTP_CODE="$(
    curl -sS \
      --connect-timeout 15 \
      --max-time 3600 \
      -o "$IMAGE_PREFLIGHT_JSON" \
      -w '%{http_code}' \
      http://127.0.0.1:8000/v1/images/generations \
      -H 'Content-Type: application/json' \
      -d '{"prompt":"A simple blue ceramic cup on a white table, studio photograph","width":512,"height":512,"steps":10,"guidance_scale":7.0,"seed":42}' \
      || true
  )"

  {
    echo "=== $(timestamp) SDXL image synthesis preflight ==="
    echo "HTTP status: $IMAGE_HTTP_CODE"
    cat "$IMAGE_PREFLIGHT_JSON" 2>/dev/null || true
    echo
  } >>"$PREFLIGHT_LOG"

  if [[ "$IMAGE_HTTP_CODE" != "200" ]]; then
    tail -n 300 "$IMAGE_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
    tail -n 150 "$PREFLIGHT_LOG" >&2 || true
    fatal "SDXL image preflight failed (HTTP $IMAGE_HTTP_CODE). See $PREFLIGHT_LOG and $IMAGE_LOG."
  fi

  IMAGE_REL_URL="$(jq -r '.data[0].url // empty' "$IMAGE_PREFLIGHT_JSON")"
  IMAGE_FILE="$(basename "$IMAGE_REL_URL")"
  if [[ -z "$IMAGE_FILE" || ! -s "$GENERATED_DIR/$IMAGE_FILE" ]]; then
    tail -n 300 "$IMAGE_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
    fatal "SDXL preflight returned no valid image file."
  fi

  IMAGE_SIZE="$(stat -c '%s' "$GENERATED_DIR/$IMAGE_FILE" 2>/dev/null || echo 0)"
  if (( IMAGE_SIZE < 5000 )); then
    fatal "SDXL preflight image is unexpectedly small (${IMAGE_SIZE} bytes)."
  fi

  log "SDXL image preflight passed (${IMAGE_SIZE} bytes)."

  log "Returning GPU to clean off state after image preflight..."
  curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    http://127.0.0.1:8000/control/off >/dev/null

  IMAGE_OFF_DEADLINE=$(( $(date +%s) + 240 ))
  while true; do
    OFF_STATUS="$(curl -fsS http://127.0.0.1:8000/control/status)"
    OFF_STAGE="$(printf '%s' "$OFF_STATUS" | jq -r '.stage // "unknown"')"
    OFF_MODE="$(printf '%s' "$OFF_STATUS" | jq -r '.actual_mode // .active_mode // "unknown"')"

    [[ "$OFF_MODE" == "off" && "$OFF_STAGE" == "idle" ]] && break

    if [[ "$OFF_STAGE" == "failed" || $(date +%s) -ge $IMAGE_OFF_DEADLINE ]]; then
      printf '%s\n' "$OFF_STATUS" >>"$PREFLIGHT_LOG"
      fatal "Failed to return to off mode after SDXL preflight."
    fi
    sleep 2
  done

  log "SDXL image preflight cleanup completed."
else
  warn "IMAGE_PREFLIGHT=false: skipping real SDXL image generation verification."
fi

# ------------------------------------------------------------------------------
# HunyuanVideo-1.5 Step-Distilled asynchronous image-to-video functional preflight
# ------------------------------------------------------------------------------
# HunyuanVideo-1.5 public step-distilled asynchronous functional preflight
# ------------------------------------------------------------------------------
if [[ "$VIDEO_PREFLIGHT" == "true" ]]; then
  section "HunyuanVideo-1.5 step-distilled async video preflight"

  VIDEO_TEST_IMAGE="$RUN_DIR/video-preflight-input.png"
  "$VIDEO_VENV/bin/python" - <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw
p=Path("/workspace/ai-stack/run/video-preflight-input.png")
im=Image.new("RGB",(480,832),(225,235,245))
d=ImageDraw.Draw(im)
d.rectangle((50,560,430,740),fill=(90,145,75))
d.ellipse((135,180,345,500),fill=(235,145,70),outline=(60,45,35),width=8)
d.ellipse((190,285,215,310),fill=(20,20,20))
d.ellipse((265,285,290,310),fill=(20,20,20))
d.arc((205,330,285,410),10,170,fill=(60,40,30),width=6)
im.save(p)
PY

  log "Starting isolated HunyuanVideo-1.5 video mode..."
  curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
    http://127.0.0.1:8000/control/video/start >>"$PREFLIGHT_LOG"

  VIDEO_DEADLINE=$(( $(date +%s) + 900 ))
  while true; do
    S="$(curl -fsS http://127.0.0.1:8000/control/status)"
    ST="$(printf '%s' "$S" | jq -r '.stage // "unknown"')"
    MO="$(printf '%s' "$S" | jq -r '.actual_mode // .active_mode // "unknown"')"
    [[ "$MO" == "video" && "$ST" == "idle" ]] && break
    if [[ "$ST" == "failed" || $(date +%s) -ge $VIDEO_DEADLINE ]]; then
      printf '%s\n' "$S" >>"$PREFLIGHT_LOG"
      tail -n 300 "$VIDEO_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "HunyuanVideo-1.5 service failed to become ready."
    fi
    sleep 3
  done

  log "Submitting HunyuanVideo-1.5 4-step low-cost preflight job..."
  SUBMIT_JSON="$RUN_DIR/video-preflight-submit.json"
  SUBMIT_CODE="$(
    curl -sS --connect-timeout 15 --max-time 60 \
      -o "$SUBMIT_JSON" -w '%{http_code}' -X POST \
      http://127.0.0.1:8000/v1/videos/generations \
      -F "image=@$VIDEO_TEST_IMAGE;type=image/png" \
      -F 'prompt=The orange cartoon figure visibly turns its head and raises one arm while its body shifts naturally. Clear subject animation, stable shapes, fixed camera.' \
      -F 'width=480' -F 'height=832' \
      -F 'num_frames=121' -F 'fps=24' \
      -F 'steps=4' -F 'seed=42' || true
  )"

  if [[ "$SUBMIT_CODE" != "202" ]]; then
    cat "$SUBMIT_JSON" >>"$PREFLIGHT_LOG" 2>/dev/null || true
    tail -n 300 "$VIDEO_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
    fatal "HunyuanVideo-1.5 preflight submission failed (HTTP $SUBMIT_CODE)."
  fi

  JOB_ID="$(jq -r '.job_id // empty' "$SUBMIT_JSON")"
  [[ -n "$JOB_ID" ]] || fatal "HunyuanVideo-1.5 preflight returned no job_id."
  log "HunyuanVideo-1.5 preflight queued: $JOB_ID"

  JOB_DEADLINE=$(( $(date +%s) + 1200 ))
  while true; do
    JOB_JSON="$(curl -fsS "http://127.0.0.1:8000/v1/videos/jobs/$JOB_ID")"
    JOB_STATUS="$(printf '%s' "$JOB_JSON" | jq -r '.status // "unknown"')"

    if [[ "$JOB_STATUS" == "completed" ]]; then
      printf '%s\n' "$JOB_JSON" >>"$PREFLIGHT_LOG"
      break
    fi
    if [[ "$JOB_STATUS" == "failed" ]]; then
      printf '%s\n' "$JOB_JSON" >>"$PREFLIGHT_LOG"
      JOB_LOG="$(printf '%s' "$JOB_JSON" | jq -r '.log // empty')"
      [[ -n "$JOB_LOG" ]] && tail -n 300 "$JOB_LOG" >>"$PREFLIGHT_LOG" 2>/dev/null || true
      fatal "HunyuanVideo-1.5 preflight generation job failed."
    fi
    if (( $(date +%s) >= JOB_DEADLINE )); then
      printf '%s\n' "$JOB_JSON" >>"$PREFLIGHT_LOG"
      fatal "HunyuanVideo-1.5 preflight exceeded 20 minutes."
    fi

    log "HunyuanVideo-1.5 preflight job status: $JOB_STATUS"
    sleep 5
  done

  VIDEO_REL_URL="$(printf '%s' "$JOB_JSON" | jq -r '.url // empty')"
  VIDEO_FILE="$(basename "$VIDEO_REL_URL")"
  VIDEO_PATH="$GENERATED_VIDEO_DIR/$VIDEO_FILE"
  [[ -s "$VIDEO_PATH" ]] || fatal "HunyuanVideo-1.5 preflight completed but MP4 is missing."

  "$VIDEO_VENV/bin/python" - "$VIDEO_PATH" <<'PY' >>"$PREFLIGHT_LOG" 2>&1
import subprocess,sys,imageio_ffmpeg
ff=imageio_ffmpeg.get_ffmpeg_exe()
p=subprocess.run(
    [ff,"-v","error","-i",sys.argv[1],"-map","0:v:0","-frames:v","1","-f","null","-"],
    stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True
)
if p.returncode:
    raise SystemExit(p.stderr[-4000:])
print("HunyuanVideo-1.5 MP4 decode validation: OK")
PY

  VIDEO_SIZE="$(stat -c '%s' "$VIDEO_PATH" 2>/dev/null || echo 0)"
  log "HunyuanVideo-1.5 async video preflight passed (${VIDEO_SIZE} bytes)."

  curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
    http://127.0.0.1:8000/control/off >/dev/null

  VIDEO_OFF_DEADLINE=$(( $(date +%s) + 300 ))
  while true; do
    S="$(curl -fsS http://127.0.0.1:8000/control/status)"
    ST="$(printf '%s' "$S" | jq -r '.stage // "unknown"')"
    MO="$(printf '%s' "$S" | jq -r '.actual_mode // .active_mode // "unknown"')"
    [[ "$MO" == "off" && "$ST" == "idle" ]] && break
    [[ "$ST" == "failed" || $(date +%s) -ge $VIDEO_OFF_DEADLINE ]] && fatal "Failed to return to off mode after Hunyuan preflight."
    sleep 2
  done
else
  warn "VIDEO_PREFLIGHT=false: skipping real HunyuanVideo-1.5 verification."
fi

case "$AI_START_MODE" in
  off)
    log "Initial mode requested: off"
    ;;
  tts)
    log "Initial mode requested: tts"
    curl -fsS -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      http://127.0.0.1:8000/control/tts/start >/dev/null
    ;;
  video)
    log "Initial mode requested: video"
    curl -fsS -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      http://127.0.0.1:8000/control/video/start >/dev/null
    ;;
  *)
    fatal "AI_START_MODE must be one of: off, tts, video"
    ;;
esac

section "Installation complete"

log "Script version: $SCRIPT_VERSION"
log "Gateway local URL: http://127.0.0.1:8000"
log "Swagger: /gateway/docs"
log "Health: /health"
log "Status: /control/status"
log "Initial mode: $AI_START_MODE"
log "TTS preflight: $TTS_PREFLIGHT"
log "Video preflight: $VIDEO_PREFLIGHT"
log "MCP deployment: $MCP_ENABLED"

if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
  PUBLIC_BASE="https://${RUNPOD_POD_ID}-8000.proxy.runpod.net"
  log "Public gateway: $PUBLIC_BASE"
  log "Public Swagger: $PUBLIC_BASE/gateway/docs"
  log "Public status: $PUBLIC_BASE/control/status"
  if [[ "$MCP_ENABLED" == "true" && -f "$MCP_DIR/package.json" ]]; then
    log "Public MCP connector path: /connector"
  fi
fi

cat <<EOF

===============================================================================
RunPod AI Stack is ready
===============================================================================

Local status:
  curl http://127.0.0.1:8000/control/status

Start TTS:
  curl -X POST \
    -H "Content-Type: application/json" \
    -d '{}' \
    http://127.0.0.1:8000/control/tts/start

Start video mode:
  curl -X POST http://127.0.0.1:8000/control/video/start

Generate one video (multipart image + prompt):
  curl -X POST \
    -F "image=@/path/to/input.png" \
    -F "prompt=The character gently waves and blinks. Static camera." \
    http://127.0.0.1:8000/v1/videos/generations

Stop all GPU workloads:
  curl -X POST http://127.0.0.1:8000/control/off

CLI:
  ai-mode status
  ai-mode tts
  ai-mode video
  ai-mode off
  ai-mode restart

Storage:
  Workspace:      /workspace                         (code, logs, small runtime files)
  Shared HF:      "$HF_HOME"
  Video model:    "$VIDEO_HF_HOME"
  Video venv:     "$VIDEO_VENV"

Logs:

  Setup:      $STARTUP_LOG
  Install:    $INSTALL_LOG
  Preflight:  $PREFLIGHT_LOG
  Gateway:    $GATEWAY_LOG
  TTS:        $TTS_LOG
  Video:      $VIDEO_LOG
  MCP:        $MCP_LOG
  Video backend: HunyuanVideo-1.5 480p I2V Step-Distilled (public, async)
  FlashAttention: installed separately with --no-build-isolation
  Control:    $CONTROL_LOG

===============================================================================
EOF
