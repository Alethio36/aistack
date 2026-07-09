# local-ai-stack

Clone-and-run, Docker-Compose local AI stack: **Ollama** (inference) → **LiteLLM**
(gateway) → **Open WebUI** (chat + model management) and **OpenClaw** (agent) →
**SearXNG** (search). One installer detects your GPU, renders per-host config and
secrets, sets bind-mount permissions, and brings everything up.

## Quick start

```bash
git clone <this-repo> local-ai-stack && cd local-ai-stack
sudo ./install.sh                 # detect GPU, configure, start
```

Then open `http://<host>:8080`, create the admin user, and pull a model
(Settings → Models). Everything downstream is wired to use it.

## Choosing a model

The default `DEFAULT_MODEL` is `qwen2.5:1.5b` — deliberately tiny (~1 GB) so it
runs on CPU-only hosts without grinding to a halt. It's fine for testing; it is
not a strong model. Size up once you know your hardware.

Rough memory rule (Q4-quantized, the Ollama default): a model needs about
**params × 0.7 GB** of RAM (CPU) or VRAM (GPU), plus ~1–2 GB for context. So a 7B
model wants ~5–6 GB, a 14B ~10–11 GB, a 70B ~45 GB+.

Sane picks by tier (pull the exact tag in Open WebUI → Settings → Models):

| Host | Suggested |
|------|-----------|
| CPU only, low RAM | `qwen2.5:0.5b`, `llama3.2:1b` |
| CPU, 8–16 GB RAM (default tier) | `qwen2.5:1.5b`, `gemma2:2b` |
| CPU, 16 GB+ / small GPU | `llama3.2:3b`, `qwen2.5:3b` |
| GPU ~8 GB | `qwen2.5:7b`, `llama3.1:8b`, `mistral:7b` |
| GPU 24 GB+ | `qwen2.5:14b`, `qwen2.5:32b` |
| GPU 48 GB+ | `llama3.3:70b` (quantized) |

Browse the full catalogue with sizes/tags at **ollama.com/library** (or search at
ollama.com/search). Larger and instruction-tuned variants, coding-specific models
(`qwen2.5-coder`), and vision models are all there.

To change the **agent's** model (OpenClaw is pinned to `DEFAULT_MODEL`): pull it in
Open WebUI, set `DEFAULT_MODEL` in `.env`, delete
`$DATA_ROOT/openclaw/openclaw.json`, and re-run `./install.sh` to regenerate it.
Open WebUI's own chat model is just whatever you pick in its dropdown — no config
change needed.

## Topology

```
Open WebUI ──native──> Ollama        (pull/delete/switch models from the UI)
Open WebUI ──OpenAI──> LiteLLM        (future cloud models in the same dropdown)
OpenClaw   ──OpenAI──> LiteLLM ─────> Ollama
OpenClaw   ─────────-> SearXNG
Open WebUI ─────────-> SearXNG        (web search)
```

Open WebUI talks to **Ollama natively** for model management — LiteLLM only
exposes a chat API and cannot pull/delete models, so that path stays direct.
OpenClaw goes **through LiteLLM** so the agent's usage hits the gateway (budgets,
logging, future providers).

## Exposure & the reverse proxy

Only user-facing services publish host ports; everything else is internal to the
Docker bridge and reached by service name.

| Service    | Exposure |
|------------|----------|
| Open WebUI | Yours. Plain HTTP on `WEBUI_PORT` (8080), or HTTPS via Traefik. Has auth — safe to reverse-proxy. |
| OpenClaw   | **LAN only. Never tunnel to WAN.** Runs shell commands with OS access; community skills are a prompt-injection / supply-chain surface. |
| Ollama     | Internal only. API is **unauthenticated** — never publish 11434. |
| LiteLLM    | Internal only. |
| SearXNG    | Internal only. |
| Traefik    | Only when a proxy mode is selected; publishes the HTTPS port(s). |

**The OpenClaw dashboard requires HTTPS.** Its Control UI refuses plain-HTTP
connections from any non-localhost browser (a browser secure-context rule —
`allowInsecureAuth` / `dangerouslyDisableDeviceAuth` do **not** override it). So
the installer offers a bundled **Traefik** proxy with a self-signed cert to
provide that secure context, with no external DNS, domain, or CA — it works on a
clean box by raw IP. Pick a mode at install (or `--proxy`, or `reconfigure-proxy`):

