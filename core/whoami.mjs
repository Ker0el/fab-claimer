#!/usr/bin/env node
/**
 * 轻量登录态检查：复用已打开的 fab.com 标签页问 /i/users/me，不做任何导航。
 * 输出一行 JSON：{"ok":bool,"name":string|null,"error":string|null}
 * 供 GUI 在「等待用户登录」时每几秒轮询一次。
 */
import { chromium } from 'playwright-core';

const CDP = process.env.FAB_CDP || 'http://127.0.0.1:9222';
const out = { ok: false, name: null, error: null };

// 必须按 host 判断：Epic 登录页的 URL 里带 redirectUrl=...fab.com%2F，
// 用 includes('fab.com') 会把登录页误当成 fab 页面，fetch 相对路径就跨域失败了。
const isFab = (u) => { try { return new URL(String(u)).hostname.endsWith('fab.com'); } catch { return false; } };

let browser = null;
let createdPage = null;
try {
  browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  const fabPages = ctx.pages().filter((p) => isFab(p.url()));

  if (!fabPages.length) {
    // 关键：不能为了检测就新开标签页。
    // 用户正在 Epic 登录页上时，fab.com 标签本来就不存在 —— 早期版本会为此
    // 每 5 秒新建一个标签、导航到 fab.com、查完再关掉，浏览器就会一直闪。
    // 这里直接返回 "还判断不了"，等用户登录完跳回 fab.com 后自然就能查到。
    out.pending = true;
  } else {
    const page = fabPages[0];
    const r = await page.evaluate(async () => {
      const res = await fetch('/i/users/me', { headers: { accept: 'application/json' }, credentials: 'include' });
      return { status: res.status, body: res.ok ? await res.json() : null };
    });
    out.ok = r.status === 200;
    out.name = (r.body && r.body.displayName) || null;
  }
} catch (e) {
  out.error = e.message;
} finally {
  // 必须无条件断开：出错时不关连接，Playwright 的 WebSocket 会吊住事件循环，
  // 进程永远不退出，GUI 每 5 秒轮询一次就会堆一堆僵尸 node。
  try { if (createdPage) await createdPage.close().catch(() => {}); } catch {}
  try { if (browser) await browser.close(); } catch {}
}

process.stdout.write(JSON.stringify(out) + '\n');
process.exit(0);
