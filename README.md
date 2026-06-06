sudo systemctl --user --machine=llm@ status llamacpp-qwen-36-reasoning
sudo systemctl --user --machine=llm@ status litellm

sudo -iu llm
journalctl --user -u llamacpp-qwen-36-reasoning -b --no-pager
journalctl --user -u litellm -b --no-pager
