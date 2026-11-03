import { sql } from 'kysely';
import { scanMusicLibrary, type MusicLibraryRow } from './scan';
import { TrackRow, PlaylistRow } from './util';
import type { KernelApi } from '../../../kernel/types';

/** 音乐库 register 作用域内的闭包辅助函数（原样抽出，工厂化） */
export function makeMusicHelpers(k: KernelApi, libWatch: { refresh(): Promise<void> | void }) {
    const ref = (id: string) => ({ $ref: `${id}#` });

    const limitOf = (raw: unknown, def: number, max: number) =>
      Math.max(1, Math.min(Number(raw ?? def) || def, max));

    const loadLibrary = async (id: string): Promise<MusicLibraryRow | null> => {
      const res = await sql<MusicLibraryRow>`select * from music_libraries where id = ${id}`.execute(
        k.db,
      );
      return res.rows[0] ?? null;
    };

    const loadTrack = async (id: string): Promise<TrackRow | null> => {
      const res = await sql<TrackRow>`select * from music_tracks where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    const loadPlaylist = async (id: string, owner: string): Promise<PlaylistRow | null> => {
      const res = await sql<PlaylistRow>`
        select p.id, p.name, p.owner_id, p.created_at,
          (select count(*) from music_playlist_items i where i.playlist_id = p.id) as tracks,
          (select t.id from music_playlist_items i
             join music_tracks t on t.id = i.track_id
            where i.playlist_id = p.id and t.has_cover = 1
            order by i.position limit 1) as cover_track_id
          from music_playlists p
         where p.id = ${id} and p.owner_id = ${owner}
      `.execute(k.db);
      return res.rows[0] ?? null;
    };
  return { ref, limitOf, loadLibrary, loadTrack, loadPlaylist, libWatch };
}

export type MusicHelpers = ReturnType<typeof makeMusicHelpers>;
