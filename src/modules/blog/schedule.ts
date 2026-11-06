import { sql } from 'kysely';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../kernel/types';
import { readSettings } from './settings';
import { isGenerating, startGeneration } from './generate';

/**
 * 每日定时生成（默认 04:00）。
 *
 * 为什么不精确匹配「小时 === 计划小时 && 分钟 === 计划分钟」：
 * 电脑 / 服务重启会错过那一分钟，用户第二天早上就什么都没有。
 * 这里用「今天已过计划时间、且今天还没生成过」来判定 —— 重启后会补跑。
 * 但只补 6 小时窗口：晚上十点开机突然开始播早新闻也很怪。
 *
 * `last_plan_date` 在**启动生成前**先写上，避免同一分钟内被 tick 两次。
 */

const CATCH_UP_MINUTES = 6 * 60;

export function startBlogSchedule(app: FastifyInstance, k: KernelApi): void {
  const tick = async (): Promise<void> => {
    try {
      const s = await readSettings(k);
      if (!s.planEnabled || isGenerating()) return;

      const now = new Date();
      const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(
        now.getDate(),
      ).padStart(2, '0')}`;
      if (s.lastPlanDate === today) return;

      const planMinutes = s.planHour * 60 + s.planMinute;
      const nowMinutes = now.getHours() * 60 + now.getMinutes();
      if (nowMinutes < planMinutes || nowMinutes - planMinutes > CATCH_UP_MINUTES) return;

      await sql`
        update blog_settings set last_plan_date = ${today} where id = 1
      `.execute(k.db);
      k.log.info(`[blog] 到达计划时间 ${s.planHour}:${String(s.planMinute).padStart(2, '0')}，开始生成`);
      await startGeneration(k, {
        counts: s.counts,
        voice: s.voice,
        speed: s.speed,
        trigger: 'schedule',
      });
    } catch (e) {
      k.log.warn(`[blog] 定时触发生成失败：${String((e as Error).message || e)}`);
    }
  };

  // 每分钟检查一次；unref 让它不阻止进程退出
  const timer = setInterval(() => void tick(), 60_000);
  timer.unref?.();
  app.addHook('onClose', async () => clearInterval(timer));

  // 启动后 20 秒先看一次（服务在计划时间之后才起来的情况不用等整分钟）
  const boot = setTimeout(() => void tick(), 20_000);
  boot.unref?.();
  app.addHook('onClose', async () => clearTimeout(boot));
}
