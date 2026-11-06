# ollama-think-proxy (Mac mini)

A small HTTP proxy in front of Ollama on the Mac mini (`192.168.1.3`) that sets `"think": false` on every
`/api/chat` and `/api/generate` request and passes everything else (embeddings, `/api/tags`, `/api/version`)
through unchanged. Streamed replies are relayed as they arrive.

**Why.** paperless-ngx 3.4.2 cannot switch thinking off: `PAPERLESS_AI_LLM_EXTRA_PARAMS` ends up in the request's
`options`, where Ollama ignores `think` (it logs `invalid option provided option=think`). gemma4 has thinking on by
default (`ollama show gemma4:26b`: thinking levels `false, true`, default `true`), and the model's prompt comes from
Ollama's built-in `gemma4` renderer, so no Modelfile setting changes it. Measured on the Mac mini on 2026-11-06 with a
suggestion-sized Polish prompt: 20 s and 1508 tokens with thinking, 5 s and 422 tokens without.

| File | What it is |
|---|---|
| `ollama-think-proxy.py` | The proxy. Standard library only, Python 3.7+. `--listen 0.0.0.0:11435 --upstream 127.0.0.1:11434` |
| `pl.sudops.ollama-think-proxy.plist.in` | launchd agent template (`RunAtLoad`, `KeepAlive`) |
| `install.sh` | Copies the script to `~/Library/Application Support/ollama-think-proxy/`, renders the plist into `~/Library/LaunchAgents/`, reloads the agent, checks `:11435` |
| `test_ollama_think_proxy.py` | Tests against a fake Ollama: `python3 -m unittest discover -s macmini/ollama-think-proxy -v` |

The Mac mini is not Ansible-managed; this directory is the source of truth and `install.sh` is the one way to put it
there. Re-run it after any change here.

## Install or update (on the Mac mini)

```bash
bash macmini/ollama-think-proxy/install.sh   # from a checkout of this repo on the Mac mini
```

It ends with `ok: ollama-think-proxy answers on :11435`. macOS may ask once whether python3 may accept incoming
connections: allow it. The agent runs in the logged-in user's session, the same as Ollama itself.

## Check

```bash
# on the Mac mini: thinking requested, still answered in ~5 s
curl -s localhost:11435/api/chat -d '{"model":"gemma4:26b","stream":false,"think":true,"messages":[{"role":"user","content":"Zaproponuj krótki tytuł dla faktury VAT nr 1/03/2025."}]}' \
  | jq -r '"total=\(.total_duration/1e9|floor)s tokens=\(.eval_count) thinking=\(.message.thinking // "" | length)"'
# from TrueNAS: reachable from the paperless side
ssh truenas_admin@192.168.1.25 "curl -s http://192.168.1.3:11435/api/version"
tail ~/Library/Logs/ollama-think-proxy.log   # one line per request; chat/generate show think=false
```

## Remove

```bash
launchctl bootout gui/$(id -u)/pl.sudops.ollama-think-proxy
rm ~/Library/LaunchAgents/pl.sudops.ollama-think-proxy.plist
```

Point `PAPERLESS_AI_LLM_ENDPOINT` back at `:11434` first (`ansible/truenas/group_vars/all.yml`, playbook run).
