import {createServer} from 'node:http';
import {createReadStream} from 'node:fs';
import {stat, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {bundle} from '@remotion/bundler';
import {renderMedia, selectComposition} from '@remotion/renderer';

const downloads = process.env.USERPROFILE + '\\Downloads';
const assets = {
  '/video1': [path.join(downloads, 'tt1.mp4'), 'video/mp4'],
  '/video2': [path.join(downloads, 'tt2.mp4'), 'video/mp4'],
  '/audio': [path.join(downloads, 'Varnished Silence.mp3'), 'audio/mpeg'],
};
const output = path.resolve('generated', 'local-production-composition.mp4');
await mkdir(path.dirname(output), {recursive: true});

async function send(req, res, file, type) {
  const info = await stat(file);
  const range = req.headers.range;
  if (range) {
    const [a, b] = range.replace('bytes=', '').split('-');
    const start = Number(a);
    const end = b ? Number(b) : info.size - 1;
    res.writeHead(206, {'content-type': type, 'content-length': end-start+1, 'content-range': `bytes ${start}-${end}/${info.size}`, 'accept-ranges': 'bytes', 'access-control-allow-origin': '*'});
    createReadStream(file, {start, end}).pipe(res);
    return;
  }
  res.writeHead(200, {'content-type': type, 'content-length': info.size, 'accept-ranges': 'bytes', 'access-control-allow-origin': '*'});
  createReadStream(file).pipe(res);
}

const server = createServer((req, res) => {
  const asset = assets[req.url];
  if (!asset) return res.writeHead(404).end();
  void send(req, res, asset[0], asset[1]);
});

server.listen(8124, '127.0.0.1', async () => {
  try {
    const props = {
      title: 'Production composition test',
      subtitle: 'Real StoryComposition code',
      debugLabel: 'local-production-test',
      segments: [
        {src: 'http://127.0.0.1:8124/video1', durationSeconds: 5, kind: 'video', caption: 'First test clip'},
        {src: 'http://127.0.0.1:8124/video2', durationSeconds: 5, kind: 'video', caption: 'Second test clip'},
      ],
      narrationUrl: 'http://127.0.0.1:8124/audio',
    };
    const serveUrl = await bundle({entryPoint: path.resolve('src/remotion-entry.tsx'), ignoreRegisterRootWarning: true});
    const selected = await selectComposition({serveUrl, id: 'StoryComposition', inputProps: props});
    await renderMedia({serveUrl, codec: 'h264', composition: {...selected, durationInFrames: 300}, inputProps: props, outputLocation: output, overwrite: true});
    console.log(`PRODUCTION_RENDER=${output}`);
  } finally {
    server.close();
  }
});