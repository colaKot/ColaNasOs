import fs from 'node:fs';
import path from 'node:path';

/**
 * 本地小模型（llama.cpp / GGUF）的路径解析。
 *
 * 目前只有一处用途：AI 新闻的「英转中」。模型是 Qwen3-1.7B-Q4_K_M（约 1.0GB），
 * **不进安装包**（`electron-builder.js` 里 `!mt/**` 排除了），由 `npm run mt:model`
 * 或用户在设置页触发下载。所以查找顺序必须包含用户数据目录。
 *
 * 与 `kernel/tts/paths.ts` 的分工：那边找 `llama-tts`（语音克隆），这边找
 * `llama-server`（常驻 HTTP 服务，翻译是逐条短请求，起进程的开销摊不平）。
 */

export interface LlmPaths {
  bin: string | null;
  modelDir: string | null;
  model: string | null;
}

const BIN_NAME = process.platform === 'win32' ? 'llama-server.exe' : 'llama-server';

/** `win32-x64` / `darwin-arm64` / `linux-x64`：预编译包按平台分目录放 */
export function platformTag(): string {
  return `${process.platform}-${process.arch}`;
}

function resourcesPath(): string | undefined {
  return (process as unknown as { resourcesPath?: string }).resourcesPath;
}

/** 除了仓库根与 resources，还要看用户数据目录（模型按需下载时落在那里） */
function roots(dataDir?: string): string[] {
  const out: string[] = [];
  const res = resourcesPath();
  if (res) out.push(res);
  if (dataDir) out.push(dataDir);
  out.push(process.cwd());
  // dist/kernel/llm → 仓库根
  out.push(path.join(__dirname, '..', '..'));
  out.push(path.join(__dirname, '..', '..', '..'));
  return [...new Set(out)];
}

function firstFile(candidates: string[]): string | null {
  for (const p of candidates) {
    try {
      if (fs.statSync(p).isFile()) return p;
    } catch {
      // 不存在就下一个
    }
  }
  return null;
}

function firstDir(candidates: string[]): string | null {
  for (const p of candidates) {
    try {
      if (fs.statSync(p).isDirectory()) return p;
    } catch {
      // 同上
    }
  }
  return null;
}

/** `llama-server` 可执行文件；`COLANAS_LLM_BIN` 可直指文件 */
export function llmBinPath(): string | null {
  const env = (process.env.COLANAS_LLM_BIN || '').trim();
  if (env) return firstFile([env]);
  const cands: string[] = [];
  for (const root of roots()) {
    cands.push(path.join(root, 'llama', platformTag(), BIN_NAME));
    cands.push(path.join(root, 'llama', BIN_NAME));
    cands.push(path.join(root, 'vendor', 'llama', platformTag(), BIN_NAME));
  }
  return firstFile(cands);
}

/** 翻译模型目录：`COLANAS_MT_DIR` > resources/models/mt > <dataDir>/models/mt > vendor/models/mt */
export function llmModelDir(dataDir?: string): string | null {
  const env = (process.env.COLANAS_MT_DIR || '').trim();
  if (env) return firstDir([env]);
  const cands: string[] = [];
  for (const root of roots(dataDir)) {
    cands.push(path.join(root, 'models', 'mt'));
    cands.push(path.join(root, 'vendor', 'models', 'mt'));
  }
  return firstDir(cands);
}

/** 目录里挑一个 .gguf：先按模型档位（1.7B 优先），再按量化档位（Q4_K_M 优先） */
export function pickGguf(dir: string): string | null {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return null;
  }
  // 0.6B 实测专名错得离谱（Republicans → 美国和德国），只在没有 1.7B 时兜底
  const score = (n: string): number => {
    const gen = /1\.7b/i.test(n) ? 0 : /0\.6b/i.test(n) ? 1 : 2;
    const quant = /q4_k_m/i.test(n) ? 0 : /q5_k_m/i.test(n) ? 1 : /q4_k_s/i.test(n) ? 2 : /q8_0/i.test(n) ? 3 : 4;
    return gen * 10 + quant;
  };
  const hits = names
    .filter((n) => n.toLowerCase().endsWith('.gguf'))
    .sort((a, b) => score(a) - score(b));
  return hits.length ? path.join(dir, hits[0]) : null;
}

export function resolveLlmPaths(dataDir?: string): LlmPaths {
  const modelDir = llmModelDir(dataDir);
  return {
    bin: llmBinPath(),
    modelDir,
    model: modelDir ? pickGguf(modelDir) : null,
  };
}
