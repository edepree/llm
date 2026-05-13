# Container-Based Deployment with Podman

## Context

Currently, llama.cpp and OpenWebUI are deployed as native systemd user services under the `llm` user — llama.cpp via pre-built ROCm binaries from lemonade-sdk, and OpenWebUI via `uv tool install`. The goal is to move entirely to podman containers running rootless under the same `llm` user. OpenWebUI uses its official container image; llama.cpp is built into a container from an Ubuntu 26.04-based Dockerfile.

## Changes

### 1. Create `containers/llamacpp/Dockerfile`

Minimal Ubuntu 26.04 base. Downloads and unpacks the llama.cpp ROCm release (lemonade-sdk), copies `llama-server` and its bundled `.so` files into `/app`. Host ROCm provides runtime libraries. Sets env vars (`HSA_OVERRIDE_GFX_VERSION`, `LD_LIBRARY_PATH`), exposes port 8080, sets `ENTRYPOINT` to `/app/llama-server`.

### 2. Create `bin/run-containers.sh`

Manages both containers via podman:

- **llama.cpp container:** builds locally from Dockerfile. Runs with GPU passthrough (`--device /dev/dri --device /dev/kfd`), host network, presets volume mount (`presets.ini` from `~/.config/llamacpp/`), podman named volume for model cache (`llamacpp-models:/models`), and env vars from original service file. Uses `--replace` and `--restart unless-stopped`.
- **OpenWebUI container:** pulls `ghcr.io/open-webui/open-webui:latest`. Runs with GPU passthrough, host network, podman named volume for data (`openwebui-data:/app/backend/data`), and environment variables mirroring `openwebui_env` from vars/main.yml. Exposes port 80 (container port 8080).

### 3. Replace `tasks/llamacpp.yml` → `tasks/llamacpp-containers.yml`

New task file that:
- Ensures podman podman volumes exist (`llamacpp-models` for model cache)
- Calls `bin/run-containers.sh build-only` to build the llama.cpp image (idempotent)
- Deploys the presets.ini template (reuse `templates/llamacpp-presets.ini.j2`) to `{{ service_account_home }}/.config/llamacpp/presets.ini`
- Calls `bin/run-containers.sh start` to launch the llama.cpp container

### 4. Replace `tasks/openwebui.yml` → `tasks/openwebui-containers.yml`

New task file that:
- Ensures `openwebui-data` podman volume exists
- Calls `bin/run-containers.sh start-openwebui` to pull and start the OpenWebUI container

### 5. Update `setup.yml`

- Replace `tasks/llamacpp.yml` with `tasks/llamacpp-containers.yml`
- Replace `tasks/openwebui.yml` with `tasks/openwebui-containers.yml`
- Add a new task `tasks/podman-setup.yml` (or inline block) that ensures podman is installed (`apt: name=podman`) — the `llm` user's group membership (`render,video`) already exists from the current service-account setup
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
| Create | `bin/run-containers.sh` |
| Create | `tasks/llamacpp-containers.yml` |
| Create | `tasks/openwebui-containers.yml` |
| Modify | `setup.yml` (replace task imports, remove handlers) |
| Modify | `README.md` |
| Delete | `templates/llamacpp.service.j2` |
| Delete | `templates/openwebui.service.j2` |
| Keep | `templates/llamacpp-presets.ini.j2` (presets still generated from ansible vars) |

## Key design notes

- **GPU passthrough:** Both containers get `--device /dev/dri --device /dev/kfd`. Rootless podman works when user is in `video`/`render` groups (already configured for `llm` user).
- **ROCm libraries:** Rely on host ROCm 7.1 installation — container only bundles llama-server binary and its bundled `.so` files from lemonade-sdk.
- **Presets:** `presets.ini` lives on the host at `~/.config/llamacpp/presets.ini` and is bind-mounted read-only into the container. Generated from the existing ansible jinja template.
- **Model cache:** Uses a podman named volume (`llamacpp-models`) for llama.cpp HF model downloads, and another (`openwebui-data`) for OpenWebUI persistent data. Survives container rebuilds.
- **No systemd:** All container lifecycle handled by podman's `--restart unless-stopped`. Container startup triggered by ansible playbook.
- **Networking:** `--network host` for simplicity — both containers bind directly to host ports. OpenWebUI connects to llama.cpp at `http://localhost:8080`.
- **Auto-update:** `podman auto-update` runs after containers start to pull new image versions.

## Verification (manual steps post-deployment)

1. Run `./run` against localhost — playbook should complete without errors
2. Verify containers are running: `sudo -u llm podman ps`
3. Verify named volumes exist: `sudo -u llm podman volume ls`
4. Check llama.cpp: `curl http://localhost:8080/health` should return OK
5. Check OpenWebUI: browse to `http://localhost:80` — UI should load
6. Test model inference: send a request through OpenWebUI API pointing at a loaded model
7. Verify GPU usage: `rocm-smi --showmeminfo vram` should show memory allocation
8. Verify model cache in podman volume: `sudo -u llm podman volume inspect llamacpp-models`
9. Verify container persistence after reboot (lingering + `--restart unless-stopped`)
10. Verify presets reload: change a model config in ansible vars, re-run, confirm container picks up new presets.ini
