# Operations

## Running the Playbook

`./setup.sh` deploys everything. To run one role, for example after changing its defaults:

```bash
uv run ansible-playbook -i <host>, playbook.yml --tags <role> -u <user> --ask-pass --ask-become-pass
```

Override a default without editing the file with `-e <variable>=<value>`.

## Managing Services

The services are systemd user services of `service_account_user` (`llm`). The account has no password or SSH key. From the admin account:

```bash
sudo systemctl --user -M llm@ status llamacpp-server.service
sudo systemctl --user -M llm@ restart llamacpp-server.service
sudo journalctl --user -M llm@ -u llamacpp-server.service -f
```

To run `podman` as `llm`, for example to call a backend directly on `llm.network`, open a login session:

```bash
sudo machinectl shell llm@
podman run --rm --network llm docker.io/curlimages/curl -s http://llamacpp-server:8080/health
```

`sudo -u llm` and `su - llm` do not open a login session, so `systemctl --user` and `podman` cannot find the user manager or the container state.

`common_packages` (`roles/common/defaults/main.yml`) includes monitoring tools: `nvtop` (GPU), `nethogs` (network per process; rootless container traffic shows up under `pasta`), and `xrt-smi examine` (NPU).

## Changing Models

Models are defined in `inference_presets` in `roles/inference/defaults/main.yml`, then deployed with `--tags inference`. The comment on `inference_presets` describes the format. llama-server does not start if a key is unknown, so check the journal after a change.

## Upgrading Components

Set the variable in the role's `defaults/main.yml` and run the playbook with that role's tag. The play builds or pulls the new image, restarts the service, and runs the role's checks.

| Component | Variable | Versions |
|-----------|----------|----------|
| llama.cpp | `inference_llama_ref` | [release tags](https://github.com/ggml-org/llama.cpp/releases) |
| FastFlowLM | `stt_flm_version` | [releases](https://github.com/ROCm/FastFlowLM/releases) with an `ubuntu26.04` package |
| Kokoros | `tts_kokoros_ref` | [commits](https://github.com/lucasjinreal/Kokoros/commits/main) |
| Bifrost | `router_bifrost_image` | [releases](https://github.com/maximhq/bifrost/releases) |
| Open WebUI | `webui_image` | [releases](https://github.com/open-webui/open-webui/releases) |
| Caddy | `proxy_caddy_image` | [releases](https://github.com/caddyserver/caddy/releases) |

To roll back, set the previous value. Older locally built images stay on the host, so no rebuild runs unless the Containerfile changed since then.

Builds leave untagged builder images of several GB. To remove them and old tags, run this in `sudo machinectl shell llm@`:

```bash
podman image prune -f
podman image rm localhost/llama-server:<old tag>
```

### Service Account Restart

When the `service_account` role changes the account's memlock limit, it restarts the account's user manager. This stops and starts every service, fails in-flight requests, and ends `machinectl shell` sessions. It happens on the first run, and on later runs only if that limit file changes.

## Kernel and Firmware Upgrades

The `common` role holds `linux-firmware` and the installed kernel metapackage (the reason is in `roles/common/defaults/main.yml`). To upgrade them:

```bash
apt-mark showhold
sudo apt-mark unhold <packages listed by showhold>
sudo apt full-upgrade
sudo reboot
# then re-run the playbook: it re-applies the hold and checks the GPU and NPU from the containers
```
