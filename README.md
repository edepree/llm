# LLM Stack

A local LLM inference stack for Strix Halo deployed via Ansible on Ubuntu/Debian with AMD GPU (ROCm). Choose between a **standalone** llama.cpp server deployment or a **modular** deployment with separate llama.cpp inference containers, a Bifrost model router, and an Open WebUI chat frontend. Both are orchestrated through Podman systemd user services.

## Quick Start

### Deploy

```bash
# production — runs setup and deploys to target host
./setup.sh

# development — installs toolchain only (no deployment)
./setup.sh --dev
```

The setup script will prompt for:
- **Target Endpoint** — hostname or IP of the target machine (default: `host.example.com`)
- **Deployment Mode** — `1` for standalone llama.cpp (default) or `2` for the modular stack
- **Target User** — SSH user (default: `ubuntu`)

### Standalone Mode

A single llama.cpp server runs with a model preset `.ini` file, serving both the OpenAI-compatible API and the built-in chat Web UI:

| Service | Port | Description |
|---------|------|-------------|
| llama.cpp (standalone) | 80 | OpenAI-compatible API + built-in Web UI |

Chat at `http://<target>` in your browser; the API is available at `http://<target>/v1`.

The server is deployed with a set of model presets defined in `roles/inference/defaults/main.yml` (the source of truth for which models are configured at any point in time), but only `models_max` model(s) are resident at once (default `1`): requesting a different model triggers an automatic LRU unload of an idle one. One preset may be marked `load-on-startup` so it downloads and loads at boot; the rest load on demand.

Requests select a model by its registered ID. The router normalizes quantization tags (stripping prefixes like `UD-`), so check the live list rather than guessing: `curl http://<target>/v1/models`.

### Modular Mode

After deployment, the following services are available on the target host:

| Service | Port | Description |
|---------|------|-------------|
| SSH | 22 | Remote Access |
| Open WebUI | 80 | Chat Frontend |
| Bifrost Router | 8080 | OpenAI-Compatible Model Router |
| llama.cpp (inference 01) | 9000 | Model 01 (see `inference_llamacpp` in `roles/inference/defaults/main.yml`) |
| llama.cpp (inference 02) | 9001 | Model 02 (see `inference_llamacpp` in `roles/inference/defaults/main.yml`) |

## Managing the Stack

All containers run as systemd user services under the `llm` service account.

### Check Service Status

```bash
# standalone mode
systemctl --user status llamacpp-server.service

# modular mode — check a specific service
systemctl --user status llamacpp-inference-01.service
systemctl --user status bifrost.service
systemctl --user status openwebui.service

# list all user services
systemctl --user list-units --type=service
```

### View Logs

```bash
# view logs for a specific service (follow mode)
journalctl --user -u llamacpp-server.service -f
journalctl --user -u llamacpp-inference-01.service -f
journalctl --user -u bifrost.service -f
journalctl --user -u openwebui.service -f

# view recent logs (last 100 lines)
journalctl --user -u llamacpp-inference-01.service -n 100
```

### Restart / Reload

```bash
# restart a container
systemctl --user restart llamacpp-inference-01.service

# stop a container
systemctl --user stop llamacpp-inference-01.service

# start a stopped container
systemctl --user start llamacpp-inference-01.service
```

## Architecture

### Standalone Mode

```mermaid
flowchart LR
    subgraph Client
        BROWSER["Browser / API Client"]
    end

    subgraph Inference
        LLAMA["llama.cpp server\nport 80\nAPI + Web UI"]
    end

    subgraph GPU
        ROCM["AMD GPU\n/dev/dri, /dev/kfd"]
    end

    BROWSER --> LLAMA
    LLAMA --> ROCM
```

**Data flow:**
1. Requests hit the single llama.cpp server on port 80
2. The built-in router loads/unloads models according to the preset file and routes requests by model ID
3. Inference runs on the AMD GPU via ROCm

**Key components:**
- **llama.cpp** — Runs as a single Podman quadlet container with `--models-preset` pointing at a generated `.ini` file; serves the OpenAI-compatible API and a built-in chat Web UI

### Modular Mode

```mermaid
flowchart LR
    subgraph Client
        OWUI["Open WebUI\nport 80"]
    end

    subgraph Router
        BIF["Bifrost\nport 8080"]
    end

    subgraph Inference
        INF01["llama.cpp 01\nport 9000\nmodel 01"]
        INF02["llama.cpp 02\nport 9001\nmodel 02"]
    end

    subgraph GPU
        ROCM["AMD GPU\n/dev/dri, /dev/kfd"]
    end

    OWUI --> BIF
    BIF --> INF01
    BIF --> INF02
    INF01 --> ROCM
    INF02 --> ROCM
```

**Data flow:**
1. Open WebUI sends chat requests to Bifrost's `/v1` endpoint
2. Bifrost routes requests to the appropriate llama.cpp instance based on configuration
3. llama.cpp serves inference requests using the loaded model, offloading to the AMD GPU via ROCm

