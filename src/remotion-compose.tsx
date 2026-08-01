import React from 'react';
import { Audio, AbsoluteFill, Img, Sequence, Video, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';

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

function DebugPanel({
  segments,
  narrationUrl,
  musicUrl,
  debugLabel,
}: {
  segments: StorySegment[];
  narrationUrl?: string;
  musicUrl?: string;
  debugLabel?: string;
}) {
  if (!debugLabel) return null;

  const firstSegment = segments[0];
  return (
    <div style={{ position: 'absolute', top: 28, left: 28, right: 28, zIndex: 100, padding: '16px 20px', borderRadius: 14, backgroundColor: 'rgba(0, 0, 0, 0.72)', color: '#7dffad', fontFamily: 'monospace', fontSize: 18, lineHeight: 1.35, overflow: 'hidden' }}>
      <div>job: {debugLabel}</div>
      <div>segments: {segments.length} | narration: {narrationUrl ? 'yes' : 'no'} | music: {musicUrl ? 'yes' : 'no'}</div>
      <div>first: {firstSegment ? `${firstSegment.kind} ${firstSegment.durationSeconds}s` : 'missing'}</div>
      <div style={{ whiteSpace: 'nowrap', textOverflow: 'ellipsis', overflow: 'hidden' }}>src: {firstSegment?.src ?? 'missing'}</div>
    </div>
  );
}
export function StoryComposition({ title, subtitle, segments, narrationUrl, musicUrl, debugLabel }: StoryCompositionProps) {
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
                <Video src={segment.src} muted playsInline style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              ) : (
                <Img src={segment.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
              )}
              <AbsoluteFill style={{ background: 'linear-gradient(to top, rgba(5,8,22,0.75), rgba(5,8,22,0.08) 45%, rgba(5,8,22,0.2))' }} />
              {segment.caption ? (
                <AbsoluteFill style={{ justifyContent: 'flex-end', padding: '0 64px 180px', pointerEvents: 'none' }}>
                  <div style={{ fontSize: 38, fontWeight: 700, lineHeight: 1.15, maxWidth: 920, textShadow: '0 6px 24px rgba(0,0,0,0.45)' }}>{segment.caption}</div>
                </AbsoluteFill>
              ) : null}
            </AbsoluteFill>
          </Sequence>
        );
      })}

      {title || subtitle || debugLabel ? <Overlay title={title} subtitle={subtitle} debugLabel={debugLabel} /> : null}
      <DebugPanel segments={safeSegments} narrationUrl={narrationUrl} musicUrl={musicUrl} debugLabel={debugLabel} />
      {narrationUrl ? <Audio src={narrationUrl} /> : null}
      {musicUrl ? <Audio src={musicUrl} volume={0.12} loop /> : null}
    </AbsoluteFill>
  );
}

