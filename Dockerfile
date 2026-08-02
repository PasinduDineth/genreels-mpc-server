FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-bookworm-slim
WORKDIR /app

# Whisper.cpp compiles on first use. Remotion downloads Chrome Headless Shell
# and requires these shared libraries to render video in a Linux container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    ffmpeg \
    git \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgbm1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnss3 \
    libnspr4 \
    libpango-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
# The Remotion bundler resolves this TSX entrypoint at render time.
COPY src ./src

ENV NODE_ENV=production \
    PORT=8787 \
    REMOTION_OUTPUT_DIR=/workspace/generated/remotion \
    REMOTION_JOB_DIR=/workspace/ai-stack/run/remotion-jobs

RUN mkdir -p "$REMOTION_OUTPUT_DIR" "$REMOTION_JOB_DIR"

EXPOSE 8787
CMD ["node", "dist/server.js"]