**Key components:**
- **llama.cpp** — Runs as a Podman quadlet container, serving OpenAI-compatible API endpoints
- **Bifrost** — Model router that presents a unified `/v1` interface and load-balances across inference instances
- **Open WebUI** — Chat frontend that connects to Bifrost as its OpenAI-compatible backend

## Roles Reference

| Role | Tags | Purpose |
|------|------|---------|
| `common` | `common`, `system` | OS updates, packages (podman, ufw), sysctl, journald limits, base firewall |
| `service-account` | `accounts` | Creates the `llm` user with GPU access groups, enables systemd lingering |
| `system-hardening` | `hardening`, `updates` | Unattended upgrades and reboot configuration |
| `rocm` | `rocm`, `gpu` | ROCm memory configuration (TTM pages limit) |
| `podman-setup` | `podman`, `infrastructure` | Creates the `artificial-intelligence` Podman network |
| `inference` | `inference`, `llamacpp` | Standalone: single llama.cpp quadlet with model preset file. Modular: one quadlet container per model |
| `router` | `router`, `bifrost` | Modular only: deploys Bifrost router quadlet container with model routing config |
| `chat` | `chat`, `openwebui` | Modular only: deploys Open WebUI quadlet container |

## Configuration

### Deployment Mode

The deployment mode is chosen at the `setup.sh` prompt and passed to the playbook as `llm_stack_mode` (`standalone` or `modular`). Running the playbook directly without this variable defaults to `modular`.

> **Switching modes on an already-deployed host** does not remove the other mode's services. Stop and remove leftover quadlet units manually (e.g. `systemctl --user disable --now llamacpp-server` and delete the quadlet file under `~llm/.config/containers/systemd/`) if needed.

### Standalone Model Presets

The standalone server is configured through a model preset `.ini` file generated from `inference_standalone` in `roles/inference/defaults/main.yml`. See that file for the models, quantizations, and settings deployed at any point in time. The structure looks like this:

```yaml
inference_standalone:
  name: llamacpp-server
  port: 80
  models_max: 1 # max models resident at once; excess are unloaded LRU-style
  cache_path: /root/.cache/huggingface/hub # model cache, backed by a named volume
  global_settings: # shared defaults for all models ([*] section)
    n-gpu-layers: 999
    threads: 32
  presets: # one section per model
    - section: organization/model-GGUF:UD-Q8_K_XL
      settings:
        c: 131072
        hf-repo: organization/model-GGUF:UD-Q8_K_XL # required unless the model is already in the cache
        load-on-startup: "true" # optional: download and load at boot (use for at most one preset)
        temp: 1.0
        top-p: 1.0
```

Each preset must point at its model: set `hf-repo` (downloaded on demand) or `model` (local path) unless the model already exists in the server's cache.

Keys correspond to llama.cpp CLI arguments without leading dashes (see the [llama.cpp model presets documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#model-presets)). Requests select a model by its registered ID — list them with `curl http://<target>/v1/models`.

Preset-exclusive options are also supported as settings keys, e.g. `load-on-startup: true` downloads and loads the model when the server starts instead of waiting for the first request.

### Customizing Models (modular mode)

Edit `roles/inference/defaults/main.yml` to add or modify inference containers:

```yaml
inference_llamacpp:
  models:
    - name: llamacpp-inference-01
      port: 9000
      environment_variables:
        LLAMA_ARG_ALIAS: my-model
        LLAMA_ARG_HF_REPO: organization/repo:tag
        LLAMA_ARG_N_GPU_LAYERS: 999
      command: --temp 0.7 --top-p 0.9
```

Each model entry creates an independent systemd user service. The `LLAMA_ARG_*` env vars map to llama.cpp CLI flags.

### Router Configuration

Bifrost config is generated from `roles/router/templates/router-config.json.j2` using the same model list from `inference_llamacpp.models`. No manual config editing needed — changes to the model list propagate automatically.

### Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `inference_standalone.port` | `80` | Standalone llama.cpp listening port |
| `common_service_account.name` | `llm` | Service account for running containers |
| `podman_network_name` | `artificial-intelligence` | Podman network name |
| `router_bifrost.port` | `8080` | Bifrost listening port |
| `chat_openwebui.port` | `80` | Open WebUI listening port |
| `rocm_ttm_pages_limit` | `26214400` | ROCm TTM memory limit in pages |
| `sys_hardening_enable_updates` | `true` | Enable unattended upgrades |

### Conditional Deployment

Individual components can be disabled:

```bash
uv run ansible-playbook -i host, playbook.yml \
  --extra-vars "inference_enabled=false router_enabled=false"
```

Toggleable vars: `inference_enabled`, `router_enabled`, `chat_enabled`, `svc_account_enabled`, `sys_hardening_enable_updates`, `rocm_enabled`.

The `llm_stack_mode` var (`standalone` / `modular`, default `modular`) additionally skips the router and chat roles in standalone mode.
