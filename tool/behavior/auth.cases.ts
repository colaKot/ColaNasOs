import { sql } from 'kysely';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * auth 域行为用例：登录口令、子账号权限、2FA 初始化。
 * 这里验证「谁能建账号、谁能登录、2FA 必须验码」的语义，细节边界由 smoke:auth 覆盖。
 */
const ADMIN = ['user:read', 'user:write'];

async function createUser(ctx: CaseContext, username: string, scopes: string[]): Promise<string> {
  const admin = await ctx.token(ADMIN);
  const res = await ctx.request('POST', '/api/v1/accounts/users/create', {
    token: admin,
    payload: { username, password: 'p@ssw0rd', scopes },
  });
  ctx.assertStatus(res, 200, '建账号');
  return res.json().id as string;
}

const domain: BehaviorDomain = {
  domain: 'auth',
  // 账号表是系统级管理资源：没有「他人的账号」语义，跨用户角色不适用
  shared: true,
  cases: [
    {
      id: 'login.wrong-password-401',
      name: '错误口令不能登录',
      async run(ctx) {
        await createUser(ctx, 'alice', ['files:read']);
        const res = await ctx.request('POST', '/api/v1/auth/login', {
          payload: { username: 'alice', password: 'wrong-pass' },
        });
        ctx.assertStatus(res, 401, '错误口令');
      },
    },
    {
      id: 'users.list.anonymous-401',
      name: '匿名用户不能列出账号',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/accounts/users');
        ctx.assertStatus(res, 401, '匿名列表');
      },
    },
    {
      id: 'users.create.reader-403',
      name: '只有读权限的用户不能建账号',
      async run(ctx) {
        const reader = await ctx.token(['user:read']);
        const res = await ctx.request('POST', '/api/v1/accounts/users/create', {
          token: reader,
          payload: { username: 'bob', password: 'p@ssw0rd', scopes: [] },
        });
        ctx.assertStatus(res, 403, '只读建账号');
      },
    },
    {
      id: 'users.create.admin-200',
      name: '管理员可以建账号，口令校验生效',
      async run(ctx) {
        await createUser(ctx, 'carol', ['files:read', 'files:write']);
        const res = await ctx.request('POST', '/api/v1/auth/login', {
          payload: { username: 'carol', password: 'p@ssw0rd' },
        });
        ctx.assertStatus(res, 200, '新账号登录');
        const body = res.json() as { token: string; scopes: string[] };
        ctx.expect(!!body.token, '返回 token');
        ctx.expect(body.scopes.includes('files:write'), 'scope 与创建时一致');
      },
    },
    {
      id: 'users.disable.blocks-login',
      name: '停用账号后不能登录',
      async run(ctx) {
        const id = await createUser(ctx, 'dave', ['files:read']);
        const admin = await ctx.token(ADMIN);
        const disabled = await ctx.request('POST', '/api/v1/accounts/users/disable', {
          token: admin,
          payload: { id, disabled: true },
        });
        ctx.assertStatus(disabled, 200, '停用');
        const login = await ctx.request('POST', '/api/v1/auth/login', {
          payload: { username: 'dave', password: 'p@ssw0rd' },
        });
        ctx.assertStatus(login, 401, '停用后登录');
      },
    },
    {
      id: '2fa.setup-returns-uri',
      name: '2FA 初始化返回 otpauth URI',
      async run(ctx) {
        const id = await createUser(ctx, 'erin', ['files:read']);
        const admin = await ctx.token(ADMIN);
        const res = await ctx.request('POST', '/api/v1/accounts/users/2fa/setup', {
          token: admin,
          payload: { id },
        });
        ctx.assertStatus(res, 200, '2FA 初始化');
        const body = res.json() as { secret?: string; uri?: string; otpauth?: string };
        const uri = body.uri || body.otpauth || '';
        ctx.expect(!!body.secret, '返回 secret');
        ctx.expect(uri.startsWith('otpauth://totp/'), '返回 otpauth URI');
      },
    },
    {
      id: '2fa.secret-sealed',
      name: 'TOTP secret 以密文落库，数据库中不出现明文',
      async run(ctx) {
        const id = await createUser(ctx, 'frank', ['files:read']);
        const admin = await ctx.token(ADMIN);
        const res = await ctx.request('POST', '/api/v1/accounts/users/2fa/setup', {
          token: admin,
          payload: { id },
        });
        ctx.assertStatus(res, 200, '2FA 初始化');
        const secret = (res.json() as { secret: string }).secret;
        const rows = (
          await sql<{ totp_secret: string }>`select totp_secret from auth_users where id = ${id}`.execute(
            ctx.k.db,
          )
        ).rows;
        const stored = rows[0]?.totp_secret ?? '';
        ctx.expect(stored.startsWith('v1:'), `落库应为密文，实际 ${stored.slice(0, 16)}`);
        ctx.expect(!stored.includes(secret), '密文不包含明文 secret');
      },
    },
  ],
};

export default domain;