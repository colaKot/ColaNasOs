type Handler = (payload: unknown) => void;

/** 对外暴露的事件（带单调序号，供客户端增量拉取） */
export interface BusEvent {
  seq: number;
  topic: string;
  at: number;
  data: unknown;
}

/**
 * 进程内事件总线；单个 handler 抛错不影响其他 handler。
 *
 * 额外保留一份**环形历史**（默认 256 条），让客户端可以「带序号增量拉取」：
 * `GET /api/v1/events/recent?since=<seq>`。媒体扫描是分钟级低频事件，
 * 短轮询（客户端每 4 s 拉一次）比 SSE 更省事：不用改 Transport 抽象，桌面 / Web / 移动一致。
 * payload 只放小对象（域、库、计数），不要塞列表。
 */
const HISTORY_LIMIT = 256;

export class EventBus {
  private handlers = new Map<string, Set<Handler>>();
  private seq = 0;
  private history: BusEvent[] = [];

  on(topic: string, h: Handler): () => void {
    const set = this.handlers.get(topic) ?? new Set<Handler>();
    set.add(h);
    this.handlers.set(topic, set);
    return () => this.off(topic, h);
  }

  off(topic: string, h: Handler): void {
    this.handlers.get(topic)?.delete(h);
  }

  emit(topic: string, payload?: unknown): number {
    this.seq += 1;
    this.history.push({ seq: this.seq, topic, at: Date.now(), data: payload ?? null });
    if (this.history.length > HISTORY_LIMIT) {
      this.history.splice(0, this.history.length - HISTORY_LIMIT);
    }

    const set = this.handlers.get(topic);
    if (!set) return 0;
    let delivered = 0;
    for (const h of [...set]) {
      try {
        h(payload);
        delivered++;
      } catch {
        /* 隔离单个监听器异常 */
      }
    }
    return delivered;
  }

  /** 按序号增量读取；`since` 为上次拿到的 `nextSeq` */
  eventsSince(since = 0, limit = 100): { items: BusEvent[]; nextSeq: number } {
    const capped = Math.max(1, Math.min(limit, HISTORY_LIMIT));
    const items = this.history.filter((e) => e.seq > since).slice(0, capped);
    const nextSeq = items.length > 0 ? items[items.length - 1].seq : Math.max(0, since);
    return { items, nextSeq };
  }

  topics(): string[] {
    return [...this.handlers.keys()];
  }

  /** 当前最大序号（客户端首次连接时可先读它跳过历史） */
  get cursor(): number {
    return this.seq;
  }
}