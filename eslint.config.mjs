import js from '@eslint/js';
import tseslint from 'typescript-eslint';

const nodeGlobals = {
  process: 'readonly',
  console: 'readonly',
  require: 'readonly',
  module: 'writable',
  exports: 'writable',
  __dirname: 'readonly',
  __filename: 'readonly',
  Buffer: 'readonly',
  URL: 'readonly',
  setTimeout: 'readonly',
  clearTimeout: 'readonly',
  setInterval: 'readonly',
  clearInterval: 'readonly',
  globalThis: 'readonly',
  // Node 18+ 全局（tool/fetch-ffmpeg.js 用 fetch 查询 GitHub API）
  fetch: 'readonly',
};

export default [
  {
    ignores: [
      // tsc 产物与 electron-builder 产物（后者内含打包后的 Flutter Web 与第三方 JS，
      // 不能进 lint）。用 dist* 一并覆盖 dist / dist_installer / dist_release_<日期> 等
      // 任意输出目录 —— 换输出目录名时不用再回来改配置。
      'dist*/**',
      'node_modules/**',
      'docs/**',
      // 工具/经验库的临时副本（accept 补丁会复制一份原文件，不能进 lint）
      '.codeartsdoer/**',
      // 本地临时目录（冒烟数据、实验脚本）
      '.devdata/**',
      // 冒烟测试在 .cache/rss 等目录里生成的临时 JS（每次跑都可能出现，不该进 lint）
      '.cache/**',
      // IDE 内置浏览器/调试器留下的临时 Chrome profile（第三方编译产物）
      '.tmp-chrome-profile/**',
      '.tmp-*/**',
      'contracts/openapi.json',
      '**/*.d.ts',
      // Flutter 构建产物（web 的 main.dart.js 有 7 万+ 行，误扫会淹没有用输出）
      'apps/**/build/**',
      'apps/**/.dart_tool/**',
      // Flutter Web 引导模板：`{{flutter_js}}` 等占位符由构建期替换，不是合法 JS
      'apps/colanas_os/web/flutter_bootstrap.js',
      // 鸿蒙端工程由 DevEco / hvigor 维护（hvigorfile.ts 依赖 @ohos/hvigor-ohos-plugin）
      'apps/colanas_os/ohos/**',
      'vendor/**',
    ],
  },

  js.configs.recommended,
  ...tseslint.configs.recommended,

  {
    files: ['**/*.ts'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: nodeGlobals,
    },
    rules: {
      'no-undef': 'off',
      'no-unused-vars': 'off',
      'no-console': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-require-imports': 'off',
    },
  },

  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: nodeGlobals,
    },
    rules: {
      'no-unused-vars': 'off',
      'no-console': 'off',
      '@typescript-eslint/no-require-imports': 'off',
    },
  },

  {
    files: ['**/*.mjs', 'eslint.config.mjs'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: nodeGlobals,
    },
  },
];
