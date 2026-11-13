import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { llmModelDir, pickGguf } from './paths';

/**
 * 本地翻译模型（Qwen3-1.7B GGUF）的一键下载状态机。
 *
 * 与 `kernel/tts/download.ts` 同构，三处差异：
 *   1. 只有一个文件（约 1.0GB），进度直接来自脚本的 progress 事件；
 *   2. 下载目标 `<dataDir>/models/mt`，与 `llmModelDir(dataDir)` 的搜索路径对齐；
 *   3. 多源自动切换（ModelScope → HF 镜像 → HuggingFace）在脚本里完成，
 *      这里只把「切换下载源」的 phase 转成界面可读的提示。
 *
 * 已下载状态**不写标记文件**，每次 status() 实时探测磁盘：
 * 用户手工放模型、换目录、删文件都不会出现「界面说已下载、实际跑不了」。
 */

export interface MtModelStatus {
  installed: boolean;
  downloading: boolean;
  /** 0~100 */
  percent: number;
  /** 当前阶段的人话描述（排障用，UI 不直接展示） */
  phase: string;
  /** model / done / error / idle：前端据此选本地化文案 */
  task: string;
  error: string | null;
  modelDir: string | null;
  /** 标称体积（MB），界面显示「约 1.0 GB」用 */
  sizeMb: number;
}

interface State {
  downloading: boolean;
  percent: number;
  phase: string;
  task: string;
  error: string | null;
}

/** 1.7B Q4_K_M 的标称体积，与 tool/mt-model.js 的 MODELS 保持一致 */
const SIZE_MB = 1056;

function state(patch: Partial<State>): State {
  return { downloading: false, percent: 0, phase: '', task: 'idle', error: null, ...patch };
}

function resolveScript(): string | null {
  const env = (process.env.COLANAS_MT_MODEL_SCRIPT || '').trim();
  if (env && fs.existsSync(env)) return env;
  const res = (process as unknown as { resourcesPath?: string }).resourcesPath;
  const candidates = [
    ...(res ? [path.join(res, 'tool', 'mt-model.js')] : []),
    path.join(__dirname, '..', '..', '..', 'tool', 'mt-model.js'),
    path.join(process.cwd(), 'tool', 'mt-model.js'),
  ];
  return candidates.find((p) => fs.existsSync(p)) ?? null;
}

class MtModelManager {
  private child: ChildProcessWithoutNullStreams | null = null;
  private dataDir: string | null = null;
  private state: State = state({});

  /** 模块注册时调用：记住用户数据目录（模型落在它下面的 models/mt） */
  configure(dataDir: string): void {
    this.dataDir = dataDir;
  }

  private probe(): { installed: boolean; modelDir: string | null } {
    const dir = llmModelDir(this.dataDir ?? undefined);
    // 未下载时也回传期望目录：页面要显示「手动下载放这里」
    return { installed: Boolean(dir && pickGguf(dir)), modelDir: dir ?? this.targetDir() };
  }

  private targetDir(): string {
    const base = this.dataDir || path.join(process.cwd(), '.devdata');
    return path.join(base, 'models', 'mt');
  }

  status(): MtModelStatus {
    // 子进程意外退出但没发 done/error 时，别让界面永远转圈
    if (this.state.downloading && !this.child) {
      this.state = state({ error: '下载进程已退出，请重试', task: 'error' });
    }
    const p = this.probe();
    if (p.installed && this.state.downloading) {
      this.child = null;
      this.state = state({ percent: 100, phase: '翻译模型已下载', task: 'done' });
    }
    return {
      ...p,
      ...this.state,
      phase: p.installed ? '翻译模型已下载' : this.state.phase,
      percent: p.installed ? 100 : this.state.percent,
      task: p.installed ? 'done' : this.state.task,
      error: p.installed ? null : this.state.error,
      sizeMb: SIZE_MB,
    };
  }

  start(): MtModelStatus {
    const before = this.status();
    if (before.installed || before.downloading) return before;

    const script = resolveScript();
    if (!script) {
      this.state = state({
        error: '找不到下载脚本 tool/mt-model.js（安装包可能不完整）',
        task: 'error',
      });
      return this.status();
    }
    const dir = this.targetDir();
    this.state = state({ downloading: true, phase: '准备下载', task: 'model' });

    const args = [script, '--json', `--dest=${dir}`];
    const env = {
      ...process.env,
      // Electron 外壳里用同一个可执行文件当 Node 跑脚本
      ELECTRON_RUN_AS_NODE: '1',
      PYTHONUTF8: '1',
    };
    const child = spawn(process.execPath, args, { env, windowsHide: true });
    this.child = child;

    let buf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buf += chunk;
      let i = buf.indexOf('\n');
      while (i >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) this.onEvent(line);
        i = buf.indexOf('\n');
      }
    });
    child.stderr.on('data', () => {
      // 人类可读日志，内核不解析
    });
    child.on('error', (e) => {
      this.finish(`无法启动下载进程：${e.message}`);
    });
    child.on('close', () => {
      const wasMine = this.child === child;
      this.child = null;
      if (wasMine && this.state.downloading) {
        const p = this.probe();
        if (!p.installed) {
          this.finish('下载中断（网络或进程被关闭），可重试，已下载部分会自动续传');
        } else {
          this.state = state({ percent: 100, phase: '翻译模型已下载', task: 'done' });
        }
      }
    });
    return this.status();
  }

  cancel(): MtModelStatus {
    const child = this.child;
    this.child = null;
    if (child && !child.killed) child.kill();
    this.state = state({ percent: this.state.percent, phase: '已取消', task: 'idle' });
    return this.status();
  }

  private finish(error: string): void {
    this.child = null;
    this.state = state({ percent: this.state.percent, task: 'error', error });
  }

  private onEvent(line: string): void {
    let ev: Record<string, unknown>;
    try {
      ev = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return; // 混入的非 JSON 行直接忽略
    }
    switch (ev.type) {
      case 'phase': {
        const label = String(ev.label || '');
        this.state = state({
          downloading: true,
          percent: this.state.percent,
          phase: label.startsWith('切换下载源') ? label : `下载 ${label}`,
          task: String(ev.task || this.state.task),
        });
        break;
      }
      case 'progress': {
        const percent = Number(ev.percent);
        this.state = state({
          downloading: true,
          percent: Number.isFinite(percent)
            ? Math.max(0, Math.min(100, percent))
            : this.state.percent,
          phase: this.state.phase || '下载中',
          task: String(ev.task || this.state.task),
        });
        break;
      }
      case 'done': {
        this.child = null;
        this.state = state({ percent: 100, phase: '翻译模型已下载', task: 'done' });
        break;
      }
      case 'error': {
        this.finish(String(ev.message || '下载失败'));
        break;
      }
      default:
        break;
    }
  }
}

export const mtModel = new MtModelManager();
