import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { config } from "./config.js";
import { logger } from "./logger.js";
import { generateSpeech, getStatus, getVideoJob, health, startVideo } from "./runpod.js";
import { getComposeJob, submitComposeJob } from "./remotion.js";

const MCP_PATH = "/mcp";
const MCP_ALTERNATE_PATH = "/api/mcp";
const MCP_CONNECTOR_PATH = "/connector";
const MCP_POST_PATHS = new Set(["/", MCP_PATH, MCP_ALTERNATE_PATH, MCP_CONNECTOR_PATH]);
const activeVideoJobs = new Set<string>();
let generationOperationInProgress = false;

async function refreshActiveVideoJobs(): Promise<string[]> {
  try {
    const entries = await readdir(config.VIDEO_JOB_DIR, { withFileTypes: true });
    const persistedActiveJobs = new Set<string>();
    await Promise.all(
      entries
        .filter((entry) => entry.isFile() && /^[0-9a-f]{32}\.json$/.test(entry.name))
        .map(async (entry) => {
          try {
            const job = JSON.parse(await readFile(path.join(config.VIDEO_JOB_DIR, entry.name), "utf8")) as {
              job_id?: unknown;
              status?: unknown;
            };
            if (typeof job.job_id === "string" && (job.status === "queued" || job.status === "processing")) {
              persistedActiveJobs.add(job.job_id);
            }
          } catch (error) {
            logger.warn({ err: error, file: entry.name }, "Could not read persisted video job state");
          }
        }),
    );
    activeVideoJobs.clear();
    for (const jobId of persistedActiveJobs) activeVideoJobs.add(jobId);
  } catch (error) {
    const code = error instanceof Error && "code" in error ? String(error.code) : "";
    if (code !== "ENOENT") logger.warn({ err: error }, "Could not refresh persisted video jobs");
  }
  return [...activeVideoJobs];
}

type OpenAiFileParam = {
  download_url?: string;
  file_id?: string;
  mime_type?: string;
  file_name?: string;
};

const openAiImageFileSchema = z.union([
  z.object({
    download_url: z.string().url().describe("Temporary HTTPS download URL supplied by ChatGPT."),
    file_id: z.string().optional().describe("Stable ChatGPT file identifier."),
    mime_type: z.string().optional().describe("Image MIME type."),
    file_name: z.string().optional().describe("Original image filename."),
  }).passthrough(),
  z.string().describe("ChatGPT platform file reference; the client replaces this with a downloadable file object."),
]).optional().describe("ChatGPT-generated or uploaded source image. Use this for an image available in the conversation.");

const captionSchema = z.object({
  text: z.string(),
  startMs: z.number(),
  endMs: z.number(),
  timestampMs: z.number().optional(),
  confidence: z.number().optional(),
});

const videoFrameCountSchema = z.number().int().min(25).max(121).refine((value) => (value - 1) % 4 === 0, "num_frames must follow 4n + 1").default(121).describe("Number of generated frames. Must follow 4n + 1. Use 61 with 12 FPS for a fast 5-second clip, 81 with 16 FPS for balanced, or 121 with 24 FPS for quality.");

const videoFpsSchema = z.number().int().min(8).max(24).default(24).describe("Output frames per second. Approximate duration is (num_frames - 1) / fps seconds.");

function getVideoImageUrl(args: { image_url?: string; image_file?: unknown }): { imageUrl: string; source: "url" | "chatgpt_file"; fileId?: string } {
  if (args.image_file !== undefined && args.image_file !== null) {
    if (typeof args.image_file === "string") {
      throw new Error("ChatGPT passed an unresolved local file reference instead of a downloadable file object. Refresh or recreate the connector, reattach the image, and try again.");
    }
    if (typeof args.image_file !== "object" || Array.isArray(args.image_file)) {
      throw new Error("ChatGPT did not provide a usable image file reference. Refresh or recreate the connector, reattach the image, and try again.");
    }
    const file = args.image_file as OpenAiFileParam;
    if (!file.download_url || !URL.canParse(file.download_url)) {
      throw new Error("The image file reference does not contain a valid temporary download URL. Reattach the image and try again.");
    }
    if (file.mime_type && !file.mime_type.toLowerCase().startsWith("image/")) {
      throw new Error(`The attached file is not an image (${file.mime_type}).`);
    }
    return { imageUrl: file.download_url, source: "chatgpt_file", ...(file.file_id ? { fileId: file.file_id } : {}) };
  }
  if (args.image_url) return { imageUrl: args.image_url, source: "url" };
  throw new Error("Provide either image_file (a ChatGPT-generated/uploaded image) or image_url (a public HTTPS image URL).");
}

