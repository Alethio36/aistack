#!/usr/bin/env bash
# local-ai-stack installer.
# Detects GPU (or asks), renders per-host config, sets bind-mount permissions,
# and brings the stack up. Idempotent: reruns never regenerate secrets, never
# clobber existing config, never delete data.
#
# Usage:
#   sudo ./install.sh [install|update|down|status|logs|reconfigure-gpu]
#                     [--gpu nvidia|amd|cpu] [--data-root PATH] [--yes]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
LOG="$SCRIPT_DIR/install.log"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

SUBCMD="install"
ASSUME_YES=0
FORCE_GPU=""
CLI_DATA_ROOT=""
FORCE_WT=""
GPU_VENDOR=""
GPU_INFO=""

# ── output helpers ──────────────────────────────────────────────────────────
info() { printf '\033[0;34m[*]\033[0m %s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[0;32m[+]\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

# shellcheck disable=SC2154  # rc is assigned at the start of the trap body
trap 'rc=$?; if [ "$rc" -ne 0 ]; then warn "Aborted (exit $rc). Fix the issue and re-run: sudo ./install.sh ${SUBCMD}"; fi' EXIT

usage() {
  cat <<'EOF'
local-ai-stack installer

Commands:
  install            Detect GPU, configure, and start the stack (default)
  update             Record current image IDs, then pull+recreate (incl. OpenClaw)
  reconfigure-gpu    Re-detect/choose GPU and recreate Ollama
  down               Stop the stack
  status             Show containers and check data-dir write permissions
  logs               Follow logs

Options:
  --gpu nvidia|amd|cpu   Skip detection and force acceleration mode
  --data-root PATH       Override DATA_ROOT (where models/data live)
  --watchtower CRON      Set Watchtower schedule non-interactively (6-field cron)
  --yes, -y              Non-interactive (accept detected GPU; fail if none usable)
  -h, --help             This help
EOF
}

# ── small utilities ─────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. $2"; }

get_kv() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true
}

set_kv() {
  # set_kv KEY VALUE — update in place or append. Values are written raw.
  if grep -qE "^$1=" "$ENV_FILE" 2>/dev/null; then
    # use | delimiter; secrets/values here contain no | or newlines
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

# COMPOSE base command; GPU overlay appended by gpu_overlay()
COMPOSE=()
build_compose_cmd() {
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f compose.yaml)
  case "$(get_kv GPU_VENDOR)" in
    nvidia) COMPOSE+=(-f compose.gpu.nvidia.yaml) ;;
    amd)    COMPOSE+=(-f compose.gpu.amd.yaml) ;;
    *)      : ;;  # cpu / none / unset -> base only
  esac
}
dc() { "${COMPOSE[@]}" "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
  need_cmd docker "Install Docker Engine: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 plugin missing. Install: https://docs.docker.com/compose/install/"
  docker info >/dev/null 2>&1 \
    || die "Cannot reach the Docker daemon. Is it running, and are you root / in the docker group?"
  need_cmd openssl "Install openssl (Debian/Ubuntu: apt-get install -y openssl)."
}

# ── GPU detection / choice / probe ──────────────────────────────────────────
detect_gpu() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    GPU_INFO="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | paste -sd'; ' - || true)"
  elif [ -e /dev/kfd ] && command -v rocminfo >/dev/null 2>&1; then
    GPU_VENDOR="amd"
    GPU_INFO="$(rocminfo 2>/dev/null | grep -m1 -i 'Marketing Name' | sed 's/.*://; s/^ *//' || true)"
  elif ls /dev/dri/renderD* >/dev/null 2>&1; then
    GPU_VENDOR="unknown"
  else
    GPU_VENDOR="none"
  fi
}

