import { registerRoot, Composition } from 'remotion';
import { z } from 'zod';
import { StoryComposition } from './remotion-compose';

const captionSchema = z.object({
  text: z.string(),
  startMs: z.number(),
  endMs: z.number(),
  timestampMs: z.number().optional(),
  confidence: z.number().optional(),
});

const schema = z.object({
  narrationUrl: z.string().url().optional(),
  musicUrl: z.string().url().optional(),
  captions: z.array(captionSchema).optional(),
  segments: z.array(z.object({
    src: z.string().url(),
    durationSeconds: z.number().positive(),
    kind: z.union([z.literal('video'), z.literal('image')]),
  })).min(1),
});

const Root = () => (
  <>
    <Composition
      id="StoryComposition"
      component={StoryComposition}
      width={1080}
      height={1920}
      fps={24}
      durationInFrames={24}
      schema={schema}
      defaultProps={{ segments: [{ src: 'https://example.com', durationSeconds: 1, kind: 'image' }] }}
    />
  </>
);

registerRoot(Root);
