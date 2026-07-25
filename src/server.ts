import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { config } from "./config.js";
import { logger } from "./logger.js";
import { generateImage, getStatus, getVideoJob, health, startVideo, waitForVideo } from "./runpod.js";

const MCP_PATH = "/mcp";
const MCP_ALTERNATE_PATH = "/api/mcp";
const MCP_POST_PATHS = new Set(["/", MCP_PATH, MCP_ALTERNATE_PATH]);
const activeVideoJobs = new Set<string>();
let generationOperationInProgress = false;

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
    { name: "runpod-ai-studio", version: "1.0.0" },
    {
      instructions:
        "Use get_runpod_status before diagnosing availability. generate_image creates an image and returns a public URL. generate_video_from_image submits a 5-second portrait video job from an image URL. check_video_job is read-only. generate_video_and_wait may take several minutes; use it only when the user explicitly wants the final result in one tool call.",
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
    "generate_image",
    {
      title: "Generate image on RunPod",
      description:
        "Generate one SDXL image from a text prompt. Use this when the user asks to create a starting image or standalone image. This tool automatically switches the single GPU into image mode and waits until ready.",
      inputSchema: {
        prompt: z.string().min(1).max(4000).describe("Detailed visual prompt for the generated image."),
        width: z.number().int().min(256).max(1536).multipleOf(16).default(1024),
        height: z.number().int().min(256).max(1536).multipleOf(16).default(1024),
        steps: z.number().int().min(1).max(100).default(30),
        guidance_scale: z.number().min(0).max(20).default(7),
        seed: z.number().int().nonnegative().optional(),
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) {
          throw new Error("Cannot switch to image mode while a video job is active. Check the video job until it completes or fails.");
        }
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        logger.info({ tool: "generate_image", width: args.width, height: args.height, steps: args.steps }, "MCP tool invoked");
        const result = await generateImage({
          prompt: args.prompt,
          width: args.width,
          height: args.height,
          steps: args.steps,
          guidanceScale: args.guidance_scale,
          seed: args.seed,
        });
        return textResult(`Image generated successfully: ${result.image_url}`, {
          ok: true,
          type: "image",
          image_url: result.image_url,
          model: result.model,
          created: result.created,
          ...result.data[0],
        });
      } catch (error) {
        return errorResult(error);
      } finally {
        if (acquiredGenerationLock) generationOperationInProgress = false;
      }
    },
  );

  server.registerTool(
    "generate_video_from_image",
    {
      title: "Generate 5-second video from image",
      description:
        "Submit a HunyuanVideo image-to-video job using a publicly reachable image URL. Use this for a 5-second 480x832 portrait clip. The tool switches the GPU into video mode and returns immediately with a job ID; call check_video_job afterward.",
      inputSchema: {
        image_url: z.string().url().describe("Public image URL, commonly returned by generate_image."),
        prompt: z.string().min(1).max(4000).describe("Motion/camera prompt describing how the input image should animate."),
        steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8),
        seed: z.number().int().nonnegative().optional(),
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        logger.info({ tool: "generate_video_from_image", imageUrl: args.image_url, steps: args.steps }, "MCP tool invoked");
        const result = await startVideo({ imageUrl: args.image_url, prompt: args.prompt, steps: args.steps, seed: args.seed });
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
        "Generate a 5-second HunyuanVideo clip from an image URL and wait until the MP4 is complete. Use only when the user explicitly wants a finished clip in one operation; this can take several minutes.",
      inputSchema: {
        image_url: z.string().url(),
        prompt: z.string().min(1).max(4000),
        steps: z.union([z.literal(4), z.literal(8), z.literal(12)]).default(8),
        seed: z.number().int().nonnegative().optional(),
      },
    },
    async (args) => {
      let acquiredGenerationLock = false;
      try {
        if (generationOperationInProgress) throw new Error("Another generation request is currently being prepared.");
        if (activeVideoJobs.size > 0) throw new Error("A video job is already active. Check that job before submitting another one.");
        generationOperationInProgress = true;
        acquiredGenerationLock = true;
        logger.info({ tool: "generate_video_and_wait", imageUrl: args.image_url, steps: args.steps }, "MCP tool invoked");
        const submitted = await startVideo({ imageUrl: args.image_url, prompt: args.prompt, steps: args.steps, seed: args.seed });
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
