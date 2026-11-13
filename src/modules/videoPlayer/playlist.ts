/**
 * 分段续转的播放列表拼接（纯函数，无 IO）。
 *
 * 每段是一次独立 ffmpeg 产物（自己的 init.mp4 + 分片，PTS 从 0 开始），
 * 所以段与段之间必须插 `#EXT-X-DISCONTINUITY`。各段的 init.mp4 内容相同，
 * 只写第一段的 `#EXT-X-MAP`（每段重复声明会让 libmpv 跨段解不出分片）。
 * 真 Chrome + hls.js 1.4.10 实测：
 * 接缝处会出现第二次 `FRAG_BUFFERED sn=initSegment`，播放能顺到 24s、
 * seek 到第二段也能起播，无 fatal。
 *
 * URI 用 `?part=pN` 标出所属分段，服务端按这个参数去子目录里取文件；
 * 这样 `/api/v1/player/hls/:session/:file` 的 `:file` 仍是纯文件名，
 * 不用放宽路径白名单（防目录穿越）。
 */
export interface PlaylistPart {
  /** 子目录名：p0 / p1 / ... */
  name: string;
  /** 该段自己的 index.m3u8 文本 */
  text: string;
}

/** 一段播放列表里所有 #EXTINF 的时长合计（毫秒） */
export function playlistDurationMs(text: string): number {
  let ms = 0;
  for (const raw of text.split('\n')) {
    const m = /^#EXTINF:\s*([\d.]+)/.exec(raw.trim());
    if (m) ms += Number(m[1]) * 1000;
  }
  return Math.round(ms);
}

const withPart = (file: string, part: string): string =>
  `${file}${file.includes('?') ? '&' : '?'}part=${encodeURIComponent(part)}`;

/** 取 URI / 分片行的文件名部分，丢掉 ffmpeg 可能写进来的绝对路径前缀 */
const basename = (uri: string): string => uri.split(/[\\/]/).pop() || uri;

/**
 * 把多段拼成一份 EVENT 播放列表。末尾**不写** `#EXT-X-ENDLIST`：
 * 后续分段还会追加，hls.js 需要保持 live 语义持续刷新。
 */
export function mergePlaylists(parts: PlaylistPart[]): string {
  const head = [
    '#EXTM3U',
    '#EXT-X-VERSION:7',
    '#EXT-X-TARGETDURATION:6',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:EVENT',
    // 转码产物是「从头播的整片」，但 EVENT 列表没有 ENDLIST，播放器会按直播语义
    // 从**末尾**几片起播（实测只拉 seg00027~29，接着就一直等新片）。
    // 明确要求从 0 秒开始，才有完整的 3 分钟可播内容。
    '#EXT-X-START:TIME-OFFSET=0',
  ];
  const body: string[] = [];
  // 各段 init.mp4 逐字节相同（同一套编码参数），只在第一段写一次 MAP。
  // 跨段重新声明会让 libmpv 重置 demuxer 却不重新拉 init，随后解不出分片
  // （Failed to recognize file format）。与 buildStaticVodPlaylist 保持一致。
  let mapWritten = false;
  parts.forEach(({ name, text }, i) => {
    if (i > 0) body.push('#EXT-X-DISCONTINUITY');
    for (const raw of text.replace(/\r/g, '').split('\n')) {
      const line = raw.trim();
      if (!line || line === '#EXTM3U') continue;
      if (/^#EXT-X-(VERSION|TARGETDURATION|MEDIA-SEQUENCE|PLAYLIST-TYPE|ENDLIST)/.test(line))
        continue;
      if (line.startsWith('#EXT-X-MAP')) {
        if (mapWritten) continue;
        mapWritten = true;
        const uri = /URI="([^"]+)"/.exec(line)?.[1] || 'init.mp4';
        body.push(`#EXT-X-MAP:URI="${withPart(basename(uri), name)}"`);
        continue;
      }
      if (line.startsWith('#')) {
        body.push(line);
        continue;
      }
      body.push(withPart(basename(line), name));
    }
  });
  return [...head, ...body, ''].join('\n');
}
