# Usage

Caddy on port 80 is the only entry point. Point DNS for `proxy_webui_host` and `proxy_router_host` (`roles/proxy/defaults/main.yml`) at the target. The web UI host goes to Open WebUI; every other name and the bare IP go to Bifrost. HTTP only, and the API and Open WebUI have no key or login, so use them only on a trusted network.

## API

The OpenAI-compatible API is at `http://<target>/v1`. Model IDs are `<bifrost provider>/<backend model>`:

| Endpoint | Model |
|----------|-------|
| `/v1/chat/completions`, `/v1/completions` | `llamacpp/<preset>`, a key of `inference_presets` in `roles/inference/defaults/main.yml` |
| `/v1/audio/transcriptions` | `flm/whisper-v3` |
| `/v1/audio/speech` | `kokoro/kokoro` |

`curl http://<target>/v1/models` lists only the `llamacpp/` models. The speech models are left out of the list but still work when called by name.

```bash
curl http://<target>/v1/audio/transcriptions -F file=@clip.wav -F model=flm/whisper-v3 -F language=en
curl http://<target>/v1/audio/speech -H 'Content-Type: application/json' -o reply.wav \
  -d '{"model": "kokoro/kokoro", "input": "The lights are off.", "voice": "af_heart", "response_format": "wav"}'
```

- **Chat:** at most `inference_models_max` models are loaded at once. A request for another model unloads the least recently used idle model, and the first request after that waits for the load.
- **Speech-to-text:** set `language` when you know it. Without it, Whisper detects the language and can add made-up text at trailing silence. Requests run one at a time, and a short command takes about 2 s because Whisper always processes a 30 s window. Long audio is limited by Bifrost's upload size and by `router_stt_timeout` (see `roles/router/defaults/main.yml`); use a compressed format (ogg, mp3) rather than WAV.
- **Text-to-speech:** `voice` takes a [Kokoro voice](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) or an OpenAI voice name (`alloy`, `nova`, …), which Kokoros maps to a Kokoro voice. `model` is ignored. Requests run one at a time.

The Bifrost dashboard at `http://<target>/` shows request logs, including Open WebUI's. Log in as `admin` with the password in `credentials/bifrost-admin` on the machine that ran the playbook.

## Open WebUI

Open `http://<proxy_webui_host>`. Everyone on the network shares one user and one chat history. The connection to Bifrost is stored in Open WebUI's database on first start; change it later under Admin Settings → Connections.

## Home Assistant

Home Assistant's built-in **OpenAI** integration handles speech-to-text and text-to-speech. The integration has no base URL setting, but its OpenAI client library reads `OPENAI_BASE_URL` from the environment. Home Assistant does not support this, so check it again after Home Assistant upgrades.

1. Set the environment variable on the Home Assistant container and restart it. On Kubernetes, in the pod spec:

   ```yaml
   env:
     - name: OPENAI_BASE_URL
       value: "http://<target>/v1"
   ```

2. Under Settings → Devices & services, add the **OpenAI** integration. Enter any API key: Bifrost ignores it, but the field is required.
3. In the integration's **OpenAI STT** entry, type `flm/whisper-v3` as the model. The dropdown accepts a custom value.
4. Add the integration's **OpenAI TTS** entry. It always requests `gpt-4o-mini-tts`, which Bifrost sends to Kokoros, its only speech provider. Pick the voice in the Assist pipeline.
5. Select both entities in an Assist pipeline.

The variable applies to the whole Home Assistant process: every OpenAI-based integration without its own base URL calls Bifrost. The conversation agent the integration creates defaults to an OpenAI model that Bifrost does not have. Ignore it, or set it to a `llamacpp/` model.

The `router` role's "Verify STT via Router" task sends the same request Home Assistant sends.
