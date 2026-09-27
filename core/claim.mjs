#!/usr/bin/env node
/**
 * Fab 限时免费资产自动入库 —— GUI 版
 *
 * 与 fab-claim.mjs 的区别：只加了一层「事件输出」，领取逻辑完全一致。
 *   --gui    以 NDJSON 事件流输出到 stdout（供 PowerShell GUI 读取），人读日志仍写 logs/
 *   --scan   只扫描当前批次 + 登录态 + 归属，不做任何领取，扫完即退
 *   --dry    同 fab-claim.mjs：只看不领
 *   --ui     强制走真实点击通路
 *   --due    时间闸门：只判断「到该检查的时间了吗」，不联网、不启动浏览器。
 *            到点了 exit 0，没到 exit 2。给 auto-claim.cmd 用，避免每天空跑。
 *
 * 自调度：每次跑完把「本批截止时间」和「下次该检查的时间」写进 next-check.json，
 * 自动任务靠 --due 读它来决定要不要启动浏览器。
 *
 * 事件类型（NDJSON，每行一个 JSON）：
 *   {ev:"phase", phase, text}                     阶段变化
 *   {ev:"login", ok, name}                        登录态（name 为 Fab 显示名）
 *   {ev:"batch", count, items:[{uid,title}]}      当前批次
 *   {ev:"item", uid, title, state, reason, ...}   state: owned|todo|claiming|ok|fail
 *   {ev:"progress", done, total}
 *   {ev:"summary", ok, total, results:[...]}
 *   {ev:"log", text, level}                       详细日志（给「详细日志」面板）
 *   {ev:"fatal", code, text}                      致命错误
 */
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// 数据目录（claimed.json / logs）由 GUI 通过 FAB_DATA 指定为程序根目录；直接跑则落到脚本目录
const DATA = process.env.FAB_DATA || HERE;

const CFG = {
  cdp: process.env.FAB_CDP || 'http://127.0.0.1:9222',
  base: 'https://www.fab.com',
  bladeUrl: '/i/blades/free_content_blade',
  preferLicense: process.env.FAB_LICENSE || 'professional',
  minDelay: 1500,
  maxDelay: 3500,
  logDir: path.join(DATA, 'logs'),
  claimedFile: path.join(DATA, 'claimed.json'),
};
const DRY = process.argv.includes('--dry');
const FORCE_UI = process.argv.includes('--ui');
const GUI = process.argv.includes('--gui');
const SCAN_ONLY = process.argv.includes('--scan');
const GATE = process.argv.includes('--due');

// ---------- 自调度：预测「下次该检查的时间」 ----------
// 限免批次约每两周轮换一次，而上批的 discountEndDate 就是下批上线的时间点。
// 所以每次跑完把「下次该看的时间」写进 next-check.json；auto-claim.cmd 在启动浏览器
// 之前先用 --due 问一句，没到时间就直接退出 —— 平时那次触发完全不启动浏览器、不弹窗口，
// 只有真换批了才会动作。
const GATE_FILE = path.join(DATA, 'next-check.json');
const GATE_CFG = {
  endBufferMs: 5 * 60 * 1000,            // 截止后再等 5 分钟，给服务端换批留时间
  retryAfterFailMs: 2 * 60 * 60 * 1000,  // 有资产没领成：2 小时后就重试
  emptyBatchMs: 6 * 60 * 60 * 1000,      // 当前没有批次：6 小时后再看
  unknownEndMs: 24 * 60 * 60 * 1000,     // 拿不到截止时间：明天再看
  maxSilenceMs: 7 * 24 * 60 * 60 * 1000, // 兜底：最多静默 7 天，防止轮换节奏变了没发现
};

function loadGate() { try { return JSON.parse(fs.readFileSync(GATE_FILE, 'utf8')); } catch { return null; } }
function saveGate(o) { try { fs.writeFileSync(GATE_FILE, JSON.stringify(o, null, 2)); } catch {} }

