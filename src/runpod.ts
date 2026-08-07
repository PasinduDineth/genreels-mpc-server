import { config } from "./config.js";
import { logger } from "./logger.js";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type Mode = "off" | "tts" | "video";

export type ControlStatus = {
  active_mode?: string;
  actual_mode?: string;
  transitioning?: boolean;
  target_mode?: string | null;
  stage?: string;
  last_error?: string | null;
  [key: string]: unknown;
};

export type VideoStartResult = {
  accepted: boolean;
  job_id: string;
  status: string;
  model?: string;
  backend?: string;
  status_url: string;
};

export type VideoJobResult = {
  job_id: string;
  status: "queued" | "processing" | "completed" | "failed" | string;
  stage?: string;
  url?: string;
  error?: string;
  error_tail?: string;
  duration_seconds?: number;
  generation_seconds?: number;
  width?: number;
  height?: number;
  fps?: number;
  seed?: number;
  [key: string]: unknown;
};

export type SpeechGenerationResult = {
  bytes: Uint8Array;
  mimeType: string;
  format: "wav";
  voice: string;
  audioUrl?: string;
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function internalAbsoluteUrl(pathOrUrl: string): string {
  if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl;
  return `${config.RUNPOD_BASE_URL}${pathOrUrl.startsWith("/") ? "" : "/"}${pathOrUrl}`;
}

function publicAbsoluteUrl(pathOrUrl: string): string {
  if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl;
  const baseUrl = config.RUNPOD_PUBLIC_BASE_URL ?? config.RUNPOD_BASE_URL;
  return `${baseUrl}${pathOrUrl.startsWith("/") ? "" : "/"}${pathOrUrl}`;
}

function isPrivateIp(address: string): boolean {
  if (isIP(address) === 4) {
    const [a, b] = address.split(".").map(Number);
    return (
      a === 10 || a === 127 || a === 0 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168)
    );
  }
  const normalized = address.toLowerCase();
  return normalized === "::1" || normalized === "::" || normalized.startsWith("fc") ||
    normalized.startsWith("fd") || normalized.startsWith("fe8") || normalized.startsWith("fe9") ||
    normalized.startsWith("fea") || normalized.startsWith("feb");
}

function isTrustedOpenAiFileHost(hostname: string): boolean {
  return hostname.toLowerCase() === "files.oaiusercontent.com";
}

async function validateRemoteImageUrl(url: URL): Promise<void> {
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("Input image URL must use HTTP or HTTPS");
  }
  // ChatGPT fileParams supplies a short-lived signed HTTPS URL on this
  // OpenAI-controlled host. In some RunPod environments its DNS is routed
  // through a private address, so the general SSRF DNS check would reject it.
  if (url.protocol === "https:" && isTrustedOpenAiFileHost(url.hostname)) return;
  const addresses = await lookup(url.hostname, { all: true });
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateIp(address))) {
    throw new Error("Input image URL resolves to a private or local network address");
  }
}

