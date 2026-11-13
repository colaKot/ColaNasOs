import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { resolveTtsPaths, setTtsHome } from './paths';

/**
 * 语音模型的「一键下载」状态机。
 *
 * 设计要点：
 *   1. **已下载状态不写标记文件**，每次 status() 直接探测磁盘。
 *      这样重装/换目录/手删模型都不会出现「界面说已下载、实际跑不了」的假状态，
 *      用户下次进来自然还是「已下载」（文件还在）。
 *   2. 下载器是独立的 `tool/tts-model.js`，以 `--json` 输出 NDJSON 进度事件；
 *      内核只解析事件、不管网络，避免把下载逻辑复制两份。
 *   3. 目标目录是 `<dataDir>/tts`（用户可写、升级不丢），通过 `setTtsHome` 注入 paths.ts。
 *   4. Windows NAS 单平台：脚本里已经拒绝其它平台，这里也只是原样透传。
 */

export interface TtsModelStatus {
  /** 磁盘上二进制 + 两个 gguf 是否齐备（每次实时探测） */
  installed: boolean;
  downloading: boolean;
  /** 0~100，跨三个文件加权：推理程序 3% / 主模型 67% / 声码器 30% */
  percent: number;
  /** 当前阶段的人话描述，如「下载 主模型」「校验 声码器」（排障用，UI 不直接展示） */
  phase: string;
  /** 当前任务 id：bin / model1 / model2 / done / error / idle，给前端选文案 */
  task: string;
  error: string | null;
  binReady: boolean;
  modelReady: boolean;
  /** 模型所在目录（给设置页显示/排障） */
  modelDir: string | null;
}

interface State {
  downloading: boolean;
  percent: number;
  phase: string;
  task: string;
  error: string | null;
}

/** 统一构造状态，避免每处赋值漏掉 task 字段 */
function state(patch: Partial<State>): State {
  return { downloading: false, percent: 0, phase: '', task: 'idle', error: null, ...patch };
}

function resolveScript(): string | null {
  const env = (process.env.COLANAS_TTS_MODEL_SCRIPT || '').trim();
  if (env && fs.existsSync(env)) return env;
  const res = (process as unknown as { resourcesPath?: string }).resourcesPath;
  const candidates = [
    ...(res ? [path.join(res, 'tool', 'tts-model.js')] : []),
    path.join(__dirname, '..', '..', '..', 'tool', 'tts-model.js'),
    path.join(process.cwd(), 'tool', 'tts-model.js'),
  ];
  return candidates.find((p) => fs.existsSync(p)) ?? null;
}

/** 一键下载的落点（即使还没下，也要能告诉用户「该放哪」） */
function expectedModelDir(home: string | null): string {
  const base = home || path.join(process.cwd(), '.devdata', 'tts');
  return path.join(base, 'models', 'qwen3-tts');
}

function probe(downloadHome: string | null): {
  installed: boolean;
  binReady: boolean;
  modelReady: boolean;
  modelDir: string | null;
} {
  const p = resolveTtsPaths();
  const binReady = Boolean(p.bin && fs.existsSync(p.bin));
  const modelReady = Boolean(
    p.model && p.mmproj && fs.existsSync(p.model) && fs.existsSync(p.mmproj),
  );
  return {
    installed: binReady && modelReady,
    binReady,
    modelReady,
    // 未下载时也回传期望目录：页面要显示「手动下载放这里」，不能让人猜路径
    modelDir: p.modelDir ?? expectedModelDir(downloadHome),
  };
}

class TtsModelManager {
  private child: ChildProcessWithoutNullStreams | null = null;
  private home: string | null = null;
  private state: State = state({});

  /** 模块注册时调用：把用户数据目录注入路径解析（装机版的可写目录） */
  configure(dataDir: string): void {
    this.home = path.join(dataDir, 'tts');
    setTtsHome(this.home);
  }

  status(): TtsModelStatus {
    // 子进程意外退出但没发 done/error 时，别让界面永远转圈
    if (this.state.downloading && !this.child) {
      this.state = state({ error: '下载进程已退出，请重试', task: 'error' });
    }
    const p = probe(this.home);
    if (p.installed && this.state.downloading) {
      // 文件已经齐了（比如用户手工放进去），即使下载进程还在跑也直接收尾
      this.child = null;
      this.state = state({ percent: 100, phase: '语音模型已下载', task: 'done' });
    }
    return {
      ...p,
      ...this.state,
      // 文件齐了就算已下载，不管上一次是不是失败过：模型还在 → 每次进页面都是「已下载」
      phase: p.installed ? '语音模型已下载' : this.state.phase,
      percent: p.installed ? 100 : this.state.percent,
      task: p.installed ? 'done' : this.state.task,
      error: p.installed ? null : this.state.error,
    };
  }

  start(): TtsModelStatus {
    const before = this.status();
    if (before.installed || before.downloading) return before;

    const script = resolveScript();
    if (!script) {
      this.state = state({
        error: '找不到下载脚本 tool/tts-model.js（安装包可能不完整）',
        task: 'error',
      });
      return this.status();
    }
    const home = this.home || path.join(process.cwd(), '.devdata', 'tts');
    setTtsHome(home);
    this.state = state({ downloading: true, phase: '准备下载', task: 'bin' });

    const args = [script, '--json', `--dest=${home}`];
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
        // 进程走了但没发 done/error：多半是被取消或被系统杀掉
        const p = probe(this.home);
        if (!p.installed) this.finish('下载中断（网络或进程被关闭），可重试，已下载部分会自动续传');
        else this.state = state({ percent: 100, phase: '语音模型已下载', task: 'done' });
      }
    });
    return this.status();
  }

  cancel(): TtsModelStatus {
    const child = this.child;
    this.child = null;
    if (child && !child.killed) child.kill();
    this.state = state({
      percent: this.state.percent,
      phase: '已取消',
      task: 'idle',
    });
    return this.status();
  }

  private finish(error: string): void {
    this.child = null;
    this.state = state({
      percent: this.state.percent,
      task: 'error',
      error,
    });
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
          phase: label.startsWith('校验') ? label : `下载 ${label}`,
          task: String(ev.task || this.state.task),
        });
        break;
      }
      case 'progress': {
        const percent = Number(ev.percent);
        this.state = state({
          downloading: true,
          percent: Number.isFinite(percent) ? Math.max(0, Math.min(100, percent)) : this.state.percent,
          phase: this.state.phase || '下载中',
          task: String(ev.task || this.state.task),
        });
        break;
      }
      case 'done': {
        this.child = null;
        this.state = state({ percent: 100, phase: '语音模型已下载', task: 'done' });
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

export const ttsModel = new TtsModelManager();
