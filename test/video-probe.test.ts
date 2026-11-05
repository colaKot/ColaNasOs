import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { parseProbeStderr } from '../src/modules/video/ffmpeg';

/**
 * `ffmpeg -i` 的 stderr 解析。
 *
 * 重点是 HDR / DV 段：这些标记写在 `Side data:` 下面的**缩进子行**里，既不
 * 含 `Stream #` 也不含 `Side data:`。早前只保留含这两个关键字的行，等于把
 * 整块 Side data 丢掉，于是 DV / HDR10 片源全部落库成 SDR —— 播放时 HDR→SDR
 * 链路整条不启用，DV P5 的 IPTPQc2 直出成偏绿偏紫。这组用例钉的就是这条。
 */

// 真实片源（DV Profile 5，Stream 行一个色彩标记都没有）
const DV5 = `Input #0, matroska,webm, from 'D:/movie/movie/给阿嬷的情书.Dear.You.2026.2160p.YK.HQ.WEB-DL.H265.DV.AAC-ADWeb.mkv':
  Metadata:
    encoder         : libebml v1.4.5 + libmatroska v1.7.1
  Duration: 01:58:36.01, start: 0.000000, bitrate: 27153 kb/s
  Stream #0:0: Video: hevc (Main 10), yuv420p10le(pc), 3840x2080, SAR 1:1 DAR 24:13, 24 fps (default)
    Metadata:
      BPS             : 26638105
    Side data:
      DOVI configuration record: version: 1.0, profile: 5, level: 6, rpu flag: 1, el flag: 0, bl flag: 1
  Stream #0:1: Audio: aac (LC), 44100 Hz, stereo, fltp (default)
`;

// HDR10：Mastering display metadata 同样在 Side data 子行里
const HDR10 = `Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'C:/x/hdr10.mkv':
  Duration: 00:10:00.00, start: 0.000000, bitrate: 20000 kb/s
  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160, 24 fps
    Side data:
      Mastering display metadata: min: 0.0050 max: 1000.0000
  Stream #0:1: Audio: ac3, 48000 Hz, 5.1(side), fltp, 640 kb/s
`;

// HDR10+（SMPTE ST 2094 动态元数据）
const HDR10PLUS = `  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160
    Side data:
      SMPTE ST 2094 App 4, Version 1, HDR10+ Profile B compatible
`;

// HLG
const HLG = `  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67), 1920x1080
`;

// 文件名里带 HDR / DV 但内容是普通 SDR：不能凭文件名误判
const SDR_NAMED_HDR = `Input #0, matroska,webm, from 'D:/x/Some.Movie.2026.DV.HDR.1080p.BluRay.mkv':
  Duration: 00:10:00.00, start: 0.000000, bitrate: 8000 kb/s
  Stream #0:0: Video: h264 (High), yuv420p(tv, bt709), 1920x1080, 24 fps
  Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp, 128 kb/s
`;

describe('parseProbeStderr', () => {
  test('DV Profile 5：Side data 子行里的 DOVI record 必须被认出来', () => {
    const m = parseProbeStderr(DV5);
    assert.equal(m.dolbyVision, true);
    assert.equal(m.hdr10, false, 'DV P5 的 Stream 行没有任何色彩标记');
    assert.equal(m.is4k, true);
    assert.equal(m.videoCodec, 'hevc');
    assert.equal(m.audioCodec, 'aac');
    assert.equal(m.height, 2080);
    assert.equal(m.durationMs, 7116010);
  });

  test('HDR10：Mastering display metadata 在 Side data 子行里', () => {
    const m = parseProbeStderr(HDR10);
    assert.equal(m.hdr10, true);
    assert.equal(m.dolbyVision, false);
    assert.equal(m.is4k, true);
  });

  test('HDR10+ / HLG 各自能识别', () => {
    assert.equal(parseProbeStderr(HDR10PLUS).hdr10plus, true);
    assert.equal(parseProbeStderr(HLG).hlg, true);
  });

  test('文件名带 DV / HDR 但片源是 SDR：不看文件名，只看流信息', () => {
    const m = parseProbeStderr(SDR_NAMED_HDR);
    assert.equal(m.dolbyVision, false);
    assert.equal(m.hdr10, false);
    assert.equal(m.hdr10plus, false);
    assert.equal(m.hlg, false);
    assert.equal(m.is4k, false);
  });

  test('探测失败的空输出不抛错，全部按「没有」兜底', () => {
    const m = parseProbeStderr('');
    assert.equal(m.videoCodec, null);
    assert.equal(m.durationMs, null);
    assert.equal(m.dolbyVision, false);
    assert.equal(m.is4k, false);
  });
});
