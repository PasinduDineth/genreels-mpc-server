# RunPod AI MCP Server

A local-first, production-style Model Context Protocol (MCP) server that exposes your existing RunPod AI gateway to ChatGPT.

## What it exposes

- `get_runpod_status` — read-only health/status check.
- `generate_speech` — switches to TTS mode, saves a WAV, and returns a public downloadable audio URL.
- `generate_video_from_image` — accepts a ChatGPT-generated/uploaded image or downloads a public image URL, switches to video mode, submits a 5-second HunyuanVideo job, and returns a job ID.
- `check_video_job` — read-only job polling; returns `video_url` when completed.
- `generate_video_and_wait` — backward-compatible asynchronous alias that returns a job ID immediately.

## Architecture

ChatGPT -> HTTPS -> RunPod gateway/MCP -> Qwen3-TTS or HunyuanVideo

The MCP server runs locally. Your GPU workloads remain on RunPod.

## Prerequisites

- Node.js 20+ (Node 22 recommended)
- A running RunPod pod with your `run_pod_config.sh` gateway available on port 8000
- The RunPod public proxy URL, for example `https://<pod-id>-8000.proxy.runpod.net`

## 1. Configure

```bash
cp .env.example .env
```

Set:

```dotenv
RUNPOD_BASE_URL=https://YOUR_POD_ID-8000.proxy.runpod.net
```

## 2. Install and run locally

```bash
npm install
npm run typecheck
npm run dev
```

### Run MCP automatically on the RunPod pod

Push this project to GitHub, then set these environment variables once in the
RunPod template or pod:

```dotenv
MCP_REPO_URL=https://github.com/YOUR_ACCOUNT/runpod-mcp-server.git
MCP_BRANCH=main
MCP_ENABLED=true
MCP_PORT=8787
```

For a private repository, configure a read-only Git deploy key on the pod.
Do not put a GitHub token directly in `run_pod_config.sh`.

If you clone this complete repository onto RunPod and execute its
`run_pod_config.sh`, no repository setting is required: the script detects,
builds, and starts the MCP project beside it. `MCP_REPO_URL` is only needed
when you upload the shell script by itself and want it to clone the project,
or when you want each run to fetch the configured branch automatically.

For RunPod, MCP is forwarded through the primary FastAPI gateway because some
RunPod proxy routes reject POST requests sent directly to secondary ports.
Use the neutral `/connector` alias. It avoids upstream platforms that reserve
or filter the literal `/mcp` path:

```text
https://<pod-id>-<gateway-port>.proxy.runpod.net/connector
```

Port `8787` remains the internal/direct MCP service and can still be used for
local diagnostics.

Expected startup log:

```text
RunPod AI MCP server started
mcpUrl: http://localhost:8787/mcp
```

Check local service health:

```bash
curl http://localhost:8787/
curl http://localhost:8787/healthz
```

`/healthz` also calls the upstream RunPod `/health` endpoint.

## 3. Test with MCP Inspector first

```bash
npx @modelcontextprotocol/inspector@latest \
  --server-url http://localhost:8787/mcp \
  --transport http
```

Recommended test order:

1. `get_runpod_status`
2. `generate_speech` with a short line of text
3. `generate_video_from_image` with the generated/uploaded ChatGPT image (preferred) or a public image URL, plus a motion prompt
4. Copy `job_id`
5. Repeatedly call `check_video_job` until `status` is `completed`
6. Open `video_url`

`generate_video_and_wait` is retained as a backward-compatible alias, but it also returns immediately. Poll `check_video_job` for the final result.

Video tools accept `num_frames` and `fps`. Frame counts must follow `4n + 1`:

- Fast 5 seconds: `num_frames: 61`, `fps: 12`, `steps: 4`
- Balanced 5 seconds: `num_frames: 81`, `fps: 16`
- Quality 5 seconds: `num_frames: 121`, `fps: 24`