choose_gpu() {
  if [ -n "$FORCE_GPU" ]; then
    case "$FORCE_GPU" in nvidia|amd|cpu) GPU_VENDOR="$FORCE_GPU" ;; *) die "--gpu must be nvidia|amd|cpu" ;; esac
    info "GPU mode forced: $GPU_VENDOR"
    return
  fi

  detect_gpu
  case "$GPU_VENDOR" in
    nvidia)  info "Detected NVIDIA: ${GPU_INFO:-unknown}" ;;
    amd)     info "Detected AMD (ROCm): ${GPU_INFO:-unknown}" ;;
    unknown) warn "A GPU is present but it is neither NVIDIA nor AMD ROCm — no supported Ollama GPU path." ;;
    none)    warn "No GPU detected." ;;
  esac

  # Non-interactive: accept usable detection, otherwise fail loudly (no silent CPU).
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    case "$GPU_VENDOR" in
      nvidia|amd) return ;;
      *) die "No usable GPU and running non-interactively. Re-run with --gpu cpu to accept slow CPU mode, or --gpu nvidia|amd to force." ;;
    esac
  fi

  local def="$GPU_VENDOR"
  case "$def" in unknown|none) def="cpu" ;; esac
  printf 'Use which acceleration? [nvidia/amd/cpu] (default: %s): ' "$def"
  local ans=""; read -r ans || true
  GPU_VENDOR="${ans:-$def}"
  case "$GPU_VENDOR" in nvidia|amd|cpu) ok "Using: $GPU_VENDOR" ;; *) die "Invalid choice: $GPU_VENDOR" ;; esac
}

probe_gpu() {
  # Confirm the container runtime can actually SEE the GPU — this is what prevents
  # Ollama silently running on CPU. We never auto-install host drivers/toolkit.
  local img; img="$(get_kv OLLAMA_IMAGE)"; img="${img:-ollama/ollama:latest}"
  case "$(get_kv GPU_VENDOR)" in
    nvidia)
      info "Probing NVIDIA visibility inside Docker (pulls ${img} if needed)…"
      if ! docker run --rm --gpus all "$img" nvidia-smi -L >/dev/null 2>&1; then
        die "Docker cannot see the NVIDIA GPU. Install the NVIDIA Container Toolkit on the host, then:
    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
  Guide: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
  (Or re-run with --gpu cpu to proceed CPU-only.)"
      fi
      ok "NVIDIA GPU visible to Docker."
      ;;
    amd)
      info "Checking AMD device nodes…"
      { [ -e /dev/kfd ] && [ -e /dev/dri ]; } \
        || die "AMD selected but /dev/kfd or /dev/dri is missing. Install ROCm on the host and reboot. (Or --gpu cpu.)"
      ok "AMD device nodes present. ROCm runtime is best-effort — verify with: docker logs ai-ollama"
      ;;
    *)
      warn "CPU-only mode — inference will be slow."
      ;;
  esac
}

# ── env + secrets ────────────────────────────────────────────────────────────
init_env() {
  [ -f "$ENV_EXAMPLE" ] || die ".env.example is missing from the repo."
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created .env from .env.example."
  fi

  # Secrets: generate once, reuse forever. Regenerating would break sessions.
  local k cur val
  for k in LITELLM_MASTER_KEY WEBUI_SECRET_KEY SEARXNG_SECRET OPENCLAW_GATEWAY_TOKEN; do
    cur="$(get_kv "$k")"
    if [ -z "$cur" ]; then
      if [ "$k" = "LITELLM_MASTER_KEY" ]; then
        val="sk-$(openssl rand -hex 24)"
      else
        val="$(openssl rand -hex 32)"
      fi
      set_kv "$k" "$val"
      info "Generated $k."
    fi
  done

  # Persist GPU + optional data-root override.
  if [ -n "$GPU_VENDOR" ]; then set_kv GPU_VENDOR "$GPU_VENDOR"; fi
  if [ -n "$CLI_DATA_ROOT" ]; then set_kv DATA_ROOT "$CLI_DATA_ROOT"; fi
  return 0
}

