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

## Exposure — only two services publish ports

| Service    | Port  | Exposure |
|------------|-------|----------|
| Open WebUI | 8080  | Yours. Safe to reverse-proxy / Cloudflare Tunnel (it has auth). |
| OpenClaw   | 18789 | **LAN only. Never tunnel.** It runs shell commands with OS access; community skills are a prompt-injection / supply-chain surface. Reach it remotely over a VPN, or drive it via an outbound messaging channel (Telegram/Discord). |
| Ollama     | —     | Internal only. Its API is **unauthenticated** — never publish 11434. |
| LiteLLM    | —     | Internal only. |
| SearXNG    | —     | Internal only. |

**Blast-radius note:** LAN-only limits *inbound* to OpenClaw, not what it can
*reach outbound*. On a flat LAN a compromised skill can hit everything on the
subnet. If you care, put the host (or OpenClaw) on its own VLAN with inter-VLAN
deny rules. Otherwise: vet skills, grant least capability.

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
