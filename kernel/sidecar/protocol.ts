/**
 * Sidecar 通信协议（§7.1）：stdin/stdout 上的 NDJSON，一行一条消息。
 *
 * 请求（内核 → sidecar）：
 *   {"id":"<uuid>","type":"ping"}
 *   {"id":"<uuid>","type":"invoke","method":"thumb","params":{...}}
 *   {"id":"<uuid>","type":"shutdown"}
 *
 * 应答（sidecar → 内核，必须带同一个 id）：
 *   {"id":"<uuid>","ok":true,"result":...}
 *   {"id":"<uuid>","ok":false,"error":{"code":"E_X","message":"..."}}
 *
 * 无 id 的主动消息：
 *   {"type":"event","event":"batch","data":{...}}      // 进度 / 数据流
 *   {"type":"log","level":"info","message":"..."}      // 走内核日志
 */

export type SidecarRequestPayload =
  | { type: 'ping' }
  | { type: 'invoke'; method: string; params?: unknown }
  | { type: 'shutdown' };

export type SidecarRequest = SidecarRequestPayload & { id: string };

export interface SidecarError {
  code: string;
  message: string;
}

export type SidecarResponse =
  | { id: string; ok: true; result?: unknown }
  | { id: string; ok: false; error: SidecarError };

export type SidecarLogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface SidecarEvent {
  type: 'event';
  event: string;
  data?: unknown;
}

export interface SidecarLog {
  type: 'log';
  level: SidecarLogLevel;
  message: string;
}

export type SidecarOutbound = SidecarResponse | SidecarEvent | SidecarLog;

export function isResponse(msg: unknown): msg is SidecarResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    typeof (msg as { id?: unknown }).id === 'string' &&
    typeof (msg as { ok?: unknown }).ok === 'boolean'
  );
}

export function isEvent(msg: unknown): msg is SidecarEvent {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    (msg as { type?: unknown }).type === 'event' &&
    typeof (msg as { event?: unknown }).event === 'string'
  );
}

export function isLog(msg: unknown): msg is SidecarLog {
  return (
    typeof msg === 'object' && msg !== null && (msg as { type?: unknown }).type === 'log'
  );
}

/**
 * 按行拆帧：处理 TCP/pipe 的半包与粘包。
 * 单行上限用于防止异常 sidecar 打出无换行巨串撑爆内存。
 */
export class NdjsonDecoder {
  private buffer = '';

  constructor(private readonly maxLineBytes = 8 * 1024 * 1024) {}

  push(chunk: string): unknown[] {
    this.buffer += chunk;
    const out: unknown[] = [];

    let idx = this.buffer.indexOf('\n');
    while (idx >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (line.length > 0) {
        try {
          out.push(JSON.parse(line));
        } catch {
          out.push({ type: 'log', level: 'warn', message: `bad ndjson line: ${line.slice(0, 200)}` });
        }
      }
      idx = this.buffer.indexOf('\n');
    }

    if (this.buffer.length > this.maxLineBytes) {
      out.push({
        type: 'log',
        level: 'error',
        message: `ndjson line exceeded ${this.maxLineBytes} bytes, buffer truncated`,
      });
      this.buffer = '';
    }

    return out;
  }

  /** 进程退出时冲刷残留（无反斜杠换行的情况） */
  flush(): unknown[] {
    const rest = this.buffer.trim();
    this.buffer = '';
    if (!rest) return [];
    try {
      return [JSON.parse(rest)];
    } catch {
      return [];
    }
  }
}

export function encodeRequest(req: SidecarRequest): string {
  return JSON.stringify(req) + '\n';
}