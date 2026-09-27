#!/usr/bin/env node
/**
 * 把浏览器带到前台并打开 Epic 登录页，让用户完成登录。
 *   （无参数）  打开 Epic 登录页
 *   --fab      只是把 fab.com 打开（已登录时「打开浏览器」用）
 * 输出一行 JSON：{"ok":bool,"created":bool,"error":string|null}
 */
import { chromium } from 'playwright-core';

const CDP = process.env.FAB_CDP || 'http://127.0.0.1:9222';
// Epic 标准登录入口；登录成功后会跳回 fab.com 并把登录态写进该浏览器配置
const LOGIN = 'https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.fab.com%2F';
const IS_FAB = process.argv.includes('--fab');
const TARGET = IS_FAB ? 'https://www.fab.com/' : LOGIN;
const out = { ok: false, created: false, error: null };

// 按 host 判断，别被 Epic 登录页 URL 里的 redirectUrl=...fab.com%2F 骗到
const isFab = (u) => { try { return new URL(String(u)).hostname.endsWith('fab.com'); } catch { return false; } };
const urlOf = (p) => String(p.url());

let browser = null;
try {
  browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  let page;

  if (IS_FAB) {
    // 已登录，只是想把 fab.com 打开
    page = ctx.pages().find((p) => isFab(urlOf(p)));
    if (!page) { page = await ctx.newPage(); out.created = true; }
    await page.bringToFront().catch(() => {});
    await page.goto(TARGET, { waitUntil: 'domcontentloaded', timeout: 60000 });
  } else {
    // 登录页：优先复用已在登录页的标签；否则新开一个。
    // 关键：不要劫持 fab.com 标签 —— 登录期间若没有 fab 页面，
    // 登录态检测（whoami）就失去了落点。
    page = ctx.pages().find((p) => /epicgames\.com\/id\/login/.test(urlOf(p)));
    if (!page) {
      page = ctx.pages().find((p) => urlOf(p).includes('epicgames.com'));
      if (!page) { page = await ctx.newPage(); out.created = true; }
      await page.goto(TARGET, { waitUntil: 'domcontentloaded', timeout: 60000 });
    }
  }

  await page.bringToFront().catch(() => {});
  out.ok = true;
} catch (e) {
  out.error = e.message;
} finally {
  // 出错也必须断开，否则 WebSocket 吊住事件循环，进程不退出
  try { if (browser) await browser.close(); } catch {}
}

process.stdout.write(JSON.stringify(out) + '\n');
process.exit(0);