const pad2 = (n) => String(n).padStart(2, '0');
function fmtLocal(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 只有「真的把这一批处理完了」才推进下次检查时间；手动扫描 / DRY 试跑不推进 */
function planNextCheck({ batchEnd, afterMs, result }) {
  if (SCAN_ONLY || DRY) return;
  const at = Number.isFinite(batchEnd)
    ? batchEnd + GATE_CFG.endBufferMs
    : Date.now() + (afterMs ?? GATE_CFG.unknownEndMs);
  patchGate({ nextCheckAt: new Date(at).toISOString(), lastResult: result });
  log(`⏰ 下次自动检查：${fmtLocal(at)}`);
}

// 攒着改动、退出前一次性落盘 —— 这样任何一条 return 路径都不会漏写
let gatePatch = {};
function patchGate(o) { Object.assign(gatePatch, o); }
process.on('exit', () => {
  if (!Object.keys(gatePatch).length) return;
  saveGate({ ...(loadGate() || {}), ...gatePatch });
});

/** --due：现在该跑吗？exit 0 = 该跑，exit 2 = 还没到时间 */
function checkDue() {
  const now = Date.now();
  const g = loadGate();
  const next = g?.nextCheckAt ? Date.parse(g.nextCheckAt) : NaN;
  const last = g?.lastRealCheckAt ? Date.parse(g.lastRealCheckAt) : 0;
  // 必须同时有「排期」和「这批已处理完的结论」才算有历史，否则当成全新安装 ——
  // 先实际检查一遍当前批次。只看时间不够稳：安装包/拷贝目录可能把别的机器的
  // 状态带过来，那会让新机器一装上就跳过当前批次。
  // 注意 lastResult 只在 planNextCheck 里和 nextCheckAt 一起写，两者必然同进同退；
  // 只跑过 --scan 时没有 lastResult，所以这里会放行，正是我们要的。
  if (!Number.isFinite(next) || !g?.lastResult) {
    console.log('[gate] 没有可用的排期记录 → 先实际检查一次当前批次');
    process.exit(0); return;
  }
  if (now >= next) { console.log(`[gate] 已到预测时间 ${fmtLocal(next)} → 该跑`); process.exit(0); return; }
  if (last && now - last >= GATE_CFG.maxSilenceMs) {
    console.log(`[gate] 已 ${Math.floor((now - last) / 86400000)} 天没实际检查过（兜底）→ 该跑`);
    process.exit(0); return;
  }
  console.log(`[gate] 未到检查时间（下次 ${fmtLocal(next)}，还有 ${Math.ceil((next - now) / 3600000)} 小时）→ 跳过`);
  process.exit(2);
}

// ---------- 事件流 ----------
function emit(o) {
  if (GUI) process.stdout.write(JSON.stringify(o) + '\n');
}

// ---------- UI 文案（中英双匹配；匹配不到时会把实际文案打进日志） ----------
const RE = {
  cta: /^(立即购买|立即获取|添加到库|加入库|获取|免费获取|购买|buy now|add to library|add to cart|claim|get|get it free)$/i,
  placeOrder: /^(下订单|提交订单|确认订单|确认购买|完成购买|结账|去结算|place order|confirm order|complete order|complete purchase|checkout|buy now|add to library|claim)$/i,
  // Epic 结账成功文案是 "It's all yours / Thanks for your purchase!"（英文，且不含 "library" 字样）
  owned: /(已保存到我的库|已在您的库中|已拥有|在库中|已添加到|saved in my library|in your library|you own this|already owned|added to your library|it'?s all yours|thanks for your purchase)/i,
  licenseBtn: /(个人|专业|personal|professional)/i,
};

// ---------- 工具 ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const randDelay = () => sleep(CFG.minDelay + Math.random() * (CFG.maxDelay - CFG.minDelay));

let logStream = null;
let fatalSent = false;
function log(...args) {
  const text = args.join(' ');
  const level = /✗|⚠️|❌/.test(text) ? 'warn' : 'info';
  if (GUI) emit({ ev: 'log', text, level });
  else console.log(`[${new Date().toISOString()}] ${text}`);
  // 注意：finally 里会 end() 掉 logStream，之后 main().catch() 还会再 log 一次，
  // 不判断 writableEnded 就会 ERR_STREAM_WRITE_AFTER_END 把真实错误盖掉。
  if (logStream && !logStream.writableEnded) {
    logStream.write(`[${new Date().toISOString()}] ${text}\n`);
  }
}
function initLog() {
  try { fs.mkdirSync(CFG.logDir, { recursive: true }); } catch {}
  logStream = fs.createWriteStream(
    path.join(CFG.logDir, `claim-${new Date().toISOString().slice(0, 10)}.log`),
    { flags: 'a' }
  );
}
function loadClaimed() { try { return JSON.parse(fs.readFileSync(CFG.claimedFile, 'utf8')); } catch { return {}; } }
function saveClaimed(o) { try { fs.writeFileSync(CFG.claimedFile, JSON.stringify(o, null, 2)); } catch {} }

function fatal(code, text) {
  if (!fatalSent) { fatalSent = true; emit({ ev: 'fatal', code, text }); }
  log(`❌ ${text}`);
}

/** 把脚本内部的技术性失败原因翻译成小白能看懂的中文 */
function friendlyReason(info) {
  const s = String(info || '');
  if (!s) return '未知原因';
  if (/Not free/i.test(s)) return '接口直领通道不支持限免商品（属正常，已自动改用真实点击方式）';
  if (s === 'no-cta') return '商品页上没找到「领取」按钮，可能页面改版了';
  if (s === 'no-place-order') return '结账页面没找到「Add to library」按钮，可能页面改版了';
  if (/未确认成功/.test(s)) return '结账没走完，可能是验证码没通过 —— 可以打开浏览器窗口手动领取一次';
  // 必须排在 401/403 那条前面：挑战页里也带 "HTTP 403"，混在一起会把风控说成掉登录
  if (CF_MARK.test(s)) return '被 Cloudflare 人机验证拦住了 —— 请到浏览器窗口完成验证后重试';
  if (/HTTP 401|HTTP 403/.test(s)) return '登录状态失效了，请重新登录 Epic 账号';
  if (/HTTP 429/.test(s)) return '请求太频繁被限流，等几分钟再试';
  if (/复核未通过/.test(s)) return '结账后没能确认入库，请打开 Fab 网站手动看一眼';
  if (/no-cta|找不到主操作按钮/.test(s)) return '商品页没找到领取按钮，可能页面改版了';
  if (/异常/.test(s)) return '网络或浏览器出现异常';
  if (/add-to-library/.test(s)) return '接口直领失败（已自动改用真实点击方式）';
  return s.slice(0, 150);
}

// ---------- 抓包：拦截 fetch / XHR，把 /i/ 接口的请求与响应记进各页面自己的 window.__cap ----------
// 用 addInitScript 注入，所以包括结账页在内的每次导航都会自动重新装上。
function netHook() {
  if (window.__cap) return;
  window.__cap = [];
  const strip = (u) => String(u).replace(location.origin, '');
  const keep = (u) => /\/i\//.test(String(u)) || /epicgames|unrealengine/i.test(String(u));

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const req = args[0];
    const url = (req && req.url) || req;
    const opt = args[1] || {};
    if (!keep(url)) return origFetch.apply(this, args);
    const rec = {
      via: 'fetch',
      method: (opt.method || (req && req.method) || 'GET').toUpperCase(),
      url: strip(url),
      reqBody: typeof opt.body === 'string' ? opt.body.slice(0, 800) : (opt.body ? '[' + opt.body.constructor.name + ']' : null),
      status: null,
      respBody: null,
    };
    window.__cap.push(rec);
    try {
      const res = await origFetch.apply(this, args);
      rec.status = res.status;
      const ct = res.headers.get('content-type') || '';
      if (/json|text/.test(ct)) {
        const c = res.clone();
        c.text().then((t) => { rec.respBody = t.slice(0, 800); }).catch(() => {});
      }
      return res;
    } catch (e) { rec.status = 'ERR ' + e.message; throw e; }
  };

  const OX = window.XMLHttpRequest.prototype.open;
  const OS = window.XMLHttpRequest.prototype.send;
  window.XMLHttpRequest.prototype.open = function (m, u, ...rest) {
    this.__keepRec = keep(u);
    if (this.__keepRec) {
      this.__rec = { via: 'xhr', method: String(m).toUpperCase(), url: strip(u), reqBody: null, status: null, respBody: null };
      window.__cap.push(this.__rec);
    }
    return OX.call(this, m, u, ...rest);
  };
  window.XMLHttpRequest.prototype.send = function (b) {
    if (this.__rec) {
      this.__rec.reqBody = typeof b === 'string' ? b.slice(0, 800) : (b ? '[' + b.constructor.name + ']' : null);
      this.addEventListener('loadend', () => {
        this.__rec.status = this.status;
        this.__rec.respBody = String(this.responseText || '').slice(0, 800);
      });
    }
    return OS.call(this, b);
  };
}

/** 把某个页面抓到的接口打进日志（只看新增的，避免重复刷屏） */
const netSeen = new Map();
async function dumpNet(page, tag) {
  let cap = [];
  try { cap = await page.evaluate(() => window.__cap || []); } catch { return; }
  const key = page.url();
  const from = netSeen.get(key) || 0;
  const fresh = cap.slice(from);
  netSeen.set(key, cap.length);
  if (!fresh.length) return;
  log(`    [NET] ${tag} 新增 ${fresh.length} 条 /i/ 接口：`);
  for (const r of fresh) {
    log(`      ${r.method} ${r.url} → ${r.status}`);
    if (r.reqBody) log(`        req : ${String(r.reqBody).replace(/\s+/g, ' ').slice(0, 300)}`);
    if (r.respBody) log(`        resp: ${String(r.respBody).replace(/\s+/g, ' ').slice(0, 300)}`);
  }
}

/** 桌面通知（Windows toast）+ 可选微信推送。GUI 模式下 toast 由界面本身承担，跳过 */
function notify(title, content) {
  if (!GUI) {
    const ps = `[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null;` +
      `$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);` +
      `$n=$t.GetElementsByTagName('text');$n.Item(0).AppendChild($t.CreateTextNode(${JSON.stringify(title)})) > $null;` +
      `$n.Item(1).AppendChild($t.CreateTextNode(${JSON.stringify(content)})) > $null;` +
      `[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Fab 领取').Show([Windows.UI.Notifications.ToastNotification]::new($t));`;
    execFile('powershell', ['-NoProfile', '-Command', ps], () => {});
  }

  const tok = process.env.WXPUSHER_TOKEN, uid = process.env.WXPUSHER_UID;
  if (tok && uid) {
    fetch(`https://wxpusher.zjiecode.com/api/send/message`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ appToken: tok, content: `**${title}**\n\n${content}`, contentType: 3, uids: [uid] }),
    }).catch(() => {});
  }
}

