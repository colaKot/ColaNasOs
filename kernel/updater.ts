import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

/**
 * SP4 版本目录式更新器。
 *
 * 布局：
 *   <root>/versions/D<NNN>/       每个版本一个目录（构建产物原样落位）
 *   <root>/versions/D<NNN>/manifest.json   { version, files:{rel:sha256}, algo, signature }
 *   <root>/versions/current.json   { id: 'D104' }  原子切换
 *
 * 红线：**禁止原地覆盖 asar**；升级 = 落新目录 + 切指针，回滚 = 切回上一目录。
 */
export class UpdaterError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'UpdaterError';
  }
}

export interface VersionEntry {
  id: string;
  version: number;
  dir: string;
}

export interface Manifest {
  version: number;
  algo: 'ed25519';
  files: Record<string, string>;
  signature: string;
}

const ID_RE = /^D(\d+)$/;

export function versionId(n: number): string {
  if (!Number.isInteger(n) || n < 1) {
    throw new UpdaterError('E_VERSION', `非法版本号: ${n}`);
  }
  return `D${String(n).padStart(3, '0')}`;
}

export function parseVersionId(id: string): number | null {
  const m = ID_RE.exec(id);
  return m ? Number(m[1]) : null;
}

/** 稳定序列化：键排序 + 固定字段，签名与校验必须用同一份字节 */
export function canonicalPayload(version: number, files: Record<string, string>): Buffer {
  const sorted: Record<string, string> = {};
  for (const k of Object.keys(files).sort()) sorted[k] = files[k];
  return Buffer.from(JSON.stringify({ version, files: sorted }), 'utf8');
}

export function sha256File(p: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

/** 递归列出目录内所有文件的相对路径（POSIX 分隔符，排除 manifest 自身） */
export function listFiles(dir: string, rel = ''): string[] {
  const out: string[] = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const childRel = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...listFiles(dir, childRel));
    else if (e.isFile() && childRel !== 'manifest.json') out.push(childRel);
  }
  return out.sort();
}

export function signManifest(
  version: number,
  dir: string,
  privateKeyPem: string,
): Manifest {
  const files: Record<string, string> = {};
  for (const rel of listFiles(dir)) files[rel] = sha256File(path.join(dir, rel));
  const signature = crypto
    .sign(null, canonicalPayload(version, files), privateKeyPem)
    .toString('base64');
  return { version, algo: 'ed25519', files, signature };
}

export interface VerifyResult {
  ok: boolean;
  errors: string[];
}

export class Updater {
  readonly versionsDir: string;

  constructor(
    readonly root: string,
    private readonly publicKeyPem?: string,
  ) {
    this.versionsDir = path.join(root, 'versions');
  }

  /** 已有版本，按版本号升序 */
  list(): VersionEntry[] {
    const names = ((): string[] => {
      try {
        return fs
          .readdirSync(this.versionsDir, { withFileTypes: true })
          .filter((e) => e.isDirectory())
          .map((e) => e.name);
      } catch {
        return [];
      }
    })();
    return names
      .map((id) => {
        const version = parseVersionId(id);
        return version === null ? null : { id, version, dir: path.join(this.versionsDir, id) };
      })
      .filter((x): x is VersionEntry => x !== null)
      .sort((a, b) => a.version - b.version);
  }

  current(): VersionEntry | null {
    const p = path.join(this.versionsDir, 'current.json');
    try {
      const data = JSON.parse(fs.readFileSync(p, 'utf8')) as { id?: string };
      if (!data.id) return null;
      const version = parseVersionId(data.id);
      if (version === null) return null;
      return { id: data.id, version, dir: path.join(this.versionsDir, data.id) };
    } catch {
      return null;
    }
  }

  /** 落新版本目录；已存在则拒绝（永不原地覆盖） */
  install(srcDir: string, version: number): VersionEntry {
    if (!fs.existsSync(srcDir)) {
      throw new UpdaterError('E_SRC', `源目录不存在: ${srcDir}`);
    }
    const id = versionId(version);
    const dest = path.join(this.versionsDir, id);
    if (fs.existsSync(dest)) {
      throw new UpdaterError('E_EXISTS', `版本目录已存在: ${id}`);
    }
    fs.mkdirSync(this.versionsDir, { recursive: true });
    const tmp = path.join(this.versionsDir, `.tmp-${id}-${process.pid}`);
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.cpSync(srcDir, tmp, { recursive: true });
    fs.renameSync(tmp, dest);
    return { id, version, dir: dest };
  }

