import "dotenv/config";
import { z } from "zod";

const envSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  LOG_LEVEL: z.string().default("info"),
  RUNPOD_BASE_URL: z.string().url().transform((value) => value.replace(/\/$/, "")),
  RUNPOD_PUBLIC_BASE_URL: z.string().url().transform((value) => value.replace(/\/$/, "")).optional(),
  MCP_PUBLIC_BASE_URL: z.string().url().transform((value) => value.replace(/\/$/, "")).optional(),
  AUDIO_OUTPUT_DIR: z.string().min(1).default("/workspace/generated/audio"),
  IMAGE_UPLOAD_DIR: z.string().min(1).default("/workspace/generated/uploads"),
  IMAGE_UPLOAD_MAX_BYTES: z.coerce.number().int().positive().default(20_000_000),
  VIDEO_OUTPUT_DIR: z.string().min(1).default("/workspace/generated/videos"),
  VIDEO_JOB_DIR: z.string().min(1).default("/workspace/ai-stack/run/video-jobs"),
  RUNPOD_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(60_000),
  MODE_SWITCH_TIMEOUT_MS: z.coerce.number().int().positive().default(600_000),
  MODE_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(2_000),
  VIDEO_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(4_000),
  VIDEO_POLL_TIMEOUT_MS: z.coerce.number().int().positive().default(1_200_000),
  REMOTE_IMAGE_TIMEOUT_MS: z.coerce.number().int().positive().default(30_000),
  REMOTE_IMAGE_MAX_BYTES: z.coerce.number().int().positive().default(20_000_000),
  REMOTION_OUTPUT_DIR: z.string().min(1).default("/workspace/generated/remotion"),
  REMOTION_JOB_DIR: z.string().min(1).default("/workspace/ai-stack/run/remotion-jobs"),
  REMOTION_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(4_000),
  REMOTION_POLL_TIMEOUT_MS: z.coerce.number().int().positive().default(1_800_000),
});

const parsed = envSchema.safeParse(process.env);
if (!parsed.success) {
  console.error("Invalid environment configuration:", parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const config = parsed.data;
