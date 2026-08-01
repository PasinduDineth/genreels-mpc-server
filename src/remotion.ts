import { bundle } from '@remotion/bundler';
import { renderMedia } from '@remotion/renderer';
import path from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
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
  await mkdir(config.REMOTION_JOB_DIR, { recursive: true });
}

function publicAbsoluteUrl(fileName: string): string {
  const base = config.RUNPOD_PUBLIC_BASE_URL ?? config.MCP_PUBLIC_BASE_URL ?? config.RUNPOD_BASE_URL;
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

async function downloadToFile(url: string, outputPath: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Failed to download asset (${response.status})`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error('Downloaded asset was empty');
  await writeFile(outputPath, bytes);
}

function toFileUrl(filePath: string): string {
  return `file://${filePath.replace(/\\/g, '/')}`;
}

function getExtensionFromUrl(url: string, fallback: string): string {
  try {
    const ext = path.extname(new URL(url).pathname);
    return ext || fallback;
  } catch {
    const ext = path.extname(url);
    return ext || fallback;
  }
}

async function prepareLocalAsset(inputUrl: string, jobId: string, kind: 'video' | 'image' | 'audio', index: number): Promise<string> {
  const ext = getExtensionFromUrl(inputUrl, kind === 'image' ? '.png' : kind === 'video' ? '.mp4' : '.wav');
  const filename = `${jobId}-${kind}-${index}${ext}`;
  const outputPath = path.join(config.REMOTION_JOB_DIR, filename);
  await downloadToFile(inputUrl, outputPath);
  return toFileUrl(outputPath);
}

async function prepareComposeInput(input: ComposeVideoInput, jobId: string): Promise<ComposeVideoInput & { segments: ComposeSegment[] }> {
  const segments = Array.isArray(input.segments) ? input.segments : [];
  if (segments.length === 0) throw new Error('Compose job requires at least one segment.');
  const localSegments: ComposeSegment[] = [];
  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    if (!segment?.src) throw new Error(`Segment ${i + 1} is missing src`);
    localSegments.push({
      ...segment,
      src: await prepareLocalAsset(segment.src, jobId, segment.kind, i),
    });
  }
  const prepared: ComposeVideoInput & { segments: ComposeSegment[] } = { ...input, segments: localSegments };
  if (input.narrationUrl) prepared.narrationUrl = await prepareLocalAsset(input.narrationUrl, jobId, 'audio', 0);
  if (input.musicUrl) prepared.musicUrl = await prepareLocalAsset(input.musicUrl, jobId, 'audio', 1);
  return prepared;
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
      const prepared = await prepareComposeInput(input, jobId);
      const serveUrl = await getBundleUrl();
      const durationInFrames = Math.max(1, Math.round(prepared.segments.reduce((sum, seg) => sum + seg.durationSeconds, 0) * 30));
      await renderMedia({
        serveUrl,
        codec: 'h264',
        composition: {
          id: 'StoryComposition',
          width: 1080,
          height: 1920,
          fps: 30,
          durationInFrames,
          defaultProps: prepared,
        } as never,
        inputProps: prepared,
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
