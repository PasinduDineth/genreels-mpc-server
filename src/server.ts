import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { config } from "./config.js";
import { logger } from "./logger.js";
import { generateSpeech, getStatus, getVideoJob, health, startVideo, waitForVideo } from "./runpod.js";

const MCP_PATH = "/mcp";
const MCP_ALTERNATE_PATH = "/api/mcp";
const MCP_CONNECTOR_PATH = "/connector";
const MCP_POST_PATHS = new Set(["/", MCP_PATH, MCP_ALTERNATE_PATH, MCP_CONNECTOR_PATH]);
const activeVideoJobs = new Set<string>();
let generationOperationInProgress = false;

type OpenAiFileParam = {
  download_url?: string;
  file_id?: string;
  mime_type?: string;
  file_name?: string;
};

function getVideoImageUrl(args: { image_url?: string; image_file?: unknown }): {
  imageUrl: string;
  source: "url" | "chatgpt_file";
  fileId?: string;
} {
  if (args.image_file !== undefined && args.image_file !== null) {
    if (typeof args.image_file !== "object" || Array.isArray(args.image_file)) {
      throw new Error("ChatGPT did not provide a usable image file reference. Reattach the image and try again.");
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
    { name: "runpod-ai-studio", version: "1.3.0" },
    {
      instructions:
        "Use get_runpod_status before diagnosing availability. generate_speech creates Qwen3-TTS audio. generate_video_from_image submits a 5-second portrait video job from a ChatGPT-generated/uploaded image or a public image URL. check_video_job is read-only. generate_video_and_wait may take several minutes; use it only when the user explicitly wants the final result in one tool call.",
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
        speed: z.number().min(0.25).max(4).default(1).describe("Speech speed multiplier."),
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) {
          throw new Error("Cannot switch to TTS mode while a video job is active. Check the video job until it completes or fails.");
        }
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        logger.info({ tool: "generate_speech", voice: args.voice, textLength: args.text.length }, "MCP tool invoked");
        const result = await generateSpeech({ text: args.text, voice: args.voice, speed: args.speed });
        const data = Buffer.from(result.bytes).toString("base64");
        return {
          content: [
            {
              type: "text" as const,
              text: result.audioUrl
                ? `Speech generated successfully with voice ${result.voice}: ${result.audioUrl}`
                : `Speech generated successfully with voice ${result.voice}.`,
            },
            { type: "audio" as const, data, mimeType: result.mimeType },
          ],
          structuredContent: {
            ok: true,
            type: "audio",
            format: result.format,
            mime_type: result.mimeType,
            voice: result.voice,
            byte_length: result.bytes.byteLength,
            ...(result.audioUrl ? { audio_url: result.audioUrl } : {}),
          },
        };
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
        const [healthResult, status] = await Promise.all([health(), getStatus()]);
        return textResult("RunPod gateway is reachable.", { ok: true, health: healthResult, status });
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
      inputSchema: {
        image_file: z.any().optional().describe("ChatGPT-generated or uploaded source image. Use this for an image available in the conversation."),
        image_url: z.string().url().optional().describe("Publicly reachable source image URL. Use only when no ChatGPT image file is available."),
        prompt: z.string().min(1).max(4000).describe("Motion/camera prompt describing how the input image should animate."),
        steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8),
        seed: z.number().int().nonnegative().optional(),
      },
      _meta: {
        "openai/fileParams": ["image_file"],
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        const image = getVideoImageUrl(args);
        logger.info({ tool: "generate_video_from_image", imageSource: image.source, fileId: image.fileId, steps: args.steps }, "MCP tool invoked");
        const result = await startVideo({ imageUrl: image.imageUrl, prompt: args.prompt, steps: args.steps, seed: args.seed });
        activeVideoJobs.add(result.job_id);
        return textResult(`Video job accepted. Job ID: ${result.job_id}`, {
          ok: true,
          type: "video_job",
          ...result,
        });
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
      inputSchema: {
        job_id: z.string().regex(/^[0-9a-f]{32}$/).describe("32-character hexadecimal video job ID."),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ job_id }) => {
      try {
        const result = await getVideoJob(job_id);
        if (result.status === "completed" || result.status === "failed") activeVideoJobs.delete(job_id);
        const message =
          result.status === "completed"
            ? `Video completed: ${result.video_url}`
            : result.status === "failed"
              ? `Video failed: ${result.error ?? "unknown error"}`
              : `Video is ${result.status}${result.stage ? ` (${result.stage})` : ""}.`;
        return textResult(message, { ok: result.status !== "failed", type: "video_job", ...result });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "generate_video_and_wait",
    {
      title: "Generate 5-second video and wait",
      description:
        "Generate a 5-second HunyuanVideo clip from a ChatGPT-generated/uploaded image or public image URL and wait until the MP4 is complete. Prefer image_file for an image created or attached in this chat. Use only when the user explicitly wants a finished clip in one operation; this can take several minutes.",
      inputSchema: {
        image_file: z.any().optional().describe("ChatGPT-generated or uploaded source image. Use this for an image available in the conversation."),
        image_url: z.string().url().optional().describe("Publicly reachable source image URL. Use only when no ChatGPT image file is available."),
        prompt: z.string().min(1).max(4000),
        steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8),
        seed: z.number().int().nonnegative().optional(),
      },
      _meta: {
        "openai/fileParams": ["image_file"],
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        const image = getVideoImageUrl(args);
        logger.info({ tool: "generate_video_and_wait", imageSource: image.source, fileId: image.fileId, steps: args.steps }, "MCP tool invoked");
        const submitted = await startVideo({ imageUrl: image.imageUrl, prompt: args.prompt, steps: args.steps, seed: args.seed });
        activeVideoJobs.add(submitted.job_id);
        let completed;
        try {
          completed = await waitForVideo(submitted.job_id);
        } finally {
          activeVideoJobs.delete(submitted.job_id);
        }
        return textResult(`Video generated successfully: ${completed.video_url}`, {
          ok: true,
          type: "video",
          ...completed,
        });
      } catch (error) {
        return errorResult(error);
      } finally {
        if (acquiredGenerationLock) generationOperationInProgress = false;
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
    res.end(
      JSON.stringify({
        service: "runpod-ai-mcp-server",
        status: "ok",
        mcp: MCP_PATH,
        connector_url: "/",
        alternate_mcp: MCP_ALTERNATE_PATH,
        neutral_connector: MCP_CONNECTOR_PATH,
      }),
    );
    return;
  }

  if (req.method === "GET" && url.pathname === "/healthz") {
    try {
      const upstream = await health();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ status: "ok", upstream }));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ status: "degraded", error: message }));
    }
    return;
  }

  const audioPrefix = "/files/generated/audio/";
  if (req.method === "GET" && url.pathname.startsWith(audioPrefix)) {
    const filename = path.basename(decodeURIComponent(url.pathname.slice(audioPrefix.length)));
    const filePath = path.join(config.AUDIO_OUTPUT_DIR, filename);
    try {
      const info = await stat(filePath);
      if (!info.isFile() || path.extname(filename).toLowerCase() !== ".wav") throw new Error("Not a WAV file");
      res.writeHead(200, {
        "content-type": "audio/wav",
        "content-length": info.size,
        "content-disposition": `inline; filename="${filename}"`,
        "cache-control": "public, max-age=31536000, immutable",
      });
      createReadStream(filePath).pipe(res);
    } catch {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ detail: "Generated audio not found." }));
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
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });

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
  logger.info(
    {
      port: config.PORT,
      mcpUrl: `http://localhost:${config.PORT}${MCP_PATH}`,
      runpodBaseUrl: config.RUNPOD_BASE_URL,
    },
    "RunPod AI MCP server started",
  );
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
