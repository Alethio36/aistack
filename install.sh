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
FORCE_PROXY=""
FORCE_TOKEN=""
EXEC_ARGS=()
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
  install            Detect GPU, choose proxy mode, configure, and start (default)
  update             Record current image IDs, then pull+recreate (incl. OpenClaw)
  reconfigure-gpu    Re-detect/choose GPU and recreate Ollama
  reconfigure-proxy  Change proxy mode (none/openclaw/all) and re-apply
  discord            Guided Discord bot setup (instructions + token + wiring)
  exec [svc] [cmd]   Exec into a service (default: shell in the OpenClaw container)
  onboard [args]     Run OpenClaw onboarding inside its container
  down               Stop the stack
  status             Show containers and check data-dir write permissions
  logs               Follow logs

Options:
  --gpu nvidia|amd|cpu   Skip detection and force acceleration mode
  --proxy none|openclaw|all  Set reverse-proxy mode non-interactively
  --token <BOT_TOKEN>    Discord bot token for non-interactive `discord`
  --data-root PATH       Override DATA_ROOT (where models/data live)
  --watchtower CRON      Set Watchtower schedule non-interactively (6-field cron)
  --yes, -y              Non-interactive (accept detected/default choices)
  -h, --help             This help

Examples:
  sudo ./install.sh --proxy openclaw          # HTTPS dashboard for OpenClaw
  sudo ./install.sh onboard                    # configure OpenClaw interactively
  sudo ./install.sh exec openclaw models status
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

# COMPOSE base command; GPU + proxy overlays appended here.
COMPOSE=()
build_compose_cmd() {
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f compose.yaml)
  case "$(get_kv GPU_VENDOR)" in
    nvidia) COMPOSE+=(-f compose.gpu.nvidia.yaml) ;;
    amd)    COMPOSE+=(-f compose.gpu.amd.yaml) ;;
    *)      : ;;  # cpu / none / unset -> base only
  esac
  # Proxy overlays. Compose can't remove a published port via overlay, so the
  # base publishes nothing user-facing and these add ports additively.
  case "$(get_kv PROXY_MODE)" in
    all)
      COMPOSE+=(-f compose.proxy-base.yaml -f compose.front-webui.yaml -f compose.front-openclaw.yaml) ;;
    openclaw)
      COMPOSE+=(-f compose.proxy-base.yaml -f compose.front-openclaw.yaml -f compose.direct-webui.yaml) ;;
    *)  # none / unset -> everything on direct plain-HTTP ports
      COMPOSE+=(-f compose.direct-webui.yaml -f compose.direct-openclaw.yaml) ;;
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

# ── reverse proxy / TLS mode ────────────────────────────────────────────────
# Writes PROXY_MODE = none | openclaw | all.
#   none     : direct plain-HTTP ports. OpenClaw dashboard not usable over LAN.
#   openclaw : Traefik fronts OpenClaw over self-signed HTTPS (dashboard works);
#              Open WebUI stays on its direct port.
#   all      : Traefik fronts OpenClaw + Open WebUI over HTTPS.
choose_proxy() {
  if [ -n "$FORCE_PROXY" ]; then
    case "$FORCE_PROXY" in none|openclaw|all) set_kv PROXY_MODE "$FORCE_PROXY"; info "Proxy mode: $FORCE_PROXY"; return 0 ;;
      *) die "--proxy must be none|openclaw|all" ;; esac
  fi
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    [ -n "$(get_kv PROXY_MODE)" ] || set_kv PROXY_MODE none
    return 0
  fi

  printf '\nReverse proxy / TLS (Traefik, self-signed cert).\n'
  printf 'The OpenClaw web dashboard needs an HTTPS "secure context"; Traefik provides it.\n'
  printf '  1) None — direct plain-HTTP ports. OpenClaw dashboard via CLI/tunnel only.\n'
  printf '  2) Traefik for OpenClaw only — HTTPS dashboard; Open WebUI stays direct. [default]\n'
  printf '  3) Traefik for OpenClaw + Open WebUI — both over HTTPS.\n'
  printf 'Choose [1-3] (default 2): '
  local c=""; read -r c || true
  case "${c:-2}" in
    1) set_kv PROXY_MODE none ;;
    2) set_kv PROXY_MODE openclaw ;;
    3) set_kv PROXY_MODE all ;;
    *) warn "Invalid choice — defaulting to OpenClaw-only."; set_kv PROXY_MODE openclaw ;;
  esac
  ok "Proxy mode: $(get_kv PROXY_MODE)"
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

  patch_openclaw_proxy "$data_root/openclaw/openclaw.json"
}

