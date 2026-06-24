# Local AI Runtimes (MLX)

Reference for the on-device MLX inference servers that back OpenClicky's
`.localOpenAICompatible` provider. Both expose an OpenAI-compatible
`/v1/chat/completions` endpoint, so a `local:<id>` model in
`OpenClickyModelCatalog` routes to `LocalChatCompletionsAPI` against whichever
server is running. Apple Silicon only.

These run on the developer's / user's machine; they are **not** bundled into the
app and not a build dependency. Install them once with `uv`.

## What's installed

Installed as isolated `uv` tools (commands land in `~/.local/bin`):

| Command | Package | Purpose |
| --- | --- | --- |
| `mlx_lm.server` (+ `mlx_lm`, `mlx_lm.generate`, …) | `mlx-lm` (current) | OpenAI-compatible server, single model per process |
| `fastmlx` | `fastmlx` 0.2.1 | Dynamic model load/switch over REST + vision (VLM) models |

`mlx_lm.server` is **not** a separate package — it is a console script shipped
inside `mlx-lm`.

```sh
uv tool install --python 3.12 mlx-lm
# fastmlx: see the pinned command below — do NOT install it unpinned
```

## Quick start

```sh
# Single-model server (downloads the model on first use)
mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit --port 8080

# Dynamic multi-model / VLM server
fastmlx --host 127.0.0.1 --port 8000
```

Point OpenClicky's Local AI endpoint at the matching host/port
(`LocalModelSettingsStore`).

## IMPORTANT: fastmlx is pinned to an old MLX stack — do not upgrade blindly

`fastmlx` 0.2.1 is the latest release and is effectively unmaintained. Its
generation layer is written against mid-2024 MLX APIs that current `mlx-lm` /
`mlx-vlm` have since changed (functions moved modules, signatures changed, and
`stream_generate` now yields objects instead of plain strings). Installing it
against the current MLX stack makes it load-crash (`NameError: vlm_models`) or
fail on the first inference.

So `fastmlx` is installed in its **own** isolated venv pinned to the contemporary
stack it was built for. The standalone `mlx-lm` tool stays current and is
unaffected — the two venvs are independent.

Reinstall / repair command (re-run this exactly if fastmlx ever breaks):

```sh
uv tool install --force --python 3.12 "fastmlx==0.2.1" \
  --with "mlx-lm==0.16.1" \
  --with "mlx-vlm==0.0.12" \
  --with "transformers==4.44.2" \
  --with "huggingface-hub==0.24.6"
```

Pinned set (resolved): `fastmlx 0.2.1`, `mlx-lm 0.16.1`, `mlx-vlm 0.0.12`,
`transformers 4.44.2`, `huggingface-hub 0.24.6`, `tokenizers 0.19.1`,
`numpy 2.2.6`, Python 3.12. The `huggingface-hub` pin matters: transformers
4.44.2 imports `huggingface_hub.utils._errors`, which newer hub releases removed.

### Do NOT run `uv tool upgrade fastmlx`

`fastmlx`'s declared bounds are open (`mlx-lm>=0.15.2`, `mlx-vlm>=0.0.12`, no
upper cap), so an upgrade re-pulls the latest incompatible MLX and re-breaks it.
If that happens, re-run the pinned command above.

If you only need text chat (no dynamic switching / vision), prefer
`mlx_lm.server` — it is current, simpler, and serves the same
`/v1/chat/completions` API.
