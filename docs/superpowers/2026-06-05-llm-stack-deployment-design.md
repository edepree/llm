# Design: LLM Stack Deployment via Ansible + Rootless Podman

## Goal

Deploy an LLM inference stack on a fresh Ubuntu 26.04 host using Ansible to provision the system and rootless Podman containers for each service. Target hardware is an AMD GPU (ROCm). The stack consists of **llama.cpp** (inference, one container per model), **LiteLLM** (API proxy/routing), and **Open WebUI** (frontend).

## Architecture

```
User --> OpenWebUI (:80) --> LiteLLM (:4000) --> llama.cpp :8080 (model A)
                                                --> llama.cpp :8081 (model B)
                                                --> ...
```

- **OpenWebUI** is exposed externally on port 80. It communicates with LiteLLM as its OpenAI-compatible backend.
- **LiteLLM** is exposed externally on port 4000. It acts as a reverse proxy, routing requests to the appropriate llama.cpp instance based on the requested model name.
- **llama.cpp** containers are internal-only, each bound to `127.0.0.1` on a unique port. They are not accessible from outside the host.

Each model runs as a separate `llama-server` Podman container. This allows independent GPU memory management per model, independent model file volumes, and the ability to load/unload models without affecting others.

## Design Decisions

### 1. Rootless Podman under a dedicated `llm` service account

All containers run as a non-root `llm` user, created during host provisioning. Systemd lingering is enabled so the user's Podman runtime persists across logins. This follows the principle of least privilege — neither the containers nor the service account need root access.

### 2. One llama.cpp container per model

Each model gets its own container, its own GPU passthrough, and its own named volume for the model file. Models are accessed internally via `127.0.0.1:<port>`. LiteLLM's config maps each model name to the corresponding container's endpoint.

This approach has trade-offs:
- **Pro**: Independent VRAM isolation per model, easy to add/remove models, each container can be managed separately
- **Con**: More containers and Podman resources to track

### 3. LiteLLM as the routing layer

OpenWebUI talks to LiteLLM, which proxies to llama.cpp. LiteLLM supports the OpenAI API format natively, so OpenWebUI's `OPENAI_API_BASE_URL` and `OPENAI_API_KEY` settings point at LiteLLM. LiteLLM's `config.yaml` defines each model as a separate proxy target with its own `model_name` and `litellm_params` pointing at `http://127.0.0.1:<llama_port>/v1`.

### 4. llama.cpp container image from official ROCm build

The llama.cpp containers use the official `ghcr.io/ggml-org/llama.cpp:server-rocm` image. It already bundles ROCm support — no custom Dockerfile or image build needed. The host provides ROCm kernel drivers (loaded as part of provisioning); the container accesses GPU devices via Podman's `--device` passthrough.

### 5. Model weights downloaded to Podman named volumes

Model files (GGUF) are downloaded to a Podman named volume (`llamacpp-models`) mounted into each container. This ensures model data survives container rebuilds and is stored in Podman's managed storage rather than the container's writable layer.

## Project Structure

Flat layout — no roles, no indirection. One entrypoint (`deploy.yml`) imports task files in sequence.

```
.
├── ansible.cfg              # Ansible configuration (host key checking, sudo.ws)
├── deploy.yml               # Single entrypoint: imports tasks in order
├── vars/
│   └── main.yml             # All configuration variables (ports, models, GPU tuning)
├── tasks/
│   ├── common.yml           # Host provisioning: apt, UFW, unattended-upgrades
│   ├── rocm.yml             # Upstream ROCm install, TTM pages, modprobe.d
│   ├── service-account.yml  # llm user, groups, lingering, runtime dir
│   ├── podman.yml           # Podman installation, rootless setup
│   ├── models.yml           # Model weight downloads to Podman volumes
│   ├── llamacpp.yml         # Per-model containers (uses official image)
│   └── openwebui.yml        # LiteLLM + OpenWebUI containers
├── templates/
│   ├── litellm-config.yaml.j2 # LiteLLM proxy configuration
│   └── openwebui-env.j2      # OpenWebUI environment variables
```

## Playbook Flow

