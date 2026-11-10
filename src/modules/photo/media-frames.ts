import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import type { KernelApi } from '../../../kernel/types';

/**
 * 视频 / 动态照片抽帧，喂给 photo-ai 的 analyze。
 *
 * analyze 只认「一个能解出静态图的路径」，所以这里先把需要的帧落成临时 JPEG：
 *   - 视频：`k.media.thumb(src, dst, 960, at)`（`-ss` 快速定位）
 *   - 动态照片：尾部那段 mp4 不在独立文件里，先按字节区间切出来成临时 mp4 再抽帧
 *
 * 临时文件统一放在 `<dataDir>/photo-ai-frames/`，调用方拿到 `cleanup()` 后删。
 * 抽帧分辨率 960：和静态图 OCR 那条路一致，再大只是白烧 CPU。
 */

/** 抽帧目标宽度：与 sidecar 里静态图的最长边口径对齐 */
const FRAME_SIZE = 960;

function tmpDir(k: KernelApi): string {
  return path.join(k.paths.dataDir, 'photo-ai-frames');
}

function tmpName(): string {
  return `${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
}

/**
 * 视频按比例取帧：`count` 帧均匀分布在 8%~92% 之间。
 * 首尾各留 8% 是因为片头片尾常是黑场 / 台标，抽到那里等于没抽。
 */
export function frameTimes(durationMs: number | null, count = 1): number[] {
  const dur = Math.max(0, Number(durationMs) || 0) / 1000;
  if (count <= 1) return [dur > 0 ? dur * 0.5 : 0.5];
  const out: number[] = [];
  for (let i = 0; i < count; i += 1) {
    const ratio = count === 1 ? 0.5 : 0.08 + (0.84 * i) / (count - 1);
    out.push(dur > 0 ? dur * ratio : 0.5 + i);
  }
  return out;
}

/** 从视频（或尾部带 mp4 的 JPEG）抽帧，返回临时 JPEG 路径；失败返回空数组 */
export async function extractFrames(
  k: KernelApi,
  abs: string,
  opts: { durationMs?: number | null; liveSize?: number | null; count?: number },
): Promise<{ files: string[]; cleanup: () => Promise<void> }> {
  const count = Math.max(1, Math.min(opts.count ?? 1, 5));
  const dir = tmpDir(k);
  const tag = tmpName();
  const created: string[] = [];
  const cleanup = async () => {
    for (const f of created) await fsp.rm(f, { force: true }).catch(() => undefined);
  };

  if (!k.media.available()) return { files: [], cleanup };

  try {
    await fsp.mkdir(dir, { recursive: true });
    let source = abs;
    const live = Number(opts.liveSize) || 0;
    if (live > 0) {
      // 动态照片：尾部 live 个字节才是一段独立 mp4，直接 ffmpeg 读整张 JPEG 解不出来
      const st = await fsp.stat(abs);
      const start = st.size - live;
      if (start <= 0) return { files: [], cleanup };
      const cut = path.join(dir, `${tag}-tail.mp4`);
      const fh = await fsp.open(cut, 'w');
      try {
        const rs = fs.createReadStream(abs, { start, end: st.size - 1 });
        for await (const chunk of rs) {
          await fh.write(chunk as Buffer);
        }
      } finally {
        await fh.close();
      }
      created.push(cut);
      source = cut;
    }

    const times = frameTimes(opts.durationMs ?? null, count);
    for (let i = 0; i < times.length; i += 1) {
      const out = path.join(dir, `${tag}-${i}.jpg`);
      try {
        await k.media.thumb(source, out, FRAME_SIZE, times[i]);
        if (fs.existsSync(out)) created.push(out);
      } catch (err) {
        k.log.debug({ err: String(err), at: times[i], src: abs }, 'frame extract failed');
      }
    }
    return { files: created.filter((f) => f.endsWith('.jpg')), cleanup };
  } catch (err) {
    k.log.warn({ err: String(err), src: abs }, 'extractFrames failed');
    await cleanup();
    return { files: [], cleanup };
  }
}