The video backend accepts 25–121 frames (following `4n + 1`) and 8–24 FPS; duration is determined by the selected frame count and FPS.

The persistent HunyuanVideo pipeline remains loaded after a job completes. It unloads only when switching to TTS/off mode or restarting the video service.

## 4. Connect the local server to ChatGPT

ChatGPT cannot reach `localhost` directly. Keep this MCP server local and expose it temporarily through HTTPS.

### Option A: ngrok

```bash
ngrok http 8787
```

You will get a URL similar to:

```text
https://abc123.ngrok.app
```

Your MCP endpoint is:

```text
https://abc123.ngrok.app/mcp
```

### Option B: Cloudflare Tunnel

Use a Cloudflare tunnel that forwards HTTPS traffic to `http://localhost:8787`, then append `/mcp` to the generated HTTPS hostname.

## 5. Add the MCP app in ChatGPT

1. Open ChatGPT on the web.
2. Go to **Settings -> Security and login -> Developer mode** and enable it.
3. Go to **Settings -> Plugins** (or the developer-mode app management page).
4. Create a new developer-mode app.
5. Name: `RunPod AI Studio`.
6. Description: `Generates Qwen3-TTS speech and 5-second HunyuanVideo clips using my RunPod GPU.`
7. MCP URL: `https://YOUR_TUNNEL_HOST/mcp`.
8. Create the app and verify the advertised tools appear.
9. Start a new chat, add the app from the `+` / More menu, and test it.

Suggested first prompt:

```text
Use my RunPod AI Studio app. First check the RunPod status. Then generate an image of a cinematic futuristic city at sunset. Return the image URL.
```

Then:

```text
Use the image you just generated as the starting frame. Create a 5-second video where the camera slowly moves forward, lights flicker naturally, and clouds drift. Submit the job and tell me the job ID.
```

Then:

```text
Check that video job. If it is complete, give me the final MP4 URL.
```

For a one-call test:

```text
Generate an image first, then use generate_video_and_wait to create the final 5-second MP4 from it.
```

## Logs

Logs are structured with Pino and include:

- MCP/HTTP request IDs
- tool invocation names
- RunPod request paths and response status
- request duration
- GPU mode transitions
- video job ID/status/stage
- failures with stack/context

Set verbosity in `.env`:

```dotenv
LOG_LEVEL=debug
```

Use `debug` while integrating; use `info` normally.

## Important behavior

### Single GPU mode switching

Your RunPod gateway uses mutually exclusive GPU modes. The MCP server never assumes a mode is ready immediately. It:

1. calls `/control/<mode>/start`
2. polls `/control/status`
3. waits until the requested mode is active and transitions finish
4. only then invokes image/video generation

### Image response

The gateway returns an image response containing `data[0].url`. The MCP server converts that relative URL into an absolute RunPod URL before returning it to ChatGPT.

### Video response

Video submission is asynchronous. The gateway returns `job_id` and `status_url`. The MCP server exposes both an asynchronous tool pair and a convenience wait-until-complete tool.

## Network access

The gateway and MCP endpoint do not require authentication. Anyone with the
RunPod proxy URLs can invoke them and consume GPU resources, so keep the URLs
private.

## Troubleshooting

### `RUNPOD_BASE_URL` validation error

Set a complete URL beginning with `https://` in `.env`.

### `503 ... mode is not ready`

The server should normally prevent this by polling. Set `LOG_LEVEL=debug` and inspect mode transition logs.

### Video polling returns 503 after switching modes

Your gateway only guarantees video job metadata while video mode remains active. Do not switch to TTS mode while a video job is running or before retrieving its completed job state.

### ChatGPT cannot connect

Verify:

```bash
curl https://YOUR_TUNNEL_HOST/
```

and test the MCP endpoint with Inspector through the tunnel:

```bash
npx @modelcontextprotocol/inspector@latest \
  --server-url https://YOUR_TUNNEL_HOST/mcp \
  --transport http
```

Then refresh the app metadata in ChatGPT.
