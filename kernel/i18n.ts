export interface LocaleEntry {
  code: string;
  native: string;
  enabled: boolean;
  files: { electron: string; flutter: string; harmony: string };
}

/**
 * i18n 键注册表（SP0 只做键登记与语言清单；翻译文本后续生成）
 * 单一真源：contracts/locales.json
 */
export class I18nRegistry {
  private byNamespace = new Map<string, Set<string>>();

  constructor(private readonly locales: LocaleEntry[]) {}

  static fromJSON(json: unknown): I18nRegistry {
    if (!Array.isArray(json)) throw new Error('locales.json must be an array');
    const list = json.map((v: any) => ({
      code: String(v.code),
      native: String(v.native ?? v.code),
      enabled: Boolean(v.enabled ?? true),
      files: {
        electron: String(v.files?.electron ?? `${v.code}.json`),
        flutter: String(v.files?.flutter ?? ''),
        harmony: String(v.files?.harmony ?? ''),
      },
    })) as LocaleEntry[];
    return new I18nRegistry(list);
  }

  register(namespace: string, keys: string[]): void {
    const set = this.byNamespace.get(namespace) ?? new Set<string>();
    for (const k of keys) set.add(k);
    this.byNamespace.set(namespace, set);
  }

  has(namespace: string, key: string): boolean {
    return this.byNamespace.get(namespace)?.has(key) ?? false;
  }

  allKeys(): Array<{ namespace: string; key: string }> {
    const out: Array<{ namespace: string; key: string }> = [];
    for (const [ns, keys] of this.byNamespace) {
      for (const k of keys) out.push({ namespace: ns, key: k });
    }
    return out;
  }

  localeCodes(): string[] {
    return this.locales.map((l) => l.code);
  }

  enabledCodes(): string[] {
    return this.locales.filter((l) => l.enabled).map((l) => l.code);
  }
}
