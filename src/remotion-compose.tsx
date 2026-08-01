import React from 'react';
import { Audio, AbsoluteFill, Img, OffthreadVideo, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';

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
  debugLabel?: string;
};

const CONTAINER_STYLE: React.CSSProperties = {
  flex: 1,
  backgroundColor: '#050816',
  color: 'white',
  fontFamily: 'Arial, Helvetica, sans-serif',
};

function Overlay({ title, subtitle, debugLabel }: { title?: string; subtitle?: string; debugLabel?: string }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const opacity = interpolate(frame, [0, fps * 0.25, fps * 1.0], [0, 1, 1], { extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ justifyContent: 'flex-end', padding: '64px 56px', pointerEvents: 'none', opacity }}>
      {debugLabel ? <div style={{ marginBottom: 16, fontSize: 20, fontWeight: 700, opacity: 0.9 }}>DEBUG: {debugLabel}</div> : null}
      {title ? <div style={{ fontSize: 68, fontWeight: 800, lineHeight: 1.04, textShadow: '0 8px 30px rgba(0,0,0,0.45)' }}>{title}</div> : null}
      {subtitle ? <div style={{ marginTop: 20, fontSize: 30, fontWeight: 500, maxWidth: 920, lineHeight: 1.3, color: 'rgba(255,255,255,0.9)' }}>{subtitle}</div> : null}
    </AbsoluteFill>
  );
}

export function StoryComposition({ title, subtitle, segments, narrationUrl, musicUrl, debugLabel }: StoryCompositionProps) {
  const safeSegments = Array.isArray(segments) ? segments : [];
  const firstSegment = safeSegments[0] ?? null;
  const durationInFrames = Math.max(1, Math.round((firstSegment?.durationSeconds ?? 1) * 30));

  return (
    <AbsoluteFill style={CONTAINER_STYLE}>
      {firstSegment ? (
        <AbsoluteFill>
          {firstSegment.kind === 'video' ? (
            <OffthreadVideo src={firstSegment.src} muted style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          ) : (
            <Img src={firstSegment.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          )}
          <AbsoluteFill style={{ background: 'linear-gradient(to top, rgba(5,8,22,0.75), rgba(5,8,22,0.08) 45%, rgba(5,8,22,0.2))' }} />
          {firstSegment.caption ? (
            <AbsoluteFill style={{ justifyContent: 'flex-end', padding: '0 64px 180px', pointerEvents: 'none' }}>
              <div style={{ fontSize: 38, fontWeight: 700, lineHeight: 1.15, maxWidth: 920, textShadow: '0 6px 24px rgba(0,0,0,0.45)' }}>{firstSegment.caption}</div>
            </AbsoluteFill>
          ) : null}
        </AbsoluteFill>
      ) : null}

      {title || subtitle || debugLabel ? <Overlay title={title} subtitle={subtitle} debugLabel={debugLabel} /> : null}
      {narrationUrl ? <Audio src={narrationUrl} /> : null}
      {musicUrl ? <Audio src={musicUrl} volume={0.12} loop /> : null}
    </AbsoluteFill>
  );
}
