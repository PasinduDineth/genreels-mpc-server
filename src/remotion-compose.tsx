import React from 'react';
import { Audio, AbsoluteFill, Img, OffthreadVideo, Sequence, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';

export type StorySegment = {
  src: string;
  durationSeconds: number;
  kind: 'video' | 'image';
  caption?: string;
};

export type StoryCompositionProps = {
  title?: string;
  subtitle?: string;
  segments?: StorySegment[];
  narrationUrl?: string;
  musicUrl?: string;
};

const CONTAINER_STYLE: React.CSSProperties = {
  flex: 1,
  backgroundColor: '#050816',
  color: 'white',
  fontFamily: 'Arial, Helvetica, sans-serif',
};

function Overlay({ title, subtitle }: { title?: string; subtitle?: string }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const opacity = interpolate(frame, [0, fps * 0.5, fps * 1.5], [0, 1, 1], { extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ justifyContent: 'flex-end', padding: '96px 72px', pointerEvents: 'none', opacity }}>
      {title ? <div style={{ fontSize: 72, fontWeight: 800, lineHeight: 1.04, textShadow: '0 8px 30px rgba(0,0,0,0.45)' }}>{title}</div> : null}
      {subtitle ? <div style={{ marginTop: 24, fontSize: 32, fontWeight: 500, maxWidth: 900, lineHeight: 1.3, color: 'rgba(255,255,255,0.9)' }}>{subtitle}</div> : null}
    </AbsoluteFill>
  );
}

export function StoryComposition({ title, subtitle, segments = [], narrationUrl, musicUrl }: StoryCompositionProps) {
  let from = 0;
  return (
    <AbsoluteFill style={CONTAINER_STYLE}>
      {segments.map((segment, index) => {
        const durationInFrames = Math.max(1, Math.round(segment.durationSeconds * 30));
        const media = segment.kind === 'video' ? (
          <OffthreadVideo src={segment.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} muted={Boolean(narrationUrl)} />
        ) : (
          <Img src={segment.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
        );
        const block = (
          <AbsoluteFill>
            {media}
            <AbsoluteFill style={{ background: 'linear-gradient(to top, rgba(5,8,22,0.8), rgba(5,8,22,0.1) 45%, rgba(5,8,22,0.25))' }} />
            {segment.caption ? (
              <AbsoluteFill style={{ justifyContent: 'flex-end', padding: '0 72px 220px', pointerEvents: 'none' }}>
                <div style={{ fontSize: 40, fontWeight: 700, lineHeight: 1.15, maxWidth: 920, textShadow: '0 6px 24px rgba(0,0,0,0.45)' }}>{segment.caption}</div>
              </AbsoluteFill>
            ) : null}
          </AbsoluteFill>
        );
        const sequence = (
          <Sequence key={index} from={from} durationInFrames={durationInFrames}>
            {block}
          </Sequence>
        );
        from += durationInFrames;
        return sequence;
      })}
      {title || subtitle ? <Overlay title={title} subtitle={subtitle} /> : null}
      {narrationUrl ? <Audio src={narrationUrl} /> : null}
      {musicUrl ? <Audio src={musicUrl} volume={0.12} loop /> : null}
    </AbsoluteFill>
  );
}