// ---------- 连接 Chrome ----------
async function assertChromeUp() {
  try {
    const r = await fetch(`${CFG.cdp}/json/version`, { signal: AbortSignal.timeout(5000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const ver = await r.json();
    // 没有窗口的 headless 浏览器干不了这件事：用户得有窗口才能登录、才能过人机验证。
    // 端口被别的工具占着时很容易接上这种东西（实测踩过：另一个工具的 headless
    // Chrome 占着 9222），早点说清楚，比让人对着"请点一下验证框"干等 5 分钟强。
    if (/HeadlessChrome/i.test(ver['User-Agent'] || '')) {
      const err = new Error('当前连的是一个没有窗口的 headless 浏览器，没法登录 / 过人机验证。');
      err.code = 'HEADLESS_BROWSER';
      throw err;
    }
    return ver;
  } catch (e) {
    if (e.code === 'HEADLESS_BROWSER') throw e;   // 别被下面的兜底包装成"连不上"
    const err = new Error(`连不上浏览器调试端口 ${CFG.cdp}`);
    err.code = 'NO_BROWSER';
    err.cause = e;
    throw err;
  }
}

// ---------- 页面内 API ----------
// 页面可能正在跳转（登录跳转、前端路由），此时 evaluate 会抛
// "Execution context was destroyed"；在途的 fetch 则会被中断成 "Failed to fetch"。
// 这两类都是暂时的，重试即可；其它错误（真没登录、网络断了）直接往上抛。
const NAV_ERR = /Execution context was destroyed|because of a navigation|Target closed|detached|Cannot find context|Failed to fetch/i;
async function evalRetry(page, fn, arg, tries = 4) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try { return await page.evaluate(fn, arg); }
    catch (e) {
      lastErr = e;
      if (!NAV_ERR.test(e.message || '')) throw e;
      log(`      ⏳ 页面正在跳转，${i + 1}/${tries} 次重试…`);
      await sleep(1200);
      try { await page.waitForLoadState('domcontentloaded', { timeout: 15000 }); } catch {}
    }
  }
  throw lastErr;
}

// ---------- Cloudflare 人机验证 ----------
// Fab 前面挂着 Cloudflare 的防护。它觉得这个浏览器可疑时，所有 /i/ 接口都会返回一张
// 「请稍候…」挑战页（HTML）而不是 JSON —— 日志里那段 <html> 就是这么来的。
// 既不是程序坏了，也不是没登录：用户在浏览器窗口点一下「确认您是真人」就能过。
// 所以这里不报错退出，而是把浏览器让给用户、每 5 秒探一次，过了自动接着跑 ——
// 跟等登录是同一个套路。等太久（下方 timeoutMs）才放弃，免得界面永远卡在「处理中」。
const CF_MARK = /cf_challenge|cf-chl|__cf_chl|challenges\.cloudflare\.com|Just a moment|Verifying you are human|Enable JavaScript and cookies|请稍候/i;

/** 状态码非 200 且正文是挑战页 → 被 Cloudflare 拦了（注意别把真没登录的 401 算进来） */
function isCfChallenge(status, body) {
  if (status === 200) return false;
  return CF_MARK.test(typeof body === 'string' ? body : '');
}

const CF_WAIT = { pollMs: 5000, timeoutMs: 5 * 60 * 1000 };
const CF_TIMEOUT_HINT = 'Cloudflare 人机验证一直没通过。请切到浏览器窗口把「确认您是真人」做完，然后重新点「刷新批次」。';

/** 被拦下时抛这个：调用方据此走「等用户过验证」而不是报错 */
function cfError(what, status) {
  const e = new Error(`${what}被 Cloudflare 人机验证拦住（HTTP ${status}）`);
  e.cfBlocked = true;
  return e;
}

/**
 * 等用户过验证。返回 true = 已通过（可以继续），false = 等超时了。
 * 探针就用 /i/users/me：它既看得出"还被拦着"，通了之后也顺手带回登录态。
 */
async function waitForCfPass(page) {
  log('⚠️ 被 Cloudflare 人机验证拦住了（Fab 前面的防护，不是你操作错了）。');
  log('   请切到浏览器窗口点一下验证框；程序每 5 秒自动检查，通过后会自己接着跑。');
  emit({ ev: 'challenge', ok: false });
  // 把标签页调到前面。GUI 收到 challenge 事件后会临时取消置顶，所以这里调起来看得见。
  await page.bringToFront().catch(() => {});
  const t0 = Date.now();
  for (let i = 1; ; i++) {
    await sleep(CF_WAIT.pollMs);
    let r = null;
    try { r = await pageApi.me(page); } catch { r = null; }
    const sec = Math.round((Date.now() - t0) / 1000);
    if (r && !r.blocked) {
      emit({ ev: 'challenge', ok: true });
      log(`✅ 人机验证已通过（等了 ${sec} 秒），继续。`);
      return true;
    }
    if (sec >= CF_WAIT.timeoutMs / 1000) {
      emit({ ev: 'challenge', ok: false, timeout: true });
      log(`❌ 人机验证等了 ${sec} 秒还没过，先停下。`);
      return false;
    }
    if (i % 6 === 0) {          // 每 30 秒给界面一个心跳，让人知道程序还活着
      emit({ ev: 'challenge', ok: false, sec });
      log(`   还在等人机验证…（已等 ${sec} 秒）`);
    }
  }
}

const pageApi = {
  async discover(page) {
    const r = await evalRetry(page, async (url) => {
      const res = await fetch(url, { headers: { accept: 'application/json' }, credentials: 'include' });
      return { status: res.status, body: res.ok ? await res.json() : await res.text() };
    }, CFG.bladeUrl);
    if (isCfChallenge(r.status, r.body)) throw cfError('拉取批次', r.status);
    if (r.status !== 200) throw new Error(`blade 接口返回 ${r.status}: ${String(r.body).slice(0, 200)}`);
    return (r.body.tiles || []).map((t) => {
      const l = t.listing || {};
      return {
        uid: l.uid, title: l.title, url: `${CFG.base}/listings/${l.uid}`,
        licenses: (l.licenses || []).map((x) => ({ slug: x.slug, offerId: x.offerId })),
      };
    }).filter((x) => x.uid);
  },

  /**
   * 登录态 + 用户名：/i/users/me 登录时 200 带 displayName，未登录 401。
   * 注意 checked 字段：只有真正问到服务端才算 checked=true。
   * 抛异常时调用方必须当成"没查出来"，绝不能当成"未登录"。
   * blocked=true 是第三种情况：被 Cloudflare 拦了 —— 同样不是"未登录"，
   * 混在一起会让界面喊用户去登录，而问题根本不在登录。
   */
  async me(page) {
    const r = await evalRetry(page, async () => {
      const res = await fetch('/i/users/me', { headers: { accept: 'application/json' }, credentials: 'include' });
      return { status: res.status, body: res.ok ? await res.json() : (await res.text()).slice(0, 4000) };
    });
    if (isCfChallenge(r.status, r.body)) return { ok: false, name: null, status: r.status, checked: false, blocked: true };
    if (r.status !== 200) return { ok: false, name: null, status: r.status, checked: true };
    return { ok: true, name: r.body?.displayName || null, status: 200, checked: true };
  },

  async states(page, uids) {
    if (!uids.length) return {};
    const q = uids.map((u) => `listing_ids=${u}`).join('&');
    const r = await evalRetry(page, async (url) => {
      const res = await fetch(url, { headers: { accept: 'application/json' }, credentials: 'include' });
      return { status: res.status, body: res.ok ? await res.json() : await res.text() };
    }, `/i/users/me/listings-states?${q}`);
    if (isCfChallenge(r.status, r.body)) throw cfError('查归属', r.status);
    if (r.status !== 200) throw new Error(`listings-states 返回 ${r.status}（多为未登录）`);
    return Object.fromEntries((r.body || []).map((x) => [x.uid, x.acquired]));
  },

  async detail(page, uid) {
    const r = await evalRetry(page, async (url) => {
      const res = await fetch(url, { headers: { accept: 'application/json' }, credentials: 'include' });
      return { status: res.status, body: res.ok ? await res.json() : await res.text() };
    }, `/i/listings/${uid}`);
    if (isCfChallenge(r.status, r.body)) throw cfError('查商品详情', r.status);
    if (r.status !== 200) throw new Error(`listings/${uid} 返回 ${r.status}`);
    return r.body;
  },

  /** 通路 A */
  async addToLibrary(page, uid, offerId) {
    return await evalRetry(page, async ({ uid, offerId }) => {
      const csrf = (document.cookie.split('; ').find((c) => c.startsWith('fab_csrftoken=')) || '').split('=')[1] || '';
      const boundary = '----WebKitFormBoundary1';
      const body = `--${boundary}\r\nContent-Disposition: form-data; name="offer_id"\r\n\r\n${offerId}\r\n--${boundary}--\r\n`;
      const res = await fetch(`/i/listings/${uid}/add-to-library`, {
        method: 'POST',
        headers: {
          accept: 'application/json, text/plain, */*',
          'content-type': `multipart/form-data; boundary=${boundary}`,
          'x-csrftoken': csrf,
          'x-requested-with': 'XMLHttpRequest',
        },
        body, credentials: 'include',
      });
      let text = ''; try { text = (await res.text()).slice(0, 300); } catch {}
      return { status: res.status, text };
    }, { uid, offerId });
  },
};

// ---------- 通路 B：真实点击走结账 ----------
async function claimViaUi(page, item, ctx) {
  log(`    [UI] 打开商品页 ${item.url}`);
  await page.goto(item.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await sleep(3000);
  await dumpNet(page, '商品页加载');

  // 1) 选 Professional 授权
  try {
    const licBtn = page.locator('button[aria-haspopup], [role="button"][aria-expanded], button[aria-controls]')
      .filter({ hasText: RE.licenseBtn });
    if (await licBtn.count()) {
      const cur = (await licBtn.first().innerText()).trim();
      if (!/专业|professional/i.test(cur)) {
        log(`    [UI] 切换授权（当前: ${cur.replace(/\s+/g, ' ').slice(0, 30)}）`);
        await licBtn.first().click();
        await sleep(900);
        const opt = page.locator('[role="option"], [role="menuitem"], li, button')
          .filter({ hasText: /专业|professional/i }).first();
        if (await opt.count()) { await opt.click(); await sleep(1200); }
        else log('    [UI] ⚠️ 没找到 Professional 选项，沿用当前授权');
      }
    } else {
      log('    [UI] ⚠️ 没找到授权选择器（可能只有一个授权）');
    }
  } catch (e) { log(`    [UI] 授权切换异常：${e.message}`); }
  await dumpNet(page, '授权切换后');

  // 2) 点主按钮（Playwright 的 click 经 CDP 派发真实输入事件）
  const dumpButtons = async () => {
    const t = await page.evaluate(() => [...document.querySelectorAll('button, a[role="button"]')]
      .filter((b) => b.getBoundingClientRect().height > 0)
      .map((b) => (b.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30)).filter(Boolean).slice(0, 40));
    log(`    [UI] 当前可见按钮：${JSON.stringify([...new Set(t)])}`);
  };

  const cta = page.locator('button, a[role="button"]').filter({ hasText: RE.cta });
  if (!(await cta.count())) {
    if (RE.owned.test(await page.evaluate(() => document.body.innerText))) {
      log('    [UI] 页面显示已拥有');
      return { ok: true, how: 'ui:already-owned' };
    }
    log('    [UI] ✗ 找不到主操作按钮');
    await dumpButtons();
    return { ok: false, how: 'ui', info: 'no-cta' };
  }
  log(`    [UI] 点击：${(await cta.first().innerText()).trim().replace(/\s+/g, ' ').slice(0, 30)}`);
  await cta.first().click();

  // 3) 等结账界面。当前 Fab 的真实形态是【同页 iframe 遮罩】：
  //    <iframe src="https://www.fab.com/payment/web/purchase?...offers=<ns>-<offerId>--">
  //    外面套 .webPurchaseBg / .webPurchaseContainer 两个 z-index 99998/99999 的遮罩。
  //    页面 URL 不变、也不开新标签，所以早期版本只看 page.url()/ctx.pages() 永远找不到下单按钮。
  const PAY_RE = /\/payment\/web\/purchase|\/purchase|checkout/i;
  let page2 = page;         // URL 参考（新标签用）
  let checkout = page;      // 真正操作下单按钮的上下文：Page 或 Frame，两者都有 locator/evaluate/url
  let how = '同页';
  for (let i = 0; i < 25; i++) {
    await sleep(700);
    const np = ctx.pages().find((p) => p !== page && PAY_RE.test(p.url()));
    if (np) { page2 = np; checkout = np; how = '新标签'; break; }
    const fr = page.frames().find((f) => PAY_RE.test(f.url()));
    if (fr) { checkout = fr; how = '同页 iframe'; break; }
    if (PAY_RE.test(page.url())) { checkout = page; break; }
  }
  if (page2 !== page) {
    log(`    [UI] 结账在新标签打开：${page2.url().slice(0, 90)}`);
    await page2.waitForLoadState('domcontentloaded').catch(() => {});
  }
  log(`    [UI] 结账上下文=${how} → ${checkout.url().slice(0, 110)}`);
  await sleep(3500); // 等结账会话初始化，点太早点会 400
  await dumpNet(checkout, `结账页初始化(${how})`);
  if (checkout !== page) await dumpNet(page, '结账页初始化(主框架)');

  // 4) 点下单（Epic 结账页按钮文案是英文 "Add to library"）
  const order = checkout.locator('button, a[role="button"], [role="button"]').filter({ hasText: RE.placeOrder });
  if (!(await order.count())) {
    log('    [UI] ✗ 找不到下单按钮');
    const t = await checkout.evaluate(() => [...document.querySelectorAll('button')]
      .filter((b) => b.getBoundingClientRect().height > 0)
      .map((b) => (b.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30)).filter(Boolean).slice(0, 40));
    log(`    [UI] 结账页可见按钮：${JSON.stringify([...new Set(t)])}`);
    log(`    [UI] 结账页文本：${(await checkout.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ').slice(0, 300)}`);
    return { ok: false, how: 'ui', info: 'no-place-order' };
  }
  log(`    [UI] 点击：${(await order.first().innerText()).trim().replace(/\s+/g, ' ').slice(0, 30)}`);
  await order.first().click();
  await sleep(4000);
  await dumpNet(checkout, '下单后');

  // 成功判定：先看结账上下文，再看主页面（最终仍以 listings-states 接口为准）
  for (const tgt of [checkout, page]) {
    const txt = await tgt.evaluate(() => document.body.innerText).catch(() => '');
    if (new RegExp(RE.owned.source, 'i').test(txt)) return { ok: true, how: 'ui' };
  }
  const body = await checkout.evaluate(() => document.body.innerText.slice(0, 300).replace(/\s+/g, ' ')).catch(() => '');
  return { ok: false, how: 'ui', info: `未确认成功，页面文本：${body}` };
}

// ---------- 主流程 ----------
async function main() {
  // --due 是给自动任务用的时间闸门：必须在 initLog / 连浏览器之前就判完，
  // 没到时间就直接退出（连浏览器都不会启动）。
  if (GATE) { checkDue(); return; }

  initLog();
  log('='.repeat(60));
  log(`Fab 限时免费入库${SCAN_ONLY ? '（仅扫描）' : DRY ? '（DRY RUN）' : ''}${FORCE_UI ? '（强制 UI 通路）' : ''}`);

  emit({ ev: 'phase', phase: 'browser', text: '正在连接浏览器…' });
  let ver;
  try {
    ver = await assertChromeUp();
  } catch (e) {
    fatal('NO_BROWSER', e.code === 'HEADLESS_BROWSER'
      ? `${e.message}请点「打开浏览器」重新启动一个。`
      : '浏览器没有启动。点「打开浏览器」重试。');
    process.exitCode = 3;
    return;
  }
  log(`浏览器: ${ver.Browser}`);
  emit({ ev: 'phase', phase: 'browser', text: `已连接 ${ver.Browser}` });

  const browser = await chromium.connectOverCDP(CFG.cdp);
  const ctx = browser.contexts()[0];
  if (!ctx) {
    fatal('NO_CONTEXT', '拿不到浏览器上下文');
    await browser.close().catch(() => {});
    process.exitCode = 1;
    return;
  }

  const page = await ctx.newPage();
  // 抓包：ctx 级覆盖新开的标签页（结账可能开新 tab），page 级兜底当前页
  await ctx.addInitScript(netHook).catch(() => {});
  await page.addInitScript(netHook);
  const summary = [];
  try {
    const entry = SCAN_ONLY ? CFG.base : `${CFG.base}/limited-time-free`;
    await page.goto(entry, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await sleep(2000);

    // ---- 登录态 ----
    emit({ ev: 'phase', phase: 'login', text: '正在检查登录状态…' });
    // checked=false 表示"没查出来"（页面在跳转、被 Cloudflare 拦），绝不能当成"未登录"报给界面 ——
    // 那会把界面上一秒刚确认的已登录状态错误地降级。
    let me = { ok: false, name: null, checked: false };
    try { me = await pageApi.me(page); } catch (e) { log(`  ⚠️ 登录态检查失败：${e.message}`); }

    // 被 Cloudflare 拦下时登录态和批次接口会一起失效。先让用户去过验证，
    // 过了再重新问一次 —— 别拿"未登录"去误导他（那会打开一个根本不需要的登录页）。
    if (me.blocked) {
      if (!(await waitForCfPass(page))) {
        fatal('CF_BLOCKED', CF_TIMEOUT_HINT);
        process.exitCode = 1;
        return;
      }
      try { me = await pageApi.me(page); } catch (e) { log(`  ⚠️ 登录态检查失败：${e.message}`); }
    }

    emit({ ev: 'login', ok: me.ok, name: me.name, checked: me.checked, blocked: !!me.blocked });
    log(`登录态：${me.checked ? (me.ok ? `已登录${me.name ? ` (${me.name})` : ''}` : '未登录') : '未知（检查失败）'}`);

    // ---- 批次发现 ----
    emit({ ev: 'phase', phase: 'discover', text: '正在获取当前批次…' });
    log('→ 拉取当前批次…');
    let items = [];
    try {
      items = await pageApi.discover(page);
    } catch (e) {
      if (!e.cfBlocked) {
        fatal('DISCOVER_FAILED', `获取批次失败：${e.message}`);
        process.exitCode = 1;
        return;
      }
      // 登录态那次没被拦、拉批次时才被拦（少见但会发生）：同样让用户去过验证，过了自动重拉
      if (!(await waitForCfPass(page))) {
        fatal('CF_BLOCKED', CF_TIMEOUT_HINT);
        process.exitCode = 1;
        return;
      }
      try { items = await pageApi.discover(page); }
      catch (e2) {
        fatal('DISCOVER_FAILED', `获取批次失败：${e2.message}`);
        process.exitCode = 1;
        return;
      }
    }
    log(`  当前批次 ${items.length} 个资产：`);
    for (const it of items) log(`    · ${it.title}  (${it.uid})`);
    emit({ ev: 'batch', count: items.length, items: items.map((i) => ({ uid: i.uid, title: i.title })) });

    if (!items.length) {
      log('⚠️ 当前没有限免批次');
      planNextCheck({ afterMs: GATE_CFG.emptyBatchMs, result: 'no-batch' });
      emit({ ev: 'summary', ok: 0, total: 0, results: [], note: '当前没有限免批次' });
      return;
    }

    // ---- 归属检查 ----
    let states = {};
    try { states = await pageApi.states(page, items.map((i) => i.uid)); }
    catch (e) { log(`  ⚠️ 归属查询失败：${e.message}（多半是没登录）`); }

    emit({ ev: 'phase', phase: 'check', text: '正在检查哪些还没领…' });
    const todo = [];
    const endsList = [];
    for (const it of items) {
      const owned = states[it.uid];
      const lic = it.licenses.find((l) => l.slug === CFG.preferLicense) || it.licenses[0];
      if (!lic) {
        log(`  ✗ ${it.title}：无可用授权`);
        emit({ ev: 'item', uid: it.uid, title: it.title, state: 'fail', reason: '这个资产没有可用授权' });
        continue;
      }
      await randDelay();
      let detail = null;
      try { detail = await pageApi.detail(page, it.uid); } catch (e) { log(`  ⚠️ 详情失败：${e.message}`); }
      const dl = detail?.licenses?.find((l) => l.slug === lic.slug) || detail?.licenses?.[0];
      const disc = dl?.priceTier?.discountedPrice, ends = dl?.priceTier?.discountEndDate;
      const freeNow = dl ? (dl.priceTier?.price === 0 || disc === 0) : null;
      if (ends) endsList.push(ends);
      log(`  · ${it.title}`);
      log(`      授权=${lic.slug} 已拥有=${owned === true ? '是' : owned === false ? '否' : '未知'} 现价=${disc ?? '?'} 截止=${ends ?? '?'}`);
      if (owned === true) {
        log('      → 已拥有，跳过');
        emit({ ev: 'item', uid: it.uid, title: it.title, state: 'owned', license: lic.slug, ends });
        continue;
      }
      if (freeNow === false) {
        log('      → 折扣未生效，跳过');
        emit({ ev: 'item', uid: it.uid, title: it.title, state: 'skip', reason: '折扣还没生效', license: lic.slug, ends });
        continue;
      }
      // 未登录时 listings-states 拿不到，归属是「未知」而不是「没领过」，
      // 不能显示成待领取误导用户（他可能早就领过了）。
      if (!me.ok) {
        log('      → 未登录，无法判断是否已拥有');
        emit({ ev: 'item', uid: it.uid, title: it.title, state: 'unknown', reason: '需要先登录才能确认', license: lic.slug, ends });
        todo.push({ ...it, offerId: lic.offerId, licSlug: lic.slug });
        continue;
      }
      emit({ ev: 'item', uid: it.uid, title: it.title, state: 'todo', license: lic.slug, ends, price: disc });
      todo.push({ ...it, offerId: lic.offerId, licSlug: lic.slug });
    }

    emit({ ev: 'todo', count: todo.length, items: todo.map((t) => ({ uid: t.uid, title: t.title })) });

    // 本批截止时间就是下一批的开始时间 —— 自调度的依据。批次内几个资产截止时间一致，取最晚的。
    const batchEnd = endsList.length
      ? Math.max(...endsList.map((s) => Date.parse(s)).filter(Number.isFinite))
      : NaN;
    patchGate({
      batchUids: items.map((i) => i.uid),
      discountEndDate: Number.isFinite(batchEnd) ? new Date(batchEnd).toISOString() : null,
      lastRealCheckAt: new Date().toISOString(),
    });
    log(`  本批截止 ${Number.isFinite(batchEnd) ? fmtLocal(batchEnd) : '未知（稍后重试）'}`);

    if (SCAN_ONLY) {
      log(`✅ 扫描完成，待领取 ${todo.length} 个`);
      emit({ ev: 'summary', ok: 0, total: todo.length, results: [], scan: true });
      return;
    }

    if (!todo.length) {
      log('✅ 没有需要领取的资产');
      planNextCheck({ batchEnd, result: 'all-owned' });
      emit({ ev: 'summary', ok: 0, total: 0, results: [], note: '全部已拥有' });
      return;
    }
    if (DRY) {
      todo.forEach((t) => log(`  DRY：应领 ${t.title}`));
      emit({ ev: 'summary', ok: 0, total: todo.length, results: [], dry: true });
      return;
    }
    if (me.checked && !me.ok) {
      fatal('NO_LOGIN', '还没有登录 Epic 账号，无法领取。请点「去登录」登录后再试。');
      process.exitCode = 2;
      return;
    }
    if (!me.checked) {
      log('⚠️ 本次没能确认登录态，继续尝试领取（失败时会给出具体原因）');
    }

    // ---- 领取 ----
    emit({ ev: 'phase', phase: 'claim', text: '开始领取…' });
    const claimed = loadClaimed();
    let done = 0;
    for (const t of todo) {
      await randDelay();
      log(`→ 领取：${t.title}`);
      emit({ ev: 'item', uid: t.uid, title: t.title, state: 'claiming' });
      let res = { ok: false, how: '', info: '' };

      if (!FORCE_UI) {
        try {
          const r = await pageApi.addToLibrary(page, t.uid, t.offerId);
          res.info = `A: HTTP ${r.status}${r.text ? ' | ' + r.text.replace(/\s+/g, ' ').slice(0, 160) : ''}`;
          res.how = 'api';
          res.ok = r.status === 204 || r.status === 200;
          log(`    通路A ${res.ok ? '✅ 成功' : '✗ 失败'} ${res.info}`);
        } catch (e) {
          res.info = `A: 异常 ${e.message}`; log(`    通路A ✗ ${res.info}`);
        }
      }
      await dumpNet(page, '通路A后');

      if (!res.ok) {
        log('    转通路B（真实点击结账）…');
        try {
          const r = await claimViaUi(page, t, ctx);
          res = { ...r, info: res.info ? res.info + ' / B: ' + (r.info || 'ok') : 'B: ' + (r.info || 'ok') };
        } catch (e) { res.info += ` / B: 异常 ${e.message}`; log(`    通路B ✗ ${e.message}`); }
      }

      // 用接口做最终裁定（最可靠）：不看前端怎么报，只看 acquired。
      // 之前只在 res.ok 时才复核，导致结账明明成功（页面显示 "It's all yours"）
      // 但前端文案没匹配上就误判成失败。
      try {
        const st = await pageApi.states(page, [t.uid]);
        if (st[t.uid] === true) {
          if (!res.ok) res.info += ' | 接口复核=已拥有，纠正为成功';
          res.ok = true;
        } else if (res.ok) {
          res.ok = false; res.info += ' | 复核未通过';
        }
      } catch {}
      if (res.ok) {
        claimed[t.uid] = { title: t.title, at: new Date().toISOString(), license: t.licSlug };
        saveClaimed(claimed);
      }
      done++;
      log(`    ${res.ok ? '✅ 最终成功' : '✗ 最终失败'}  ${res.info}`);
      emit({
        ev: 'item', uid: t.uid, title: t.title,
        state: res.ok ? 'ok' : 'fail',
        reason: res.ok ? '' : friendlyReason(res.info),
        raw: res.info,
      });
      emit({ ev: 'progress', done, total: todo.length });
      summary.push({ ...t, ...res });
      await randDelay();
    }

    log('—— 汇总 ——');
    const okN = summary.filter((r) => r.ok).length;
    for (const r of summary) log(`  ${r.ok ? '✅' : '✗ '} ${r.title}`);
    emit({
      ev: 'summary', ok: okN, total: summary.length,
      results: summary.map((r) => ({
        uid: r.uid, title: r.title, ok: r.ok,
        reason: r.ok ? '' : friendlyReason(r.info),
      })),
    });
    const needHelp = summary.filter((r) => !r.ok);
    // 有没领成就两小时后重试，别干等下一批；全成就直接把下次检查推到下批开始
    if (needHelp.length) planNextCheck({ afterMs: GATE_CFG.retryAfterFailMs, result: 'partial-fail' });
    else planNextCheck({ batchEnd, result: 'ok' });
    if (needHelp.length) {
      notify(`Fab 领取：${okN}/${summary.length} 成功`, `需要手动处理：\n${needHelp.map((r) => `· ${r.title}`).join('\n')}`);
    } else if (okN > 0) {
      notify(`Fab 领取完成：${okN} 个已入库`, summary.map((r) => `· ${r.title}`).join('\n'));
    }
  } finally {
    await page.close().catch(() => {});
    await browser.close().catch(() => {});
    logStream?.end();
  }
}

main().catch((e) => {
  const msg = e?.stack || e?.message || String(e);
  if (GUI) emit({ ev: 'fatal', code: 'UNCAUGHT', text: String(e?.message || e) });
  else console.error('\n❌ ' + msg);
  log('❌ ' + String(e?.message || e));
  process.exitCode = 1;
}).finally(() => {
  // GUI 要等这个进程退出才解除按钮锁定。万一有残留的 Playwright 连接吊住事件循环，
  // 进程会永远不退出、界面就卡死在「处理中」。这里兜底强制退出（只在 GUI 模式下）。
  if (GUI) setTimeout(() => process.exit(process.exitCode ?? 0), 400);
});
