import React, {useMemo} from 'react';
import { Audio, AbsoluteFill, Img, OffthreadVideo, Sequence, useVideoConfig } from 'remotion';
import { createTikTokStyleCaptions } from '@remotion/captions';
import { CaptionPage } from './CaptionPage';

export type StorySegment = {
  src: string;
  durationSeconds: number;
  kind: 'video' | 'image';
};

export type StoryCaption = {
  startMs: number;
  endMs: number;
  text: string;
  timestampMs?: number | null;
};

export type StoryCompositionProps = {
  segments?: StorySegment[];
  narrationUrl?: string;
  musicUrl?: string;
  captions?: StoryCaption[];
};

const CONTAINER_STYLE: React.CSSProperties = {
  flex: 1,
  backgroundColor: '#050816',
};

const CAPTION_LEAD_MS = 80;
const MIN_WORD_DURATION_MS = 80;
const MAX_WORD_HOLD_MS = 1100;

const normalizeCaptionsForRender = (captions: StoryCaption[]) => {
  let previousStartMs = -MIN_WORD_DURATION_MS;
  const alignedStarts = captions.map((caption) => {
    const alignedTimestamp =
      typeof caption.timestampMs === 'number' && Number.isFinite(caption.timestampMs)
        ? caption.timestampMs
        : caption.startMs;
    const startMs = Math.max(
      0,
      alignedTimestamp - CAPTION_LEAD_MS,
      previousStartMs + MIN_WORD_DURATION_MS,
    );
    previousStartMs = startMs;
    return startMs;
  });

  return captions.map((caption, index) => {
    const startMs = alignedStarts[index];
    const nextStartMs = alignedStarts[index + 1];
    const endMs =
      nextStartMs === undefined
        ? Math.max(
            startMs + MIN_WORD_DURATION_MS,
            Math.min(caption.endMs, startMs + MAX_WORD_HOLD_MS),
          )
        : Math.min(nextStartMs, startMs + MAX_WORD_HOLD_MS);

    return {
      ...caption,
      startMs,
      endMs,
    };
  });
};

export function StoryComposition({ segments, narrationUrl, musicUrl, captions = [] }: StoryCompositionProps) {
  const safeSegments = Array.isArray(segments) ? segments : [];
  const { fps, durationInFrames } = useVideoConfig();
  const framesFor = (durationSeconds: number) => Math.max(1, Math.round(durationSeconds * fps));
  let startFrame = 0;

  const captionPages = useMemo(() => {
    if (!captions.length) return [];
    return createTikTokStyleCaptions({ captions: normalizeCaptionsForRender(captions), combineTokensWithinMilliseconds: 200 }).pages;
  }, [captions]);

  return (
    <AbsoluteFill style={CONTAINER_STYLE}>
      {safeSegments.map((segment, index) => {
        const durationInFrames = framesFor(segment.durationSeconds);
        const from = startFrame;
        startFrame += durationInFrames;
        return (
          <Sequence key={`${index}-${segment.src}`} from={from} durationInFrames={durationInFrames}>
            <AbsoluteFill>
              {segment.kind === 'video' ? (
                <OffthreadVideo src={segment.src} muted style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              ) : (
                <Img src={segment.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              )}
            </AbsoluteFill>
          </Sequence>
        );
      })}

      {narrationUrl ? <Audio src={narrationUrl} /> : null}
      {musicUrl ? <Audio src={musicUrl} volume={0.12} loop /> : null}

      {captionPages.map((page, index) => {
        const nextPage = captionPages[index + 1] ?? null;
        const captionStartFrame = Math.max(0, Math.floor((page.startMs / 1000) * fps));
        const captionEndFrame = nextPage ? Math.floor((nextPage.startMs / 1000) * fps) : durationInFrames;
        const captionDurationInFrames = Math.max(captionEndFrame - captionStartFrame, 1);

        return (
          <Sequence key={`${page.startMs}-${index}`} from={captionStartFrame} durationInFrames={captionDurationInFrames}>
            <CaptionPage page={page} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
}
