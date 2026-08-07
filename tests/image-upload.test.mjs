import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

const port = 18987;
const baseUrl = `http://127.0.0.1:${port}`;
const uploadDir = fileURLToPath(new URL("../.tmp-test-uploads", import.meta.url));

async function waitForServer() {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Test MCP server did not start");
}

test("raw image upload returns a public URL and serves the original bytes", async (t) => {
  const child = spawn(process.execPath, ["--import", "tsx", "src/server.ts"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      PORT: String(port),
      RUNPOD_BASE_URL: "http://127.0.0.1:65534",
      MCP_PUBLIC_BASE_URL: baseUrl,
      IMAGE_UPLOAD_DIR: uploadDir,
      IMAGE_UPLOAD_MAX_BYTES: "1024",
      LOG_LEVEL: "silent",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(async () => {
    child.kill("SIGTERM");
    await once(child, "exit").catch(() => {});
    await rm(uploadDir, { recursive: true, force: true });
  });
  await waitForServer();

  const png = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  ]);
  const upload = await fetch(`${baseUrl}/files/upload/image`, {
    method: "POST",
    headers: { "content-type": "image/png" },
    body: png,
  });

  assert.equal(upload.status, 201);
  const payload = await upload.json();
  assert.match(payload.image_url, new RegExp(`^${baseUrl.replaceAll(".", "\\.")}/files/generated/uploads/[0-9a-f-]+\\.png$`));

  const download = await fetch(payload.image_url);
  assert.equal(download.status, 200);
  assert.equal(download.headers.get("content-type"), "image/png");
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), png);
});