# When Traefik fronts OpenClaw, the gateway sits behind a reverse proxy and must
# (a) trust the proxy's forwarded headers and (b) allow the HTTPS origin the
# browser uses. Adds these to openclaw.json without clobbering existing values.
patch_openclaw_proxy() {
  local cfg="$1" mode host port origin
  mode="$(get_kv PROXY_MODE)"
  case "$mode" in openclaw|all) : ;; *) return 0 ;; esac
  port="$(get_kv OPENCLAW_HTTPS_PORT)"; port="${port:-18443}"
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"; host="${host:-127.0.0.1}"
  origin="https://${host}:${port}"
  ORIGIN="$origin" python3 - "$cfg" <<'PY' || warn "Could not patch openclaw.json for proxy; set gateway.trustedProxies/allowedOrigins manually."
import json, os, sys
p = sys.argv[1]; origin = os.environ["ORIGIN"]
c = json.load(open(p))
g = c.setdefault("gateway", {})
# Trust the Docker bridge range (Traefik reaches the gateway from there).
g.setdefault("trustedProxies", ["172.16.0.0/12"])
cu = g.setdefault("controlUi", {})
ao = cu.setdefault("allowedOrigins", [])
if origin not in ao:
    ao.append(origin)
json.dump(c, open(p, "w"), indent=2)
print("patched openclaw.json proxy fields:", origin)
PY
  ok "OpenClaw proxy fields set (origin ${origin})."
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
  local dm mode host wp op whttps ohttps
  dm="$(get_kv DEFAULT_MODEL)"; mode="$(get_kv PROXY_MODE)"; mode="${mode:-none}"
  wp="$(get_kv WEBUI_PORT)"; wp="${wp:-8080}"
  op="$(get_kv OPENCLAW_PORT)"; op="${op:-18789}"
  whttps="$(get_kv WEBUI_HTTPS_PORT)"; whttps="${whttps:-8443}"
  ohttps="$(get_kv OPENCLAW_HTTPS_PORT)"; ohttps="${ohttps:-18443}"
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"; host="${host:-<this-host>}"

  local webui_url openclaw_line
  case "$mode" in
    all)      webui_url="https://${host}:${whttps}  (self-signed cert — accept the warning)" ;;
    *)        webui_url="http://${host}:${wp}" ;;
  esac
  case "$mode" in
    openclaw|all) openclaw_line="https://${host}:${ohttps}  (self-signed cert — dashboard works here)" ;;
    *)            openclaw_line="http://${host}:${op}  (LAN only; dashboard NOT usable over plain HTTP — onboard via CLI)" ;;
  esac

  cat <<EOF | tee -a "$LOG"

──────────────────────────────────────────────────────────────────────────────
Stack is up.  (proxy mode: ${mode})

  Open WebUI : ${webui_url}
               create the admin user on first load
  OpenClaw   : ${openclaw_line}

Next steps:
  1. In Open WebUI, pull a model: Settings -> Models -> pull '${dm:-qwen2.5:1.5b}'
     (Ollama/LiteLLM/OpenClaw are pre-wired to use it once it exists.)
  2. Onboard OpenClaw (add a messaging channel + pair it):
       sudo ./install.sh onboard
     Token login for the dashboard (append as URL fragment):
       <openclaw-url>/#token=$(get_kv OPENCLAW_GATEWAY_TOKEN)
  3. Open a shell / run any OpenClaw command:
       sudo ./install.sh exec                 # shell in the OpenClaw container
       sudo ./install.sh exec openclaw models status

Update:  sudo ./install.sh update     Stop:  sudo ./install.sh down
──────────────────────────────────────────────────────────────────────────────
EOF
}

