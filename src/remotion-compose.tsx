import React from 'react';
import { Audio, AbsoluteFill, Img, OffthreadVideo, Sequence, useVideoConfig } from 'remotion';

export type StorySegment = {
  src: string;
  durationSeconds: number;
  kind: 'video' | 'image';
};

export type StoryCompositionProps = {
  segments?: StorySegment[];
  narrationUrl?: string;
  musicUrl?: string;
};

const CONTAINER_STYLE: React.CSSProperties = {
  flex: 1,
  backgroundColor: '#050816',
};

export function StoryComposition({ segments, narrationUrl, musicUrl }: StoryCompositionProps) {
  const safeSegments = Array.isArray(segments) ? segments : [];
  const { fps } = useVideoConfig();
  const framesFor = (durationSeconds: number) => Math.max(1, Math.round(durationSeconds * fps));
  let startFrame = 0;

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
    </AbsoluteFill>
  );
}