1. **Host provisioning** (`tasks/common.yml`):
   - `apt update && apt upgrade -y`
   - Install UFW, unattended-upgrades, other base packages
   - Configure UFW: deny incoming, allow SSH + port 80 + port 4000
   - Configure automatic security updates (unattended-upgrades)

2. **Service account** (`tasks/service-account.yml`):
   - Create `llm` user with render/video groups and lingering
   - Set up XDG runtime dir for rootless Podman

3. **ROCm kernel setup** (`tasks/rocm.yml`):
   - Add upstream ROCm APT repository
   - Install ROCm kernel module package for 7.x drivers
   - Set TTM pages limit via modprobe.d for unified memory

4. **Podman installation** (`tasks/podman.yml`):
   - Install Podman for the `llm` user
   - Configure rootless storage paths

5. **Model weights** (`tasks/models.yml`):
   - For each model: create Podman volume, download GGUF from HuggingFace
   - Skip if file already exists

6. **llama.cpp containers** (`tasks/llamacpp.yml`):
   - For each model: pull official ROCm image (once, shared) and start container with GPU passthrough

7. **LiteLLM** (`tasks/openwebui.yml`):
   - Deploy config, pull image, start container

8. **OpenWebUI** (`tasks/openwebui.yml`):
   - Pull image, start container with env pointing to LiteLLM

## Variables (key fields in `vars/main.yml`)

```yaml
service_account: llm
service_account_home: "/home/{{ service_account }}"

# GPU / ROCm
ttm_pages_limit: 33554432  # 128 GiB in 4 KiB pages
rocm_kernel_package: "rocm"  # upstream ROCm kernel package

# Ports
openwebui_port: 80
litellm_port: 4000

# LiteLLM
litellm_image: "ghcr.io/berriai/litellm:main"

# llama.cpp
llamacpp_image: "ghcr.io/ggml-org/llama.cpp:server-rocm"

# Models (one entry per model)
models:
  - name: model-a
    hf_repo: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q6_K_XL"
    llamacpp_port: 8080
    ctx_size: 131072
    gpu_layers: 999
    flash_attn: true
    cache_type_k: q4_0
    cache_type_v: q4_0
  - name: model-b
    hf_repo: "other-repo/other-model:quant-tag"
    llamacpp_port: 8081
    # ... same flags, different port and HF repo
```

## Idempotency Strategy

- **System updates**: `apt` module with `state: latest` and `update_cache: true` (idempotent by nature)
- **Firewall**: UFW tasks are declarative — only applied if not already configured
- **Service account**: `user` module with `state: present` — creates only if missing
- **Podman**: `apt` module for installation; `containers.podman.podman_image` for pulling official images
- **Containers**: `containers.podman.podman_container` module with `state: started`, `auto_remove: false`, `restart_policy: unless-stopped`
- **Model files**: Check file existence/hash before downloading; skip if already present
- **llama.cpp image**: Official `ggml-org/llama.cpp:server-rocm` — pulled once and shared across all model containers

## Network Ports

| Service     | Port     | Protocol | Exposed | Bound To      |
|-------------|----------|----------|---------|---------------|
| SSH         | 22       | TCP      | Yes     | 0.0.0.0       |
| OpenWebUI   | 80       | TCP      | Yes     | 0.0.0.0       |
| LiteLLM     | 4000     | TCP      | Yes     | 0.0.0.0       |

UFW rules will explicitly allow 22, 80, and 4000. All llama.cpp ports are internal-only.

## Error Handling & Recovery

- Container failures: `restart_policy: unless-stopped` ensures automatic restart
- Model download failures: Task fails with clear error, retry available
- GPU passthrough failures: Container won't start — error logged in Podman output
- LiteLLM config validation: LiteLLM itself validates config on startup

## ROCm Setup Details

The host installs ROCm kernel drivers from upstream AMD's APT repository. The key package is the ROCm kernel module meta-package that pulls in the correct `amdgpu` driver for the target GPU. The kernel module is loaded and blacklisted for Nouveau if applicable. The TTM subsystem is configured via `modprobe.d` to allow sufficient pages for the GPU's unified memory.

The official `ggml-org/llama.cpp:server-rocm` image is pre-built with ROCm support and relies on GPU device nodes (`/dev/dri`, `/dev/kfd`) passed through from the host.
