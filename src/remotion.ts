import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { mkdir, writeFile, access, readFile, copyFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { config } from './config.js';
import { logger } from './logger.js';

const execFileAsync = promisify(execFile);
const COMPOSITION_FPS = 24;

export type ComposeSegment = {
  src: string;
  durationSeconds: number;
  kind: 'video' | 'image';
};

export type ComposeVideoInput = {
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

function servedAssetUrl(fileName: string): string {
  return `${config.RUNPOD_BASE_URL}/files/generated/remotion/${encodeURIComponent(fileName)}`;
}

function isHttpUrl(value: string): boolean {
  try {
    return new URL(value).protocol === 'http:' || new URL(value).protocol === 'https:';
  } catch {
    return false;
  }
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

async function downloadToFile(url: string, outputPath: string, jobId: string, label: string): Promise<void> {
  logger.info({ jobId, label, url, outputPath }, 'Downloading compose asset');
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Failed to download asset (${response.status})`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error('Downloaded asset was empty');
  await writeFile(outputPath, bytes);
  logger.info({ jobId, label, outputPath, byteLength: bytes.byteLength }, 'Compose asset downloaded');
}

function toDataUrl(bytes: Uint8Array, mimeType: string): string {
  return `data:${mimeType};base64,${Buffer.from(bytes).toString('base64')}`;
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

function localPathForGeneratedAsset(url: string): string | null {
  try {
    const parsed = new URL(url);
    const filename = path.basename(parsed.pathname);
    if (parsed.pathname.startsWith('/files/generated/videos/')) return path.join(config.VIDEO_OUTPUT_DIR, filename);
    if (parsed.pathname.startsWith('/files/generated/audio/')) return path.join(config.AUDIO_OUTPUT_DIR, filename);
    if (parsed.pathname.startsWith('/files/generated/remotion/')) return path.join(config.REMOTION_OUTPUT_DIR, filename);
    return null;
  } catch {
    return null;
  }
}

async function fetchOrCopyLocalAsset(inputUrl: string, outputPath: string, jobId: string, label: string): Promise<void> {
  const localPath = localPathForGeneratedAsset(inputUrl);
  if (localPath) {
    try {
      await access(localPath, fsConstants.R_OK);
      await execFileAsync('cp', ['-f', localPath, outputPath]);
      logger.info({ jobId, label, localPath, outputPath }, 'Copied local generated asset');
      return;
    } catch {
      logger.info({ jobId, label, localPath }, 'Local generated asset missing, falling back to network download');
    }
  }
  await downloadToFile(inputUrl, outputPath, jobId, label);
}

async function transcodeVideoToBrowserFriendly(inputPath: string, outputPath: string, jobId: string, label: string): Promise<void> {
  logger.info({ jobId, label, inputPath, outputPath }, 'Transcoding video asset');
  await execFileAsync('ffmpeg', [
    '-y',
    '-i', inputPath,
    '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p',
    '-r', String(COMPOSITION_FPS),
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    '-crf', '20',
    '-movflags', '+faststart',
    '-an',
    outputPath,
  ]);
  logger.info({ jobId, label, inputPath, outputPath }, 'Video asset transcoded');
}

async function normalizeMediaAsset(inputUrl: string, jobId: string, kind: 'video' | 'image' | 'audio', index: number): Promise<string> {
  const ext = getExtensionFromUrl(inputUrl, kind === 'image' ? '.png' : kind === 'video' ? '.mp4' : '.wav');
  const rawFilename = `${jobId}-${kind}-${index}-raw${ext}`;
  const rawPath = path.join(config.REMOTION_JOB_DIR, rawFilename);
  await fetchOrCopyLocalAsset(inputUrl, rawPath, jobId, `${kind}:${index}:download`);

  if (kind === 'video') {
    const outputPath = path.join(config.REMOTION_OUTPUT_DIR, `${jobId}-${kind}-${index}.mp4`);
    await transcodeVideoToBrowserFriendly(rawPath, outputPath, jobId, `${kind}:${index}:transcode`);
    return servedAssetUrl(path.basename(outputPath));
  }

  if (kind === 'audio') {
    const bytes = await readFile(rawPath);
    const mimeType = ext.toLowerCase() === '.mp3' ? 'audio/mpeg' : 'audio/wav';
    const dataUrl = toDataUrl(new Uint8Array(bytes), mimeType);
    logger.info({ jobId, label: `${kind}:${index}:dataurl`, byteLength: bytes.byteLength }, 'Audio asset converted to data URL');
    return dataUrl;
  }

  const outputPath = path.join(config.REMOTION_OUTPUT_DIR, `${jobId}-${kind}-${index}${ext}`);
  await copyFile(rawPath, outputPath);
  logger.info({ jobId, label: `${kind}:${index}:copy`, outputPath }, 'Image asset copied to served output');
  return servedAssetUrl(path.basename(outputPath));
}

async function prepareComposeInput(input: ComposeVideoInput, jobId: string): Promise<ComposeVideoInput & { segments: ComposeSegment[] }> {
  const segments = Array.isArray(input.segments) ? input.segments : [];
  if (segments.length === 0) throw new Error('Compose job requires at least one segment.');
  const localSegments: ComposeSegment[] = [];
  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    if (!segment?.src) throw new Error(`Segment ${i + 1} is missing src`);
    logger.info({ jobId, index: i, kind: segment.kind, durationSeconds: segment.durationSeconds, src: segment.src, srcIsHttp: isHttpUrl(segment.src) }, 'Preparing compose segment');
    const normalizedSrc = await normalizeMediaAsset(segment.src, jobId, segment.kind, i);
    logger.info({ jobId, index: i, kind: segment.kind, normalizedSrc, normalizedSrcIsHttp: isHttpUrl(normalizedSrc) }, 'Compose segment normalized');
    localSegments.push({ ...segment, src: normalizedSrc });
  }
  const prepared: ComposeVideoInput & { segments: ComposeSegment[] } = { ...input, segments: localSegments };
  if (input.narrationUrl) {
    prepared.narrationUrl = await normalizeMediaAsset(input.narrationUrl, jobId, 'audio', 0);
    logger.info({ jobId, narrationIsDataUrl: prepared.narrationUrl.startsWith('data:') }, 'Narration audio attached');
  }
  if (input.musicUrl) {
    prepared.musicUrl = await normalizeMediaAsset(input.musicUrl, jobId, 'audio', 1);
    logger.info({ jobId, musicIsDataUrl: prepared.musicUrl.startsWith('data:') }, 'Music audio attached');
  }
  logger.info(
    {
      jobId,
      segmentCount: prepared.segments.length,
      segments: prepared.segments.map((segment, index) => ({ index, kind: segment.kind, durationSeconds: segment.durationSeconds, src: segment.src })),
      hasNarration: Boolean(prepared.narrationUrl),
      hasMusic: Boolean(prepared.musicUrl),
    },
    'Compose input prepared',
  );
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
      logger.info({ jobId, segmentCount: input.segments?.length ?? 0, hasNarration: Boolean(input.narrationUrl), hasMusic: Boolean(input.musicUrl) }, 'Compose job started');
      const prepared = await prepareComposeInput(input, jobId);
      const serveUrl = await getBundleUrl();
      const segmentFrames = prepared.segments.map((segment, index) => ({
        index,
        kind: segment.kind,
        durationSeconds: segment.durationSeconds,
        durationInFrames: Math.max(1, Math.round(segment.durationSeconds * COMPOSITION_FPS)),
        src: segment.src,
      }));
      const durationInFrames = Math.max(1, segmentFrames.reduce((sum, seg) => sum + seg.durationInFrames, 0));
      logger.info(
        {
          jobId,
          outputPath,
          durationInFrames,
          segmentCount: prepared.segments.length,
          segmentFrames,
          narrationUrl: prepared.narrationUrl ?? null,
          musicUrl: prepared.musicUrl ?? null,
          serveUrl,
        },
        'Rendering compose job',
      );
      const inputProps = prepared;
      const selectedComposition = await selectComposition({
        serveUrl,
        id: 'StoryComposition',
        inputProps,
      });
      const composition = { ...selectedComposition, durationInFrames };
      logger.info(
        {
          jobId,
          selectedComposition: {
            id: composition.id,
            width: composition.width,
            height: composition.height,
            fps: composition.fps,
            durationInFrames: composition.durationInFrames,
          },
        },
        'Remotion composition selected',
      );
      await renderMedia({
        serveUrl,
        codec: 'h264',
        composition,
        inputProps,
        outputLocation: outputPath,
        overwrite: true,
        browserExecutable: null,
      });
      status.status = 'completed';
      status.outputPath = outputPath;
      status.videoUrl = publicAbsoluteUrl(path.basename(outputPath));
      logger.info({ jobId, outputPath, videoUrl: status.videoUrl }, 'Compose job completed');
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