function textResult(message: string, structuredContent: Record<string, unknown>) {
  return {
    content: [{ type: "text" as const, text: message }],
    structuredContent,
  };
}

function errorResult(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  logger.error({ err: error }, "MCP tool failed");
  return {
    isError: true,
    content: [{ type: "text" as const, text: message }],
    structuredContent: { ok: false, error: message },
  };
}

function createMcpServer(): McpServer {
  const server = new McpServer(
    { name: "runpod-ai-studio", version: "1.6.0" },
    {
      instructions:
        "Use get_runpod_status before diagnosing availability or to recover active video job IDs. generate_speech creates Qwen3-TTS audio. generate_video_from_image submits a 5-second portrait video job from a ChatGPT-generated/uploaded image or a public image URL and immediately returns a job ID. Poll check_video_job with that ID until completion. generate_video_and_wait is a backward-compatible asynchronous alias and also returns immediately; no video tool waits inside one MCP request. compose_video_story assembles clips, narration, music, and optional captions into a 9:16 Remotion render and returns a job ID immediately.",
    },
  );

  server.registerTool(
    "generate_speech",
    {
      title: "Generate speech with Qwen3-TTS",
      description:
        "Convert text to spoken WAV audio using Qwen3-TTS on RunPod. This automatically switches the single GPU into TTS mode and returns playable audio.",
      inputSchema: {
        text: z.string().min(1).max(1500).describe("Text to synthesize as speech."),
        voice: z.string().min(1).max(100).default("Ryan").describe("Qwen3-TTS voice name, such as Ryan."),
        language: z.string().min(1).max(50).default("English").describe("Spoken language, such as English."),
        instructions: z.string().min(1).max(2000).default("Speak clearly and naturally with consistent tone, energy, volume, and rhythm. Use smooth transitions and short pauses without adding silence between paragraphs.").describe("Natural-language direction for voice style, emotion, pacing, pauses, and delivery."),
        speed: z.number().min(0.25).max(4).default(1).describe("Speech speed multiplier."),
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        await refreshActiveVideoJobs();
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) {
          throw new Error("Cannot switch to TTS mode while a video job is active. Check the video job until it completes or fails.");
        }
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        logger.info({ tool: "generate_speech", voice: args.voice, language: args.language, instructionsLength: args.instructions.length, textLength: args.text.length }, "MCP tool invoked");
        const result = await generateSpeech({ text: args.text, voice: args.voice, language: args.language, instructions: args.instructions, speed: args.speed });
        const data = Buffer.from(result.bytes).toString("base64");
        return { content: [{ type: "text" as const, text: result.audioUrl ? `Speech generated successfully with voice ${result.voice}: ${result.audioUrl}` : `Speech generated successfully with voice ${result.voice}.` }, { type: "audio" as const, data, mimeType: result.mimeType }], structuredContent: { ok: true, type: "audio", format: result.format, mime_type: result.mimeType, voice: result.voice, byte_length: result.bytes.byteLength, ...(result.audioUrl ? { audio_url: result.audioUrl } : {}) } };
      } catch (error) {
        return errorResult(error);
      } finally {
        if (acquiredGenerationLock) generationOperationInProgress = false;
      }
    },
  );

  server.registerTool(
    "get_runpod_status",
    {
      title: "Get RunPod AI status",
      description: "Read-only. Use this to check whether the RunPod gateway is reachable and see the current GPU mode before diagnosing generation problems.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => {
      try {
        const activeJobIds = await refreshActiveVideoJobs();
        const [healthResult, status] = await Promise.all([health(), getStatus()]);
        return textResult(activeJobIds.length > 0 ? `RunPod gateway is reachable. Active video job IDs: ${activeJobIds.join(", ")}` : "RunPod gateway is reachable. There are no MCP-tracked active video jobs.", { ok: true, health: healthResult, status, active_video_job_ids: activeJobIds });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "generate_video_from_image",
    {
      title: "Generate 5-second video from image",
      description:
        "Submit a HunyuanVideo image-to-video job using a ChatGPT-generated/uploaded image or a publicly reachable image URL. Prefer image_file for an image created or attached in this chat. Use this for a 5-second 480x832 portrait clip. The tool switches the GPU into video mode and returns immediately with a job ID; call check_video_job afterward.",
      inputSchema: { image_file: openAiImageFileSchema, image_url: z.string().url().optional().describe("Publicly reachable source image URL. Use only when no ChatGPT image file is available."), prompt: z.string().min(1).max(4000).describe("Motion/camera prompt describing how the input image should animate."), steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8), num_frames: videoFrameCountSchema, fps: videoFpsSchema, seed: z.number().int().nonnegative().optional() },
      _meta: { "openai/fileParams": ["image_file"] },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        await refreshActiveVideoJobs();
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        const image = getVideoImageUrl(args);
        logger.info({ tool: "generate_video_from_image", imageSource: image.source, fileId: image.fileId, steps: args.steps, numFrames: args.num_frames, fps: args.fps }, "MCP tool invoked");
        const result = await startVideo({ imageUrl: image.imageUrl, prompt: args.prompt, steps: args.steps, numFrames: args.num_frames, fps: args.fps, seed: args.seed });
        activeVideoJobs.add(result.job_id);
        return textResult(`Video job accepted. Job ID: ${result.job_id}`, { ok: true, type: "video_job", ...result });
      } catch (error) {
        return errorResult(error);
      } finally {
        if (acquiredGenerationLock) generationOperationInProgress = false;
      }
    },
  );

  server.registerTool(
    "check_video_job",
    {
      title: "Check video generation job",
      description:
        "Read-only. Check a previously submitted HunyuanVideo job. Use the job_id returned by generate_video_from_image. When completed, the response contains video_url.",
      inputSchema: { job_id: z.string().regex(/^[0-9a-f]{32}$/).describe("32-character hexadecimal video job ID.") },
      annotations: { readOnlyHint: true },
    },
    async ({ job_id }) => {
      try {
        const result = await getVideoJob(job_id);
        if (result.status === "completed" || result.status === "failed") activeVideoJobs.delete(job_id);
        const message = result.status === "completed" ? `Video completed: ${result.video_url}` : result.status === "failed" ? `Video failed: ${result.error ?? "unknown error"}` : `Video is ${result.status}${result.stage ? ` (${result.stage})` : ""}.`;
        return textResult(message, { ok: result.status !== "failed", type: "video_job", ...result });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "generate_video_and_wait",
    {
      title: "Generate 5-second video from image",
      description:
        "Backward-compatible alias for generate_video_from_image. It still returns immediately with a job ID and does not wait for completion.",
      inputSchema: { image_file: openAiImageFileSchema, image_url: z.string().url().optional(), prompt: z.string().min(1).max(4000), steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8), num_frames: videoFrameCountSchema, fps: videoFpsSchema, seed: z.number().int().nonnegative().optional() },
      _meta: { "openai/fileParams": ["image_file"] },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        await refreshActiveVideoJobs();
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        const image = getVideoImageUrl(args);
        logger.info({ tool: "generate_video_and_wait", imageSource: image.source, fileId: image.fileId, steps: args.steps, numFrames: args.num_frames, fps: args.fps }, "MCP tool invoked");
        const submitted = await startVideo({ imageUrl: image.imageUrl, prompt: args.prompt, steps: args.steps, numFrames: args.num_frames, fps: args.fps, seed: args.seed });
        activeVideoJobs.add(submitted.job_id);
        return textResult(`Video job accepted. Job ID: ${submitted.job_id}. Poll check_video_job until it completes.`, { ok: true, type: "video_job", ...submitted });
      } catch (error) {
        return errorResult(error);
      } finally {
        if (acquiredGenerationLock) generationOperationInProgress = false;
      }
    },
  );

  server.registerTool(
    "compose_video_story",
    {
      title: "Compose 9:16 narrative short",
      description:
        "Assemble multiple generated clips, optional narration, optional captions, and optional music into a single 9:16 TikTok-style MP4 using Remotion. The tool returns immediately with a job ID; poll check_compose_job for the final video_url.",
      inputSchema: {
        narration_url: z.string().url().optional(),
        music_url: z.string().url().optional(),
        captions: z.array(captionSchema).optional(),
        segments: z.array(z.object({ src: z.string().url(), duration_seconds: z.number().positive().max(30), kind: z.union([z.literal("video"), z.literal("image")]) })).min(1).max(30),
      },
    },
    async (args) => {
      try {
        logger.info({ tool: "compose_video_story", segmentCount: args.segments.length, hasNarration: Boolean(args.narration_url), hasMusic: Boolean(args.music_url), captionCount: args.captions?.length ?? 0 }, "MCP tool invoked");
        const result = await submitComposeJob({ captions: args.captions, narrationUrl: args.narration_url, musicUrl: args.music_url, segments: args.segments.map((segment) => ({ src: segment.src, durationSeconds: segment.duration_seconds, kind: segment.kind })) });
        return textResult(`Compose job accepted. Job ID: ${result.jobId}`, { ok: true, type: "compose_job", ...result });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "check_compose_job",
    {
      title: "Check Remotion compose job",
      description: "Read-only. Check a previously submitted compose job and return the final MP4 URL when complete.",
      inputSchema: { job_id: z.string().regex(/^[0-9a-f]{32}$/) },
      annotations: { readOnlyHint: true },
    },
    async ({ job_id }) => {
      try {
        const result = await getComposeJob(job_id);
        if (!result) throw new Error(`Unknown compose job: ${job_id}`);
        const message = result.status === "completed" ? `Compose completed: ${result.videoUrl}` : result.status === "failed" ? `Compose failed: ${result.error ?? "unknown error"}` : `Compose is ${result.status}.`;
        return textResult(message, { ok: result.status !== "failed", type: "compose_job", ...result });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  return server;
}

function setCors(res: ServerResponse): void {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, GET, DELETE, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type, mcp-session-id");
  res.setHeader("Access-Control-Expose-Headers", "Mcp-Session-Id");
}

async function sendFileWithRange(req: IncomingMessage, res: ServerResponse, filePath: string, contentType: string, filename: string): Promise<void> {
  const info = await stat(filePath);
  if (!info.isFile()) throw new Error('Not a file');
  const rangeHeader = req.headers.range;
  if (typeof rangeHeader === 'string' && rangeHeader.startsWith('bytes=')) {
    const [startRaw, endRaw] = rangeHeader.slice('bytes='.length).split('-');
    const start = Number.parseInt(startRaw, 10);
    const end = endRaw ? Number.parseInt(endRaw, 10) : info.size - 1;
    if (Number.isNaN(start) || Number.isNaN(end) || start < 0 || end < start || end >= info.size) {
      res.writeHead(416, {
        'content-range': `bytes */${info.size}`,
        'access-control-allow-origin': '*',
      });
      res.end();
      return;
    }
    const chunkSize = end - start + 1;
    res.writeHead(206, {
      'content-type': contentType,
      'content-length': chunkSize,
      'content-range': `bytes ${start}-${end}/${info.size}`,
      'accept-ranges': 'bytes',
      'content-disposition': `inline; filename="${filename}"`,
      'cache-control': 'public, max-age=31536000, immutable',
      'access-control-allow-origin': '*',
    });
    createReadStream(filePath, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, {
    'content-type': contentType,
    'content-length': info.size,
    'accept-ranges': 'bytes',
    'content-disposition': `inline; filename="${filename}"`,
    'cache-control': 'public, max-age=31536000, immutable',
    'access-control-allow-origin': '*',
  });
  createReadStream(filePath).pipe(res);
}

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const requestId = crypto.randomUUID();
  const started = Date.now();
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);

  logger.info({ requestId, method: req.method, path: url.pathname }, "HTTP request received");
  res.on("finish", () => {
    logger.info({ requestId, method: req.method, path: url.pathname, statusCode: res.statusCode, durationMs: Date.now() - started }, "HTTP request completed");
  });

  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ service: "runpod-ai-mcp-server", status: "ok", mcp: MCP_PATH, connector_url: "/", alternate_mcp: MCP_ALTERNATE_PATH, neutral_connector: MCP_CONNECTOR_PATH }));
    return;
  }

  if (req.method === "GET" && url.pathname === "/healthz") {
    try {
      const upstream = await health();
      res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(JSON.stringify({ status: "ok", upstream }));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.writeHead(503, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(JSON.stringify({ status: "degraded", error: message }));
    }
    return;
  }

  const audioPrefix = "/files/generated/audio/";
  if (req.method === "GET" && url.pathname.startsWith(audioPrefix)) {
    const filename = path.basename(decodeURIComponent(url.pathname.slice(audioPrefix.length)));
    const filePath = path.join(config.AUDIO_OUTPUT_DIR, filename);
    try {
      if (path.extname(filename).toLowerCase() !== ".wav") throw new Error("Not a WAV file");
      await sendFileWithRange(req, res, filePath, "audio/wav", filename);
    } catch {
      res.writeHead(404, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(JSON.stringify({ detail: "Generated audio not found." }));
    }
    return;
  }

  const remotionPrefix = "/files/generated/remotion/";
  if (req.method === "GET" && url.pathname.startsWith(remotionPrefix)) {
    const filename = path.basename(decodeURIComponent(url.pathname.slice(remotionPrefix.length)));
    const filePath = path.join(config.REMOTION_OUTPUT_DIR, filename);
    try {
      if (path.extname(filename).toLowerCase() !== ".mp4") throw new Error("Not an MP4 file");
      await sendFileWithRange(req, res, filePath, "video/mp4", filename);
    } catch {
      res.writeHead(404, { "content-type": "application/json", "access-control-allow-origin": "*" });
      res.end(JSON.stringify({ detail: "Generated remotion video not found." }));
    }
    return;
  }

  if (req.method === "OPTIONS" && MCP_POST_PATHS.has(url.pathname)) {
    setCors(res);
    res.writeHead(204).end();
    return;
  }

  const allowedMethods = new Set(["POST", "GET", "DELETE"]);
  if (MCP_POST_PATHS.has(url.pathname) && req.method && allowedMethods.has(req.method)) {
    setCors(res);
    const server = createMcpServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });

    res.on("close", () => {
      void transport.close();
      void server.close();
    });

    try {
      await server.connect(transport);
      await transport.handleRequest(req, res);
    } catch (error) {
      logger.error({ requestId, err: error }, "MCP request failed");
      if (!res.headersSent) res.writeHead(500).end("Internal server error");
    }
    return;
  }

  res.writeHead(404, { "content-type": "text/plain" }).end("Not Found");
});

httpServer.listen(config.PORT, "0.0.0.0", () => {
  logger.info({ port: config.PORT, mcpUrl: `http://localhost:${config.PORT}${MCP_PATH}`, runpodBaseUrl: config.RUNPOD_BASE_URL }, "RunPod AI MCP server started");
});

const shutdown = (signal: string) => {
  logger.info({ signal }, "Shutting down MCP server");
  httpServer.close((error) => {
    if (error) {
      logger.error({ err: error }, "HTTP server shutdown failed");
      process.exit(1);
    }
    process.exit(0);
  });
};

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
