# Container-Based Deployment with Podman

## Context

Currently, llama.cpp and OpenWebUI are deployed as native systemd user services under the `llm` user — llama.cpp via pre-built ROCm binaries from lemonade-sdk, and OpenWebUI via `uv tool install`. The goal is to move entirely to podman containers running rootless under the same `llm` user. OpenWebUI uses its official container image; llama.cpp is built into a container from an Ubuntu 26.04-based Dockerfile.

## Changes

### 1. Create `containers/llamacpp/Dockerfile`

Ubuntu 26.04 base. Downloads and unpacks the llama.cpp ROCm release from [aigdat/llamacpp-rocm](https://github.com/aigdat/llamacpp-rocm) (GitHub releases). The release bundles **ROCm 7 runtime libraries** — no separate host ROCm installation needed. Copies `llama-server` and all `.so` files into `/app`. Does NOT set `HSA_OVERRIDE_GFX_VERSION` or `LD_LIBRARY_PATH`; the bundled ROCm resolves its own deps. Exposes port 8080, sets `ENTRYPOINT` to `/app/llama-server`.

### 2. Replace `bin/run-containers.sh` with Ansible podman modules

Use the [`containers.podman`](https://docs.ansible.com/projects/ansible/latest/collections/containers/podman/) collection (install via `ansible-galaxy collection install containers.podman`) instead of a bash script. All container lifecycle is managed declaratively in Ansible task files:

- **`containers.podman.podman_volume`** — create `llamacpp-models` and `openwebui-data` named volumes idempotently
- **`containers.podman.podman_image`** — build llama.cpp image from Dockerfile (`build: {create_new: true, dockerfile: ...}`); pull OpenWebUI image (`ghcr.io/open-webui/open-webui:latest`) with `pull: true`
- **`containers.podman.podman_container`** — manage both containers with:
  - `state: started`, `restart: unless-stopped`
  - GPU passthrough: `devices: [/dev/dri, /dev/kfd]`
  - Networking: `network: host`
  - Volumes: bind-mount `presets.ini` and named volume for model cache on llama.cpp; named volume for OpenWebUI data
  - Environment: pass `env` dict from ansible vars (e.g., `{{ openwebui_env | default({} | combine(default_env)) }}`)
  - `pull: missing` policy so existing images are reused
  - `force_kill: true` and `replace: true` to handle container recreation

### 3. Replace `tasks/llamacpp.yml` → `tasks/llamacpp-containers.yml`

New task file that:
- Uses `containers.podman.podman_volume` to create `llamacpp-models` volume
- Deploys the presets.ini template (reuse `templates/llamacpp-presets.ini.j2`) to `{{ service_account_home }}/.config/llamacpp/presets.ini`
- Uses `containers.podman.podman_image` to build the llama.cpp image from `containers/llamacpp/Dockerfile`
- Uses `containers.podman.podman_container` to start the llama.cpp container with GPU devices, host network, presets bind-mount, and model cache volume

### 4. Replace `tasks/openwebui.yml` → `tasks/openwebui-containers.yml`

New task file that:
- Uses `containers.podman.podman_volume` to create `openwebui-data` volume
- Uses `containers.podman.podman_image` to pull the OpenWebUI image
- Uses `containers.podman.podman_container` to start the OpenWebUI container with GPU devices, host network, data volume, and environment variables from `openwebui_env`

### 5. Update `setup.yml`

- Add `galaxy_install` step to ensure `containers.podman` collection is installed
- Replace `tasks/llamacpp.yml` with `tasks/llamacpp-containers.yml`
- Replace `tasks/openwebui.yml` with `tasks/openwebui-containers.yml`
- Ensure podman package is installed (`apt: name=podman`) — the `llm` user's group membership (`render,video`) already exists from the current service-account setup
- Remove the `Restart llamacpp` and `Restart Open WebUI` handlers from the top-level playbook (handlers were on lines 18-32)

### 6. Delete obsolete template files

Remove:
- `templates/llamacpp.service.j2` — no longer needed (no systemd user service)
- `templates/openwebui.service.j2` — no longer needed (no systemd user service)

### 7. Update README.md

- Update architecture diagram to show containers instead of systemd services
- Update setup/troubleshooting sections (journalctl references, warm cache info)
- Remove "Pre-built llama.cpp" design decision note (now containerized)
- Update OpenWebUI section (now via official container, not uv)

## Files to modify (summary)

| Action | Path |
|--------|------|
| Create | `containers/llamacpp/Dockerfile` |
| Create | `tasks/llamacpp-containers.yml` |
| Create | `tasks/openwebui-containers.yml` |
| Modify | `setup.yml` (replace task imports, remove handlers, add galaxy_install) |
| Modify | `README.md` |
| Delete | `templates/llamacpp.service.j2` |
| Delete | `templates/openwebui.service.j2` |
| Keep | `templates/llamacpp-presets.ini.j2` (presets still generated from ansible vars) |

## Key design notes

- **GPU passthrough:** Both containers get `devices: [/dev/dri, /dev/kfd]`. Rootless podman works when user is in `video`/`render` groups (already configured for `llm` user). Only host kernel DRM/KFD drivers are required — no host ROCm userspace libraries.
- **Bundled ROCm:** The llama.cpp release from [aigdat/llamacpp-rocm](https://github.com/aigdat/llamacpp-rocm) ships ROCm 7 runtime libraries inside the archive, so the container is fully self-contained for GPU compute. The host only needs compatible kernel drivers (Linux 6.1+).
- **Presets:** `presets.ini` lives on the host at `~/.config/llamacpp/presets.ini` and is bind-mounted read-only into the container. Generated from the existing ansible jinja template.
- **Model cache:** Uses a podman named volume (`llamacpp-models`) for llama.cpp HF model downloads, and another (`openwebui-data`) for OpenWebUI persistent data. Survives container rebuilds.
- **No systemd:** All container lifecycle handled by `containers.podman` modules with `restart: unless-stopped`. Containers are managed entirely by Ansible playbooks.
- **Networking:** `network: host` for simplicity — both containers bind directly to host ports. OpenWebUI connects to llama.cpp at `http://localhost:8080`.
- **Auto-update:** Add a separate task/handler that runs `podman auto-update` under the `llm` user (via `ansible.builtin.command` or `community.general.podman_pod`) to pull new image versions on schedule or after playbook runs.
- **No bash script:** Container orchestration is fully declarative in Ansible using podman collection modules — idempotent, portable, and integrated into the playbook flow.

## Verification (manual steps post-deployment)

1. Run `./run` against localhost — playbook should complete without errors
2. Verify containers are running: `sudo -u llm podman ps`
3. Verify named volumes exist: `sudo -u llm podman volume ls`
4. Check llama.cpp: `curl http://localhost:8080/health` should return OK
5. Check OpenWebUI: browse to `http://localhost:80` — UI should load
6. Test model inference: send a request through OpenWebUI API pointing at a loaded model
7. Verify GPU usage: `rocm-smi --showmeminfo vram` should show memory allocation
8. Verify model cache in podman volume: `sudo -u llm podman volume inspect llamacpp-models`
9. Verify container persistence after reboot (lingering + `restart: unless-stopped`)
10. Verify presets reload: change a model config in ansible vars, re-run, confirm container picks up new presets.ini
