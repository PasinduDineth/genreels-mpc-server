import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { WhisperModel, Language } from '@remotion/install-whisper-cpp';

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(currentDirectory, '..');

export const WHISPER_BINARY_PATH = path.join(workspaceRoot, 'whisper.cpp-bin');
export const WHISPER_MODEL_PATH = path.join(workspaceRoot, 'whisper.cpp-models');
export const WHISPER_VERSION = '1.6.0';
export const WHISPER_MODEL: WhisperModel = 'base';
export const WHISPER_LANG: Language = 'auto';