| `PROXY_MODE` | OpenClaw | Open WebUI |
|--------------|----------|------------|
| `none`       | plain HTTP on 18789 (dashboard unusable remotely — onboard via CLI) | plain HTTP on 8080 |
| `openclaw`   | **HTTPS** via Traefik on `OPENCLAW_HTTPS_PORT` (18443) — dashboard works | plain HTTP on 8080 |
| `all`        | HTTPS on 18443 | HTTPS on `WEBUI_HTTPS_PORT` (8443) |

Self-signed means a one-time browser "not trusted" warning — accept it (or trust
Traefik's cert); it's still a real HTTPS secure context. When Traefik fronts
OpenClaw, the installer writes `gateway.trustedProxies` and
`controlUi.allowedOrigins` into `openclaw.json` so the gateway accepts the
proxied connection. Dashboard login uses the gateway token as a URL fragment:
`https://<host>:18443/#token=<OPENCLAW_GATEWAY_TOKEN>`.

**Blast-radius note:** LAN-only limits *inbound* to OpenClaw, not what it can
*reach outbound*. On a flat LAN a compromised skill can hit everything on the
subnet. If you care, put the host (or OpenClaw) on its own VLAN with inter-VLAN
deny rules. Otherwise: vet skills, grant least capability.

## Onboarding / running commands in OpenClaw

OpenClaw needs a one-time interactive setup (model provider is pre-wired to
LiteLLM, but you add a messaging channel and pair it). The installer wraps this:

```bash
sudo ./install.sh onboard                    # openclaw onboard --mode local
sudo ./install.sh exec                       # interactive shell in the container
sudo ./install.sh exec openclaw models status
sudo ./install.sh exec openclaw doctor
```

**Discord** (the easiest way to drive OpenClaw — no dashboard/secure-context needed,
since the bot connection is outbound):

```bash
sudo ./install.sh discord                     # prints a step-by-step bot walkthrough,
                                              # takes your token, wires + restarts OpenClaw
```

Then DM the bot (or @mention it on your server) and approve the pairing prompt.

**Web search (SearXNG)** is pre-wired: the agent's `web_search` tool points at the
bundled SearXNG via `SEARXNG_BASE_URL=http://searxng:8080` (service name, not
localhost), with JSON output already enabled. If the onboarding wizard asks for a
SearXNG base URL, that's the value — but you shouldn't need to set it.

## GPU — host prerequisites (you install these; the script won't)

The installer detects NVIDIA / AMD / none, asks if unsure, and **probes whether
Docker can actually see the GPU** before starting (this is what stops Ollama
silently falling back to CPU). It will not auto-install drivers or toolkits —
that's host management, out of scope. It prints the exact command and stops.

**NVIDIA** (Debian/Ubuntu):
```bash
# 1. Driver (nvidia-smi must work on the host first)
# 2. NVIDIA Container Toolkit:
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```
RHEL/Fedora and Arch differ — see NVIDIA's container-toolkit install guide.

On **Proxmox**: the GPU must be PCIe-passed-through to this VM (or device-mapped
to the LXC) with the NVIDIA driver installed *inside* the guest. Single GPU can't
be shared across guests.

**AMD (ROCm):** install ROCm on the host, confirm `/dev/kfd` and `/dev/dri`
exist, add your user to `video`/`render`. ROCm support is uneven across consumer
cards; some need `HSA_OVERRIDE_GFX_VERSION` in `.env`. This path is best-effort —
if Ollama won't use the GPU, check `docker logs ai-ollama`.

**CPU-only:** `sudo ./install.sh --gpu cpu` (explicit opt-in; slow). The script
never falls back to CPU silently.

Multiple GPUs: defaults to all visible. Pin a subset with `OLLAMA_GPU_COUNT` /
`NVIDIA_VISIBLE_DEVICES` (NVIDIA) in `.env`.

## Where everything lives on the host

Two locations: the **repo** (code) and **`DATA_ROOT`** (everything persistent).

```
<repo>/                       # the git clone — code only
  install.sh, compose*.yaml, config/*.tmpl
  .env                        # generated, secrets, gitignored
  install.log, .image-digests/

$DATA_ROOT/                   # default: /opt/local-ai-stack/data  (outside the clone)
  ollama/                     # downloaded models (the big one — tens of GB)
  open-webui/                 # users, chats, settings (sqlite)
  openclaw/                   # openclaw.json, state, workspace, logs
  litellm/config.yaml
  searxng/settings.yml
```

`DATA_ROOT` is **configurable**: set it at install with `--data-root /path`, or edit
`DATA_ROOT` in `.env`. Keep it on a disk with room for models, and on a fast disk
(local SSD/NVMe) if you can — model load time depends on it. Changing `DATA_ROOT`
after install means moving the existing directory there first, or the stack starts
empty (models re-download).

## Performance note (CPU especially)

OpenClaw is an *agent*, not a chatbot — with a full tool profile, one message can
trigger multiple model calls (plan → tool → reason). On CPU that's brutal. Two
defaults handle this:

- **`tools.profile`** is set from GPU detection: `minimal` on CPU (single model
  call per message — responsive), `coding` on GPU (tools viable). Bump it anytime:
  `./install.sh exec openclaw openclaw config set tools.profile full`.
- **`models.providers.litellm.timeoutSeconds: 300`** raises OpenClaw's idle
  watchdog above the implicit ~120s, so a slow first token on a cold CPU model
  doesn't false-abort. (This is the correct per-provider key — *not*
  `agents.defaults.llm`, which older guides cite and which this version rejects.)