async function request(
  path: string,
  init: RequestInit = {},
  timeoutMs = config.RUNPOD_REQUEST_TIMEOUT_MS,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const requestId = crypto.randomUUID();
  const started = Date.now();

  const headers = new Headers(init.headers);
  logger.info({ requestId, method: init.method ?? "GET", path }, "RunPod request started");

  try {
    const response = await fetch(internalAbsoluteUrl(path), {
      ...init,
      headers,
      signal: controller.signal,
    });

    logger.info(
      {
        requestId,
        method: init.method ?? "GET",
        path,
        status: response.status,
        durationMs: Date.now() - started,
      },
      "RunPod request completed",
    );

    return response;
  } catch (error) {
    logger.error(
      { requestId, method: init.method ?? "GET", path, durationMs: Date.now() - started, err: error },
      "RunPod request failed",
    );
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function jsonOrThrow<T>(response: Response, context: string): Promise<T> {
  const text = await response.text();
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = text;
  }

  if (!response.ok) {
    throw new Error(`${context} failed (${response.status}): ${typeof body === "string" ? body : JSON.stringify(body)}`);
  }
  return body as T;
}

export async function health(): Promise<Record<string, unknown>> {
  const response = await request("/health", {}, 15_000);
  return jsonOrThrow(response, "RunPod health check");
}

export async function getStatus(): Promise<ControlStatus> {
  const response = await request("/control/status", {}, 15_000);
  return jsonOrThrow(response, "RunPod status");
}

export async function ensureMode(mode: Exclude<Mode, "off">): Promise<ControlStatus> {
  const initial = await getStatus();
  const currentMode = String(initial.actual_mode ?? initial.active_mode ?? "unknown");

  if (currentMode === mode && !initial.transitioning) {
    logger.info({ mode }, "Requested GPU mode is already ready");
    return initial;
  }

  logger.info({ from: currentMode, to: mode }, "Starting GPU mode transition");
  const startResponse = await request(`/control/${mode}/start`, { method: "POST" }, 30_000);
  await jsonOrThrow(startResponse, `Start ${mode} mode`);

  const deadline = Date.now() + config.MODE_SWITCH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const status = await getStatus();
    const actualMode = String(status.actual_mode ?? status.active_mode ?? "unknown");

    logger.debug(
      {
        requestedMode: mode,
        actualMode,
        transitioning: status.transitioning,
        stage: status.stage,
        targetMode: status.target_mode,
      },
      "GPU mode transition status",
    );

    if (status.last_error) {
      throw new Error(`GPU mode transition failed: ${String(status.last_error)}`);
    }
    if (actualMode === mode && !status.transitioning) {
      logger.info({ mode }, "GPU mode is ready");
      return status;
    }
    await sleep(config.MODE_POLL_INTERVAL_MS);
  }

  throw new Error(`Timed out waiting for GPU mode '${mode}' after ${config.MODE_SWITCH_TIMEOUT_MS} ms`);
}