# ── Watchtower auto-update frequency ────────────────────────────────────────
# Writes a 6-field cron (sec min hour dom mon dow) to WATCHTOWER_SCHEDULE.
choose_watchtower() {
  # Non-interactive: honour --watchtower if given, else keep whatever is set.
  if [ -n "$FORCE_WT" ]; then set_kv WATCHTOWER_SCHEDULE "\"$FORCE_WT\""; info "Watchtower schedule: $FORCE_WT"; return 0; fi
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then return 0; fi

  printf '\nHow often should Watchtower auto-update images?\n'
  printf '  1) Daily 04:00          (0 0 4 * * *)   [default]\n'
  printf '  2) Every 6 hours        (0 0 */6 * * *)\n'
  printf '  3) Weekly, Sun 04:00    (0 0 4 * * 0)\n'
  printf '  4) Hourly               (0 0 * * * *)\n'
  printf '  5) Custom 6-field cron\n'
  printf 'Choose [1-5] (default 1): '
  local c=""; read -r c || true
  case "${c:-1}" in
    1) set_kv WATCHTOWER_SCHEDULE '"0 0 4 * * *"' ;;
    2) set_kv WATCHTOWER_SCHEDULE '"0 0 */6 * * *"' ;;
    3) set_kv WATCHTOWER_SCHEDULE '"0 0 4 * * 0"' ;;
    4) set_kv WATCHTOWER_SCHEDULE '"0 0 * * * *"' ;;
    5) printf 'Enter 6-field cron (sec min hour dom mon dow): '
       local cron=""; read -r cron || true
       if [ -n "$cron" ]; then set_kv WATCHTOWER_SCHEDULE "\"$cron\""; else warn "Empty — keeping current schedule."; fi ;;
    *) warn "Invalid choice — keeping current schedule." ;;
  esac
  ok "Watchtower schedule: $(get_kv WATCHTOWER_SCHEDULE)"
}

# ── config rendering (generate-if-absent) ───────────────────────────────────
render_configs() {
  local data_root lk sx dm
  data_root="$(get_kv DATA_ROOT)"; data_root="${data_root%/}"
  [ -n "$data_root" ] || die "DATA_ROOT is empty in .env."
  lk="$(get_kv LITELLM_MASTER_KEY)"
  sx="$(get_kv SEARXNG_SECRET)"
  dm="$(get_kv DEFAULT_MODEL)"

  install -d "$data_root/litellm" "$data_root/searxng" "$data_root/openclaw"

  _render() { # tmpl dest
    [ -f "$1" ] || die "Template not found: $1 — the .tmpl files must live under config/. Run from the repo root."
    if [ -s "$2" ]; then info "Keeping existing $(basename "$2") (not overwritten)."; return; fi
    local _tmp; _tmp="$(mktemp)"
    sed -e "s|@@LITELLM_MASTER_KEY@@|${lk}|g" \
        -e "s|@@SEARXNG_SECRET@@|${sx}|g" \
        -e "s|@@DEFAULT_MODEL@@|${dm}|g" \
        "$1" > "$_tmp"
    mv "$_tmp" "$2"
    ok "Rendered $(basename "$2")."
  }
  _render config/litellm.config.yaml.tmpl   "$data_root/litellm/config.yaml"
  _render config/searxng.settings.yml.tmpl  "$data_root/searxng/settings.yml"
  _render config/openclaw.json.tmpl         "$data_root/openclaw/openclaw.json"
}

# ── bind-mount dirs + permissions ───────────────────────────────────────────
# Known container UIDs: ollama=root(0), open-webui=root(0), openclaw=node(1000).
# Config files mounted read-only must be world-readable (non-root container users).
setup_dirs() {
  local data_root; data_root="$(get_kv DATA_ROOT)"; data_root="${data_root%/}"
  install -d "$data_root"/ollama "$data_root"/open-webui "$data_root"/openclaw \
             "$data_root"/litellm "$data_root"/searxng

  [ -f "$data_root/litellm/config.yaml" ] && chmod 644 "$data_root/litellm/config.yaml"
  [ -f "$data_root/searxng/settings.yml" ] && chmod 644 "$data_root/searxng/settings.yml"

  if ! chown -R 1000:1000 "$data_root/openclaw" 2>/dev/null; then
    warn "Could not chown $data_root/openclaw to 1000:1000 (run as root?). OpenClaw may fail to write."
  fi
  ok "Bind-mount directories prepared under $data_root."
}

