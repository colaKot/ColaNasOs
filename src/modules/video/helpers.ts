import { sql } from 'kysely';
import { scanVideoLibrary, type VideoLibraryRow } from './scan';
import { MediaRow, VideoItemRow } from './util';
import type { KernelApi } from '../../../kernel/types';

/** 影视库 register 作用域内的闭包辅助函数（原样抽出，工厂化） */
export function makeVideoHelpers(k: KernelApi, libWatch: { refresh(): Promise<void> | void }) {
    const ref = (id: string) => ({ $ref: `${id}#` });

    const limitOf = (raw: unknown, def: number, max: number) =>
      Math.max(1, Math.min(Number(raw ?? def) || def, max));

    const loadLibrary = async (id: string): Promise<VideoLibraryRow | null> => {
      const res =
        await sql<VideoLibraryRow>`select * from video_libraries where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    const loadItem = async (id: string): Promise<VideoItemRow | null> => {
      const res = await sql<VideoItemRow>`select * from video_items where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    /** 详情 / 海报共用：视频表没有就去图片表，图片行也转成与视频同构的 MediaRow */
    const loadAnyItem = async (id: string): Promise<MediaRow | null> => {
      const video = await loadItem(id);
      if (video) return video;
      const res = await sql<{
        id: string;
        library_id: string;
        rel_path: string;
        title: string;
        size: number;
        mtime: number;
        width: number | null;
        height: number | null;
        taken_at: number | null;
        mime: string;
      }>`select * from image_items where id = ${id}`.execute(k.db);
      const img = res.rows[0];
      if (!img) return null;
      return {
        id: img.id,
        library_id: img.library_id,
        rel_path: img.rel_path,
        title: img.title,
        duration: null,
        width: img.width,
        height: img.height,
        video_codec: null,
        audio_codec: null,
        container: img.mime || '',
        has_subtitle: 0,
        size: img.size,
        mtime: img.mtime,
        series: null,
        season: null,
        episode: null,
        media_type: 'image',
        taken_at: img.taken_at,
      };
    };
  return { ref, limitOf, loadLibrary, loadItem, loadAnyItem, libWatch };
}

export type VideoHelpers = ReturnType<typeof makeVideoHelpers>;