export async function generateSpeech(input: {
  text: string;
  voice?: string;
  language?: string;
  instructions?: string;
  speed?: number;
}): Promise<SpeechGenerationResult> {
  await ensureMode("tts");

  const voice = input.voice?.trim() || "Ryan";
  const language = input.language?.trim() || "English";
  const instructions = input.instructions?.trim();
  const response = await request(
    "/v1/audio/speech",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: language.toLowerCase() === "english" ? "tts-1-en" : "tts-1",
        voice,
        language,
        ...(instructions ? { instruct: instructions } : {}),
        input: input.text,
        response_format: "wav",
        speed: input.speed ?? 1,
      }),
    },
    config.MODE_SWITCH_TIMEOUT_MS,
  );

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Speech generation failed (${response.status}): ${body}`);
  }

  const contentType = response.headers.get("content-type")?.split(";", 1)[0] || "audio/wav";
  if (!contentType.startsWith("audio/") && contentType !== "application/octet-stream") {
    throw new Error(`Speech generation returned an unexpected content type: ${contentType}`);
  }

  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error("Speech generation returned an empty audio file");

  await mkdir(config.AUDIO_OUTPUT_DIR, { recursive: true });
  const filename = `${Date.now()}-${crypto.randomUUID()}.wav`;
  const outputPath = path.join(config.AUDIO_OUTPUT_DIR, filename);
  await writeFile(outputPath, bytes);
  const audioUrl = config.MCP_PUBLIC_BASE_URL
    ? `${config.MCP_PUBLIC_BASE_URL}/files/generated/audio/${encodeURIComponent(filename)}`
    : undefined;

  logger.info(
    { voice, language, hasInstructions: Boolean(instructions), byteLength: bytes.byteLength, contentType, outputPath, audioUrl },
    "Speech generated",
  );
  return {
    bytes,
    mimeType: contentType === "application/octet-stream" ? "audio/wav" : contentType,
    format: "wav",
    voice,
    audioUrl,
  };
}

async function fetchImageBytes(imageUrl: string): Promise<{ bytes: Uint8Array; contentType: string; filename: string }> {
  const localPath = resolveLocalImagePath(imageUrl);
  if (localPath) {
    const bytes = new Uint8Array(await readFile(localPath));
    const filename = path.basename(localPath) || "input.png";
    return { bytes, contentType: inferImageContentType(filename), filename };
  }

  let url = new URL(internalAbsoluteUrl(imageUrl));
  let response: Response | undefined;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.REMOTE_IMAGE_TIMEOUT_MS);
  try {
    for (let redirects = 0; redirects <= 3; redirects += 1) {
      await validateRemoteImageUrl(url);
      response = await fetch(url, { redirect: "manual", signal: controller.signal });
      if (response.status >= 300 && response.status < 400) {
        const location = response.headers.get("location");
        if (!location || redirects === 3) throw new Error("Input image URL has too many or invalid redirects");
        url = new URL(location, url);
        continue;
      }
      break;
    }
    if (!response?.ok) throw new Error(`Failed to download input image (${response?.status ?? "no response"})`);
    const declaredSize = Number(response.headers.get("content-length") ?? 0);
    if (declaredSize > config.REMOTE_IMAGE_MAX_BYTES) throw new Error("Input image exceeds the configured size limit");
    const contentType = response.headers.get("content-type")?.split(";", 1)[0] ?? "";
    if (!contentType.startsWith("image/")) throw new Error(`Input URL did not return an image (${contentType || "unknown content type"})`);
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Input image response had no body");
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > config.REMOTE_IMAGE_MAX_BYTES) {
        await reader.cancel();
        throw new Error("Input image exceeds the configured size limit");
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const pathname = url.pathname;
    const filename = pathname.split("/").pop() || "input.png";
    return { bytes, contentType, filename };
  } finally {
    clearTimeout(timeout);
  }
}

function resolveLocalImagePath(imageUrl: string): string | null {
  if (imageUrl.startsWith("file://")) {
    const filePath = fileURLToPath(imageUrl);
    if (path.isAbsolute(filePath)) return filePath;
    return null;
  }
  if (path.isAbsolute(imageUrl)) return imageUrl;
  return null;
}

function inferImageContentType(filename: string): string {
  const ext = path.extname(filename).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".png") return "image/png";
  if (ext === ".webp") return "image/webp";
  if (ext === ".gif") return "image/gif";
  if (ext === ".bmp") return "image/bmp";
  if (ext === ".tif" || ext === ".tiff") return "image/tiff";
  return "application/octet-stream";
}

export async function startVideo(input: {
  imageUrl: string;
  prompt: string;
  steps?: 4 | 8 | 12;
  numFrames?: number;
  fps?: number;
  seed?: number;
}): Promise<VideoStartResult & { status_url_absolute: string }> {
  const image = await fetchImageBytes(input.imageUrl);
  await ensureMode("video");

  const form = new FormData();
  const imageBuffer = image.bytes.buffer.slice(
    image.bytes.byteOffset,
    image.bytes.byteOffset + image.bytes.byteLength,
  ) as ArrayBuffer;
  form.append("image", new Blob([imageBuffer], { type: image.contentType }), image.filename);
  form.append("prompt", input.prompt);
  form.append("width", "480");
  form.append("height", "832");
  form.append("num_frames", String(input.numFrames ?? 121));
  form.append("fps", String(input.fps ?? 24));
  form.append("steps", String(input.steps ?? 8));
  form.append("guidance_scale", "1.0");
  if (input.seed !== undefined) form.append("seed", String(input.seed));

  const response = await request(
    "/v1/videos/generations",
    { method: "POST", body: form },
    90_000,
  );
  const result = await jsonOrThrow<VideoStartResult>(response, "Video generation submission");
  if (!result.job_id || !result.status_url) throw new Error("Video API response missing job_id/status_url");

  const statusUrl = publicAbsoluteUrl(result.status_url);
  logger.info({ jobId: result.job_id, status: result.status, statusUrl }, "Video job accepted");
  return { ...result, status_url_absolute: statusUrl };
}

export async function getVideoJob(jobId: string): Promise<VideoJobResult & { video_url?: string }> {
  const response = await request(`/v1/videos/jobs/${encodeURIComponent(jobId)}`, {}, 30_000);
  const result = await jsonOrThrow<VideoJobResult>(response, "Video job status");
  return {
    ...result,
    ...(result.url ? { video_url: publicAbsoluteUrl(result.url) } : {}),
  };
}

export async function waitForVideo(jobId: string): Promise<VideoJobResult & { video_url: string }> {
  const deadline = Date.now() + config.VIDEO_POLL_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const job = await getVideoJob(jobId);
    logger.info({ jobId, status: job.status, stage: job.stage }, "Video job status");

    if (job.status === "completed") {
      if (!job.video_url) throw new Error("Video completed but no output URL was returned");
      return job as VideoJobResult & { video_url: string };
    }
    if (job.status === "failed") {
      throw new Error(`Video generation failed: ${job.error ?? "unknown error"}`);
    }
    await sleep(config.VIDEO_POLL_INTERVAL_MS);
  }

  throw new Error(`Timed out waiting for video job '${jobId}' after ${config.VIDEO_POLL_TIMEOUT_MS} ms`);
}


