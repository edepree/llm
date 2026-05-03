# llm

```
./run
```

Prompts for the target endpoint. Use a hostname/IP for remote (requires SSH + sudo password) or `localhost` to run directly on the host (sudo password only).

To pre-download all enabled models after provisioning:

```
uv run --no-lock ansible-playbook warm-cache.yml -i host.example.com,
```
