import { bundle } from '@remotion/bundler';
import { renderMedia } from '@remotion/renderer';
import path from 'node:path';
import { mkdir } from 'node:fs/promises';
import { config } from './config.js';
import { logger } from './logger.js';

export type ComposeSegment = {
  src: string;
  durationSeconds: number;
  kind: 'video' | 'image';
  caption?: string;
};

export type ComposeVideoInput = {
  title?: string;
  subtitle?: string;
  segments?: ComposeSegment[];
  narrationUrl?: string;
  musicUrl?: string;
};

export type ComposeJobStatus = {
  jobId: string;
  status: 'queued' | 'processing' | 'completed' | 'failed';
  outputPath?: string;
  videoUrl?: string;
  error?: string;
};

const jobState = new Map<string, ComposeJobStatus>();
let bundlePromise: Promise<string> | null = null;

async function ensureOutputDir() {
  await mkdir(config.REMOTION_OUTPUT_DIR, { recursive: true });
}

function publicAbsoluteUrl(fileName: string): string {
  const base = config.MCP_PUBLIC_BASE_URL ?? config.RUNPOD_BASE_URL;
  return `${base}/files/generated/remotion/${encodeURIComponent(fileName)}`;
}

async function getBundleUrl(): Promise<string> {
  if (!bundlePromise) {
    bundlePromise = bundle({
      entryPoint: path.resolve('src', 'remotion-entry.tsx'),
      onProgress: () => undefined,
      ignoreRegisterRootWarning: true,
    });
  }
  return bundlePromise;
}

export async function submitComposeJob(input: ComposeVideoInput): Promise<ComposeJobStatus> {
  await ensureOutputDir();
  const jobId = crypto.randomUUID().replace(/-/g, '');
  const outputPath = path.join(config.REMOTION_OUTPUT_DIR, `${jobId}.mp4`);
  const status: ComposeJobStatus = { jobId, status: 'queued' };
  jobState.set(jobId, status);

  void (async () => {
    try {
      status.status = 'processing';
      const segments = Array.isArray(input.segments) ? input.segments : [];
      if (segments.length === 0) {
        throw new Error('Compose job requires at least one segment.');
      }
      const serveUrl = await getBundleUrl();
      const durationInFrames = Math.max(1, Math.round(segments.reduce((sum, seg) => sum + seg.durationSeconds, 0) * 30));
      await renderMedia({
        serveUrl,
        codec: 'h264',
        composition: {
          id: 'StoryComposition',
          width: 1080,
          height: 1920,
          fps: 30,
          durationInFrames,
          defaultProps: {
            ...input,
            segments,
          },
        } as never,
        inputProps: {
          ...input,
          segments,
        },
        outputLocation: outputPath,
        overwrite: true,
        browserExecutable: null,
      });
      status.status = 'completed';
      status.outputPath = outputPath;
      status.videoUrl = publicAbsoluteUrl(path.basename(outputPath));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      status.status = 'failed';
      status.error = message;
      logger.error({ err: error, jobId }, 'Remotion compose job failed');
    }
  })();

  return status;
}

export async function getComposeJob(jobId: string): Promise<ComposeJobStatus | undefined> {
  return jobState.get(jobId);
}
