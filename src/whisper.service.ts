import { exec, execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import {
  downloadWhisperModel,
  installWhisperCpp,
  toCaptions,
  transcribe,
} from '@remotion/install-whisper-cpp';
import type { Caption } from '@remotion/captions';
import {
  WHISPER_BINARY_PATH,
  WHISPER_LANG,
  WHISPER_MODEL,
  WHISPER_MODEL_PATH,
  WHISPER_VERSION,
} from './whisper-config.js';

const execAsync = promisify(exec);
const execFileAsync = promisify(execFile);
let whisperSetupPromise: Promise<void> | null = null;

const getWhisperExecutablePath = (whisperPath: string, whisperCppVersion: string) => {
  const useCliBinary = compareVersions(whisperCppVersion, '1.7.4') >= 0;
  const binFolder = useCliBinary ? ['build', 'bin'] : [];
  const binName = useCliBinary ? 'whisper-cli.exe' : 'main.exe';

  return path.join(whisperPath, ...binFolder, binName);
};

const compareVersions = (left: string, right: string) => {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);
  const maxLength = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftParts[index] ?? 0;
    const rightPart = rightParts[index] ?? 0;

    if (leftPart > rightPart) return 1;
    if (leftPart < rightPart) return -1;
  }

  return 0;
};

const getTempWavePath = (audioPath: string) => {
  const parsedPath = path.parse(audioPath);
  return path.join(parsedPath.dir, `${parsedPath.name}.16khz.wav`);
};

const convertAudioToWhisperWave = async (inputPath: string, outputPath: string) => {
  const args = ['-i', inputPath, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', outputPath, '-y'];

  try {
    await execFileAsync('ffmpeg', args, { windowsHide: true });
    return;
  } catch {
    const escapedInput = inputPath.replaceAll('"', '\\"');
    const escapedOutput = outputPath.replaceAll('"', '\\"');
    const fallbackCommand = `npx remotion ffmpeg -i "${escapedInput}" -ar 16000 -ac 1 -c:a pcm_s16le "${escapedOutput}" -y`;
    await execAsync(fallbackCommand, { windowsHide: true });
  }
};

const ensureWhisperAssets = async () => {
  if (!whisperSetupPromise) {
    whisperSetupPromise = (async () => {
      const executablePath = getWhisperExecutablePath(WHISPER_BINARY_PATH, WHISPER_VERSION);
      try {
        await fs.access(executablePath);
      } catch {
        await fs.rm(WHISPER_BINARY_PATH, { force: true, recursive: true });
        await installWhisperCpp({ printOutput: false, to: WHISPER_BINARY_PATH, version: WHISPER_VERSION });
      }

      await fs.mkdir(WHISPER_MODEL_PATH, { recursive: true });
      await downloadWhisperModel({ folder: WHISPER_MODEL_PATH, model: WHISPER_MODEL, printOutput: false });
    })();
  }

  return whisperSetupPromise;
};

export const transcribeNarrationAudio = async ({
  audioPath,
  captionOutputPath,
}: {
  audioPath: string;
  captionOutputPath: string;
}): Promise<Caption[]> => {
  await ensureWhisperAssets();
  const tempWavePath = getTempWavePath(audioPath);

  try {
    await convertAudioToWhisperWave(audioPath, tempWavePath);
    const whisperCppOutput = await transcribe({
      inputPath: tempWavePath,
      language: WHISPER_LANG,
      model: WHISPER_MODEL,
      modelFolder: WHISPER_MODEL_PATH,
      printOutput: false,
      splitOnWord: true,
      tokenLevelTimestamps: true,
      translateToEnglish: false,
      whisperCppVersion: WHISPER_VERSION,
      whisperPath: WHISPER_BINARY_PATH,
    });
    const { captions } = toCaptions({ whisperCppOutput });
    await fs.writeFile(captionOutputPath, JSON.stringify(captions, null, 2), 'utf8');
    return captions;
  } finally {
    await fs.rm(tempWavePath, { force: true });
  }
};
