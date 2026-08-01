import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import { bundle } from "@remotion/bundler";
import { renderMedia } from "@remotion/renderer";

const downloads = process.env.USERPROFILE + "\\Downloads";
const video1 = path.join(downloads, "tt1.mp4");
const video2 = path.join(downloads, "tt2.mp4");
const audio = path.join(downloads, "Varnished Silence.mp3");
const output = path.join(downloads, "local-remotion-tt1-tt2.mp4");
const entryPoint = path.resolve('.tmp-remotion-local/entry.tsx');

async function sendFileWithRange(req, res, filePath, contentType) {
  const info = await stat(filePath);
  const rangeHeader = req.headers.range;
  if (typeof rangeHeader === 'string' && rangeHeader.startsWith('bytes=')) {
    const [startRaw, endRaw] = rangeHeader.slice('bytes='.length).split('-');
    const start = Number.parseInt(startRaw, 10);
    const end = endRaw ? Number.parseInt(endRaw, 10) : info.size - 1;
    if (Number.isNaN(start) || Number.isNaN(end) || start < 0 || end < start || end >= info.size) {
      res.writeHead(416, { 'content-range': `bytes */${info.size}`, 'access-control-allow-origin': '*' });
      res.end();
      return;
    }
    const chunkSize = end - start + 1;
    res.writeHead(206, {
      'content-type': contentType,
      'content-length': chunkSize,
      'content-range': `bytes ${start}-${end}/${info.size}`,
      'accept-ranges': 'bytes',
      'access-control-allow-origin': '*',
    });
    createReadStream(filePath, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, {
    'content-type': contentType,
    'content-length': info.size,
    'accept-ranges': 'bytes',
    'access-control-allow-origin': '*',
  });
  createReadStream(filePath).pipe(res);
}

const server = createServer((req, res) => {
  if (!req.url) {
    res.writeHead(400).end();
    return;
  }
  if (req.url.startsWith('/video1')) return void sendFileWithRange(req, res, video1, 'video/mp4');
  if (req.url.startsWith('/video2')) return void sendFileWithRange(req, res, video2, 'video/mp4');
  if (req.url.startsWith('/audio')) return void sendFileWithRange(req, res, audio, 'audio/mpeg');
  res.writeHead(404).end('not found');
});

server.listen(8123, '127.0.0.1', async () => {
  console.log('HTTP server ready on 8123');
  const serveUrl = await bundle({ entryPoint, ignoreRegisterRootWarning: true });
  console.log('bundle ready', serveUrl);
  await renderMedia({
    serveUrl,
    composition: { id: 'LocalTest', width: 1080, height: 1920, fps: 30, durationInFrames: 300, defaultProps: { video1: 'http://127.0.0.1:8123/video1', video2: 'http://127.0.0.1:8123/video2', audioUrl: 'http://127.0.0.1:8123/audio' } },
    codec: 'h264',
    outputLocation: output,
    overwrite: true,
    inputProps: { video1: 'http://127.0.0.1:8123/video1', video2: 'http://127.0.0.1:8123/video2', audioUrl: 'http://127.0.0.1:8123/audio' },
  });
  console.log('rendered', output);
  server.close();
});