# ── subcommands ─────────────────────────────────────────────────────────────
cmd_install() {
  preflight
  choose_gpu
  init_env
  choose_watchtower
  choose_proxy
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

cmd_reconfigure_proxy() {
  preflight; init_env; choose_proxy
  # refresh OpenClaw proxy fields for the new mode, then recreate affected services
  local data_root; data_root="$(get_kv DATA_ROOT)"; data_root="${data_root%/}"
  patch_openclaw_proxy "$data_root/openclaw/openclaw.json"
  build_compose_cmd
  info "Applying proxy mode: $(get_kv PROXY_MODE)…"
  dc up -d --remove-orphans
  ok "Done. (If OpenClaw's allowedOrigins changed, give it a moment to restart.)"
}

# exec into a service. Usage: install.sh exec [service] [cmd...]
# Defaults to an interactive shell in the OpenClaw container.
cmd_exec() {
  preflight; init_env; build_compose_cmd
  local svc="openclaw"
  if [ "${#EXEC_ARGS[@]}" -gt 0 ]; then svc="${EXEC_ARGS[0]}"; EXEC_ARGS=("${EXEC_ARGS[@]:1}"); fi
  if [ "${#EXEC_ARGS[@]}" -gt 0 ]; then
    dc exec "$svc" "${EXEC_ARGS[@]}"
  else
    info "Opening a shell in '$svc' (Ctrl-D to exit)…"
    dc exec "$svc" bash 2>/dev/null || dc exec "$svc" sh
  fi
}

# Convenience: run OpenClaw's onboarding inside its container.
cmd_onboard() {
  preflight; init_env; build_compose_cmd
  info "Launching OpenClaw onboarding (Ctrl-C to abort)…"
  if [ "${#EXEC_ARGS[@]}" -gt 0 ]; then
    dc exec openclaw openclaw onboard "${EXEC_ARGS[@]}"
  else
    dc exec openclaw openclaw onboard --mode local
  fi
}

# Guided Discord channel setup: instructions, token capture, wiring, restart.
cmd_discord() {
  preflight; init_env; build_compose_cmd
  cat <<'EOF'

── Connect OpenClaw to Discord ────────────────────────────────────────────────
Create a bot (≈5 min), then paste its token below.

  1. https://discord.com/developers/applications  ->  New Application  ->  name it
  2. Left sidebar -> Bot. Under "Privileged Gateway Intents" enable:
       - Message Content Intent   (REQUIRED — without it the bot ignores messages)
       - Server Members Intent    (recommended)
  3. Still on Bot: click "Reset Token" -> Copy it (that's what you paste here).
  4. Left sidebar -> OAuth2 -> URL Generator. Scopes: tick  bot  +  applications.commands
       Bot Permissions: tick  View Channels, Send Messages, Read Message History
       (do NOT grant Administrator). Copy the URL at the bottom.
  5. Open that URL, choose YOUR server (make a private one if needed), Authorize.
────────────────────────────────────────────────────────────────────────────────
EOF
  local token=""
  if [ -n "$FORCE_TOKEN" ]; then
    token="$FORCE_TOKEN"
  elif [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    die "Non-interactive: pass the token with --token <BOT_TOKEN>."
  else
    printf 'Paste your Discord Bot Token (blank to abort): '
    read -r token || true
  fi
  [ -n "$token" ] || { warn "No token — Discord setup aborted."; return 0; }

  set_kv DISCORD_BOT_TOKEN "$token"
  local data_root cfg; data_root="$(get_kv DATA_ROOT)"; data_root="${data_root%/}"
  cfg="$data_root/openclaw/openclaw.json"
  python3 - "$cfg" <<'PY' || die "Could not enable the Discord channel in openclaw.json."
import json, sys
p = sys.argv[1]; c = json.load(open(p))
d = c.setdefault("channels", {}).setdefault("discord", {})
d["enabled"] = True
d["token"] = {"source": "env", "provider": "default", "id": "DISCORD_BOT_TOKEN"}
json.dump(c, open(p, "w"), indent=2)
print("Discord channel enabled in openclaw.json")
PY
  info "Recreating OpenClaw with the Discord token…"
  dc up -d --force-recreate openclaw
  cat <<'EOF'

Discord wired. Final steps (in Discord):
  - DM your bot, or @mention it in a channel on your server.
  - Approve the pairing request it sends (first contact only).
  - Guild messages are mention-gated by default — @mention the bot to get a reply.
Check status:  sudo ./install.sh exec openclaw openclaw channels status
EOF
  ok "Discord setup complete."
}

cmd_down()   { preflight; init_env; build_compose_cmd; dc down; ok "Stopped."; }
cmd_logs()   { preflight; init_env; build_compose_cmd; dc logs -f; }
cmd_status() { preflight; init_env; build_compose_cmd; dc ps; echo; verify_perms; }

# ── arg parsing + dispatch ──────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    install|update|down|status|logs|reconfigure-gpu|reconfigure-proxy|discord)
      SUBCMD="$1"; shift ;;
    exec|onboard)
      SUBCMD="$1"; shift; EXEC_ARGS=("$@"); break ;;   # rest is verbatim service/cmd
    --gpu)        FORCE_GPU="${2:-}"; shift 2 ;;
    --data-root)  CLI_DATA_ROOT="${2:-}"; shift 2 ;;
    --watchtower) FORCE_WT="${2:-}"; shift 2 ;;
    --proxy)      FORCE_PROXY="${2:-}"; shift 2 ;;
    --token)      FORCE_TOKEN="${2:-}"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

: > "$LOG" 2>/dev/null || true
case "$SUBCMD" in
  install)          cmd_install ;;
  update)           cmd_update ;;
  reconfigure-gpu)  cmd_reconfigure_gpu ;;
  reconfigure-proxy) cmd_reconfigure_proxy ;;
  discord)          cmd_discord ;;
  exec)             cmd_exec ;;
  onboard)          cmd_onboard ;;
  down)             cmd_down ;;
  logs)             cmd_logs ;;
  status)           cmd_status ;;
esac