verify_perms() {
  # Post-start: prove each writable service can write its data dir; emit the exact
  # fix if not (covers image-UID drift across :latest without silent failure).
  local pair svc dir
  for pair in "ollama:/root/.ollama" "open-webui:/app/backend/data" "openclaw:/home/node/.openclaw"; do
    svc="${pair%%:*}"; dir="${pair#*:}"
    if dc exec -T "$svc" sh -c "touch '$dir/.wtest' && rm -f '$dir/.wtest'" >/dev/null 2>&1; then
      ok "$svc can write its data dir."
    else
      warn "$svc CANNOT write $dir. Fix on host (DATA_ROOT/$svc), then 'docker restart ai-$svc':
    ollama/open-webui -> sudo chown -R 0:0   \$DATA_ROOT/$svc
    openclaw          -> sudo chown -R 1000:1000 \$DATA_ROOT/$svc"
    fi
  done
}

print_summary() {
  local wp op dm
  wp="$(get_kv WEBUI_PORT)"; op="$(get_kv OPENCLAW_PORT)"; dm="$(get_kv DEFAULT_MODEL)"
  local host; host="$(hostname -I 2>/dev/null | awk '{print $1}')"; host="${host:-<this-host>}"
  cat <<EOF | tee -a "$LOG"

──────────────────────────────────────────────────────────────────────────────
Stack is up.

  Open WebUI : http://${host}:${wp:-8080}        (create the admin user on first load)
  OpenClaw   : http://${host}:${op:-18789}       (LAN ONLY — do not tunnel this)

Next steps:
  1. In Open WebUI, pull a model: Settings -> Models -> pull '${dm:-qwen2.5:7b}'
     (Ollama/LiteLLM/OpenClaw are pre-wired to use it once it exists.)
  2. Finish OpenClaw setup via its own onboarding (model provider already points
     at LiteLLM in openclaw.json; you still add a messaging channel + pair it):
       docker exec -it ai-openclaw openclaw onboard      # or: openclaw doctor
  3. Verify OpenClaw's model route:  docker exec -it ai-openclaw openclaw models status

Update later:   sudo ./install.sh update     Stop:  sudo ./install.sh down
──────────────────────────────────────────────────────────────────────────────
EOF
}

# ── subcommands ─────────────────────────────────────────────────────────────
cmd_install() {
  preflight
  choose_gpu
  init_env
  choose_watchtower
  probe_gpu
  render_configs
  setup_dirs
  build_compose_cmd
  info "Pulling images…"; dc pull
  info "Starting stack…"; dc up -d
  sleep 4
  verify_perms
  print_summary
}

cmd_update() {
  preflight; init_env; build_compose_cmd
  local stamp dir; stamp="$(date +%Y%m%d-%H%M%S)"; dir="$SCRIPT_DIR/.image-digests"
  mkdir -p "$dir"
  dc images --quiet 2>/dev/null | sort -u > "$dir/$stamp.txt" || true
  info "Recorded running image IDs -> .image-digests/$stamp.txt (rollback reference)."
  dc pull
  dc up -d
  ok "Updated (OpenClaw included). If a pull broke something, the prior image IDs are in .image-digests/$stamp.txt."
}

cmd_reconfigure_gpu() {
  preflight; init_env; choose_gpu; set_kv GPU_VENDOR "$GPU_VENDOR"; probe_gpu
  build_compose_cmd
  info "Recreating Ollama with GPU mode: $(get_kv GPU_VENDOR)…"
  dc up -d --force-recreate ollama
  ok "Done."
}

cmd_down()   { preflight; init_env; build_compose_cmd; dc down; ok "Stopped."; }
cmd_logs()   { preflight; init_env; build_compose_cmd; dc logs -f; }
cmd_status() { preflight; init_env; build_compose_cmd; dc ps; echo; verify_perms; }

# ── arg parsing + dispatch ──────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    install|update|down|status|logs|reconfigure-gpu) SUBCMD="$1"; shift ;;
    --gpu)        FORCE_GPU="${2:-}"; shift 2 ;;
    --data-root)  CLI_DATA_ROOT="${2:-}"; shift 2 ;;
    --watchtower) FORCE_WT="${2:-}"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

: > "$LOG" 2>/dev/null || true
case "$SUBCMD" in
  install)         cmd_install ;;
  update)          cmd_update ;;
  reconfigure-gpu) cmd_reconfigure_gpu ;;
  down)            cmd_down ;;
  logs)            cmd_logs ;;
  status)          cmd_status ;;
esac
