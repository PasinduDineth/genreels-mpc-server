import { registerRoot, Composition } from 'remotion';
import { z } from 'zod';
import { StoryComposition } from './remotion-compose.js';

const schema = z.object({
  title: z.string().optional(),
  subtitle: z.string().optional(),
  narrationUrl: z.string().url().optional(),
  musicUrl: z.string().url().optional(),
  segments: z.array(z.object({
    src: z.string().url(),
    durationSeconds: z.number().positive(),
    kind: z.union([z.literal('video'), z.literal('image')]),
    caption: z.string().optional(),
  })).min(1),
});

const Root = () => (
  <>
    <Composition
      id="StoryComposition"
      component={StoryComposition}
      width={1080}
      height={1920}
      fps={30}
      durationInFrames={30}
      schema={schema}
      defaultProps={{ segments: [{ src: 'https://example.com', durationSeconds: 1, kind: 'image' }] }}
    />
  </>
);

registerRoot(Root);