Ollama also keeps the model resident (`OLLAMA_KEEP_ALIVE=-1`) to avoid reload cost.
Even so: on CPU expect tens of seconds to minutes per reply. For a real agent,
use a GPU or route OpenClaw's model to a hosted provider via LiteLLM. Open WebUI
chat is unaffected — the local model is fine there; it's the agent loop that's
CPU-bound.

## Updates

Images run `:latest`. **Watchtower** (the maintained `nickfedor` fork — the
upstream `containrrr` image is abandoned and broke on recent Docker) auto-pulls
and recreates on a schedule for everything **except OpenClaw** — it's
beta-velocity with OS access, so it updates only when you run `./install.sh
update`.

The installer **asks for the update frequency** during install (daily / 6-hourly
/ weekly / hourly / custom). Set it non-interactively with `--watchtower '<6-field
cron>'`, or edit `WATCHTOWER_SCHEDULE` in `.env` directly.

```bash
sudo ./install.sh update    # records current image IDs first (rollback reference)
```

## Secrets & idempotency

`.env` is generated from `.env.example` on first run; secrets are generated
**once** and reused. `.env` is gitignored — never commit a filled one. Reruns
never regenerate secrets, never overwrite existing `litellm/config.yaml`,
`searxng/settings.yml`, or `openclaw/openclaw.json` (edit those freely), and
never delete data. `DATA_ROOT` lives outside the clone so `git clean` can't touch
your models.

## Commands

```bash
sudo ./install.sh                  # install / reconfigure
sudo ./install.sh update           # pull latest + recreate (incl. OpenClaw)
sudo ./install.sh reconfigure-gpu  # re-detect/choose GPU, recreate Ollama
sudo ./install.sh reconfigure-proxy # change proxy mode (none/openclaw/all)
sudo ./install.sh onboard          # OpenClaw onboarding
sudo ./install.sh exec [svc] [cmd] # shell/exec in a container (default: openclaw)
sudo ./install.sh status           # containers + data-dir write check
sudo ./install.sh logs             # follow logs
sudo ./install.sh down             # stop
```

## Honest caveats

- **OpenClaw is the rough edge.** Image variants and its `openclaw.json` schema
  move fast. The installer pre-wires the LiteLLM provider, but you finish setup
  via `openclaw onboard` (messaging channel + pairing — a script can't mint a bot
  token) and should confirm with `openclaw doctor` / `openclaw models status`. If
  the bundled image differs, consult the current OpenClaw docs.
- **AMD ROCm** detection is reliable; *working* depends on your card.
- **Dynamic models vs OpenClaw's allowlist:** Open WebUI can pull any model and
  LiteLLM passes it through (`ollama/<name>`), but OpenClaw needs an explicit
  allowlisted model — it's pinned to `DEFAULT_MODEL`. Change that in `.env` and
  re-render (delete `openclaw.json` to regenerate) if you switch the agent model.
- **Open WebUI ↔ SearXNG** search env var names occasionally change across Open
  WebUI releases; if web search misbehaves, check its current docs.
```