  /** 切指针；默认禁止降级 */
  activate(version: number, opts: { forceDowngrade?: boolean } = {}): VersionEntry {
    const id = versionId(version);
    const dir = path.join(this.versionsDir, id);
    if (!fs.existsSync(dir)) {
      throw new UpdaterError('E_NOT_FOUND', `版本不存在: ${id}`);
    }
    const cur = this.current();
    if (cur && version < cur.version && !opts.forceDowngrade) {
      throw new UpdaterError(
        'E_DOWNGRADE',
        `拒绝降级: current=${cur.id} target=${id}（需要 --force-downgrade）`,
      );
    }
    const entry: VersionEntry = { id, version, dir };
    if (this.publicKeyPem) {
      const r = this.verify(entry);
      if (!r.ok) {
        throw new UpdaterError('E_SIGNATURE', `签名/摘要校验失败: ${r.errors.join('; ')}`);
      }
    }
    this.writePointer(id);
    return entry;
  }

  /** 切回上一版本（显式回滚，允许降级） */
  rollback(): VersionEntry {
    const cur = this.current();
    const all = this.list();
    if (all.length < 2) {
      throw new UpdaterError('E_NO_PREVIOUS', '没有可回滚的历史版本');
    }
    const idx = cur ? all.findIndex((v) => v.id === cur.id) : all.length;
    const prev = idx > 0 ? all[idx - 1] : all[all.length - 1];
    if (!prev || (cur && prev.id === cur.id)) {
      throw new UpdaterError('E_NO_PREVIOUS', '没有可回滚的历史版本');
    }
    return this.activate(prev.version, { forceDowngrade: true });
  }

  verify(entry: VersionEntry): VerifyResult {
    const errors: string[] = [];
    const mp = path.join(entry.dir, 'manifest.json');
    let manifest: Manifest;
    try {
      manifest = JSON.parse(fs.readFileSync(mp, 'utf8')) as Manifest;
    } catch {
      return { ok: false, errors: ['manifest.json 缺失或不可解析'] };
    }
    if (manifest.algo !== 'ed25519') errors.push(`不支持的签名算法: ${manifest.algo}`);
    if (manifest.version !== entry.version) {
      errors.push(`manifest.version=${manifest.version} 与目录 ${entry.id} 不一致`);
    }

    if (this.publicKeyPem) {
      const ok = crypto.verify(
        null,
        canonicalPayload(manifest.version, manifest.files),
        this.publicKeyPem,
        Buffer.from(manifest.signature, 'base64'),
      );
      if (!ok) errors.push('签名校验失败');
    }

    for (const [rel, want] of Object.entries(manifest.files)) {
      const abs = path.join(entry.dir, rel);
      if (!fs.existsSync(abs)) {
        errors.push(`缺文件: ${rel}`);
        continue;
      }
      const got = sha256File(abs);
      if (got !== want) errors.push(`摘要不符: ${rel}`);
    }
    return { ok: errors.length === 0, errors };
  }

  private writePointer(id: string): void {
    const p = path.join(this.versionsDir, 'current.json');
    const tmp = `${p}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify({ id, at: Date.now() }), 'utf8');
    fs.renameSync(tmp, p);
  }
}

/**
 * SP4-03 数据初始化：幂等准备数据目录、默认配置与运行期目录。
 * 返回本次新建的条目（已存在的不重复创建）。
 */
export function initDataDir(dataDir: string): { created: string[] } {
  fs.mkdirSync(dataDir, { recursive: true });
  const created: string[] = [];

  const dirs = ['logs', 'tmp', 'backup'];
  for (const d of dirs) {
    const p = path.join(dataDir, d);
    if (!fs.existsSync(p)) {
      fs.mkdirSync(p, { recursive: true });
      created.push(d);
    }
  }

  const cfg = path.join(dataDir, 'config.json');
  if (!fs.existsSync(cfg)) {
    fs.writeFileSync(
      cfg,
      JSON.stringify({ version: 1, port: 7788, updatedAt: Date.now() }, null, 2),
      'utf8',
    );
    created.push('config.json');
  }

  // 上次异常退出遗留的 pid 文件不应让新进程误判
  const pid = path.join(dataDir, 'kernel.pid');
  if (fs.existsSync(pid)) fs.rmSync(pid, { force: true });

  return { created };
}