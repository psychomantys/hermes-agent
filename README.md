# hermes-agent (extended image)

Docker image based on [`nousresearch/hermes-agent`](https://hub.docker.com/r/nousresearch/hermes-agent)
(built from [NousResearch/hermes-agent `Dockerfile`](https://github.com/NousResearch/hermes-agent/blob/main/Dockerfile))
with extras for local speech-to-text, Cursor as a Hermes provider, and common CLIs.

## What's added

| Area | Packages / tools |
| --- | --- |
| Local STT | `faster-whisper` in the Hermes venv; default `stt.provider: local` |
| Cursor | Cursor Agent CLI (`agent` / `cursor-agent`), bundled `cursor-acp` + `cursor-subscription-directsdk` plugins |
| CLIs | `acli`, `gh`, `jq`, `yq`, `bb`/`bbcli`, `git`, `helm`, `kustomize`, `kubectl`, `pre-commit`, `opencode`, `ffmpeg` (+ extra codecs when available) |

## Build

```bash
docker build -t psycho_mantys/hermes-agent:latest .
# pin upstream:
docker build --build-arg HERMES_TAG=v0.23.1 -t psycho_mantys/hermes-agent:v0.23.1 .
```

## Run

```bash
mkdir -p ~/.hermes
docker compose up -d --build
# or:
docker run -it --rm -v ~/.hermes:/opt/data psycho_mantys/hermes-agent:latest
```

On first start the image seeds Cursor plugins into `$HERMES_HOME/plugins` and
enables local STT defaults when `config.yaml` has no `stt:` block.

## Cursor setup (after first boot)

```bash
# Agent CLI (ACP path)
docker exec -it hermes agent login
docker exec -it hermes hermes plugins enable cursor-acp   # usually already enabled

# DirectSDK provider (uses Cursor plan models inside Hermes' own loop)
docker exec -it hermes hermes auth add cursor-subscription-directsdk
docker exec -it hermes hermes model   # pick "Cursor Subscription (DirectSDK)"
```

Quick checks:

```bash
docker exec -it hermes hermes chat --provider cursor-acp -m composer-2.5 -q 'Reply with exactly: OK'
docker exec -it hermes hermes chat --provider cursor-subscription-directsdk -m composer-2.5 -q 'Reply with exactly: OK'
```

## STT

`faster-whisper` is preinstalled. Defaults (seeded once):

```yaml
stt:
  enabled: true
  provider: local
  local:
    model: base
```

The Whisper model downloads on first use (~150 MB for `base`).

## Tool versions

CLI pins are `ARG`s in the `Dockerfile` (`YQ_VERSION`, `HELM_VERSION`, …).
Bump them there when you want newer releases.

## CI

Tagged releases (`v*.*.*`) build and publish multi-arch images to GHCR via
[`.github/workflows/build.yaml`](.github/workflows/build.yaml):

`ghcr.io/psychomantys/hermes-agent:<tag>`

