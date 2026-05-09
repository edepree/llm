# llm

Ansible playbook that deploys a local AI stack on AMD Strix Halo (gfx1151). Installs llama.cpp in multi-model router mode and Open WebUI as a frontend.

## Architecture

```mermaid
graph LR
    user([User]) --> webui

    subgraph services["llm user services (systemd --user)"]
        webui["Open WebUI\n:80"]
        router["llama.cpp router\n:8080"]
    end

    webui -->|OpenAI API| router
    router -->|model: reasoning| r_model["Qwen3.6-35B Q6\nctx 128K · reasoning on"]
    router -->|model: coder| c_model["Qwen3.6-35B Q6\nctx 64K · reasoning off"]
```

A single `llama-server` instance handles all models via `--models-preset`. Clients address models by name (`"model": "reasoning"` or `"model": "coder"`); the server loads and routes to the matching preset.

## Requirements

- Target: Ubuntu 26.04, ROCm 7.1 already present
- Control: `uv` installed locally

## Setup

Bootstrap the control machine once:

```
./setup
```

## Deploy

```
./run
```

Prompts for a target endpoint. Use a hostname/IP for remote (SSH + sudo password) or `localhost` to run directly on the host (sudo password only).

## Warm Model Cache

Pre-downloads and loads all enabled models after provisioning. Blocks until complete — expect hours for large GGUFs.

```
uv run --no-lock ansible-playbook warm-cache.yml -i host.example.com,
```

## Troubleshooting

Services run as the `llm` user, so all logs are in the `llm` user journal. To read them, either switch to that user first:

```bash
sudo -u llm XDG_RUNTIME_DIR=/run/user/$(id -u llm) bash
```

Then tail whichever service you need:

```bash
# llama.cpp router
journalctl --user -u llamacpp.service -f

# Open WebUI
journalctl --user -u openwebui.service -f
```

Drop `-f` and add `-n 200` to read recent output without tailing.

Alternatively, query from any user by UID without switching:

```bash
journalctl _UID=$(id -u llm) -u llamacpp.service -f
```

### Watching cache warmup

Watch model files grow on disk as they download:

```bash
du -sh /home/llm/.cache/llama.cpp
```

Watch GPU/unified memory fill as models load:

```bash
rocm-smi --showmeminfo vram
```

## Design decisions

**Pre-built llama.cpp** — uses [lemonade-sdk/llamacpp-rocm](https://github.com/lemonade-sdk/llamacpp-rocm) releases rather than compiling from source. Version-stamped at `{{ llamacpp_prefix }}/version`; bump `llamacpp_rocm_tag` in `vars/main.yml` to upgrade.

**Router mode** — a single `llama-server` instance handles all models via `--models-preset`. Clients address models by name (`"model": "reasoning"`); the server loads and routes to the matching preset. `--models-max` caps concurrent loads.

**Service isolation** — services run as a dedicated `llm` user with lingering enabled, so they survive without a login session. All service management goes through `systemd --user`.

**HSA_OVERRIDE_GFX_VERSION=11.5.1** — required because ROCm reports Strix Halo's iGPU as an unrecognized device; the override forces gfx1151 codepath.

**Open WebUI via uv** — installed as a uv tool under the service account to keep its Python 3.11 dependency isolated from the system Python.

**TTM pages limit** — set via `modprobe.d` to allow the iGPU to pin the full 128 GiB unified memory as GTT. Value: `33554432` pages × 4 KiB = 128 GiB.
