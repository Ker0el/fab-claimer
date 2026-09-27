#!/usr/bin/env node
/**
 * 自更新 —— 检查 GitHub 上的新版本、下载、替换、重启界面
 *
 *   --check              查一下有没有新版本，打印一行 JSON 就退出（界面启动时后台跑）
 *   --apply --parent P   把新版本下载到 logs\update-<版本>\；下载**全部**成功才返回 ok
 *   --commit ...         由 --apply 自己拉起的独立进程：等界面退出→覆盖文件→重启界面
 *
 * ★ 为什么要把"下载"和"覆盖"分成两步、还换个进程来做
 * 覆盖的是自己正在跑的代码（gui.ps1 / claim.mjs）。下载中途失败、或者界面还没退干净
 * 就去动文件，都可能留下"半个新版本 + 半个旧版本"的状态 —— 那种状态最难排查，
 * 因为这程序本身就在怀疑浏览器、账号、Cloudflare。所以：
 *   全部下载完 → 才动现有文件；动文件时界面一定已经退出了。
 *
 * ★ 为什么不用 GitHub 的 zip 包
 * 仓库里有 core\node.exe（88MB）和 node_modules，打出来的包一百多兆，
 * 为了更新几个几十 KB 的脚本让每个用户下 100MB 不合适。这里按清单逐文件取。
 *
 * 国内直连 raw.githubusercontent.com 可能不通。通了就更新，不通就安静跳过 ——
 * 绝不能因为"查不到更新"影响正常领取。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');           // 程序根目录 = core 的上一级

const REPO   = process.env.FAB_UPDATE_REPO   || 'Ker0el/fab-claimer';
const BRANCH = process.env.FAB_UPDATE_BRANCH || 'main';
const BASE   = `https://raw.githubusercontent.com/${REPO}/${BRANCH}`;
const TIMEOUT_MS = 15000;

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const argOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : null; };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- 哪些文件允许被更新 ----------
// ★ 这是**数据保护**规则，不是防入侵规则。
// 能把仓库改掉的人本来就能改 claim.mjs 去读 profile\，从程序内部挡不住。
// 它要挡的是另一类事故：更新把用户的登录态、配置、日志、大二进制冲掉。
// 所以按"目录 + 扩展名"划，而不是逐个列文件名 —— 将来新增的 core\*.mjs 能自动被更新到，
// 而下面这些**永远**碰不到：
//   profile\            Epic 登录凭据
//   logs\               日志和更新暂存区
//   core\settings.json  用户指定的浏览器 / 调试端口
//   core\cdp-port.txt   运行期状态
//   根目录的 *.json      claimed.json / next-check.json
//   core\node.exe      88MB，更新它既没必要又容易失败
//   core\node_modules\  第三方依赖
//   *.exe / *.lnk       正在运行的启动器换不掉
const ALLOW = [
  /^core\/[^/]+\.(ps1|mjs|cmd|bat|ico)$/i,
  /^(README\.md|LICENSE|THIRD-PARTY-NOTICES\.md|使用说明\.txt|version\.json)$/i,
];

function isUpdatable(rel) {
  const p = String(rel || '').replace(/\\/g, '/');
  if (!p || p.includes('..') || p.startsWith('/') || /^[a-zA-Z]:/.test(p)) return false;
  return ALLOW.some((re) => re.test(p));
}

// ---------- 版本号 ----------
function readLocalVersion() {
  try {
    return String(JSON.parse(fs.readFileSync(path.join(ROOT, 'version.json'), 'utf8')).version || '0.0.0');
  } catch { return '0.0.0'; }
}

/** 1.0.10 > 1.0.9 —— 别用字符串比大小，那个会判错 */
function isNewer(remote, local) {
  const a = String(remote).split('.').map((x) => parseInt(x, 10) || 0);
  const b = String(local).split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] || 0, y = b[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
}

// ---------- 网络 ----------
// 国内直连 GitHub 抖是常态，一次超时就让整轮更新作废太亏 —— 每个请求重试几次。
async function withRetry(label, fn, tries = 3) {
  let last;
  for (let i = 1; i <= tries; i++) {
    try { return await fn(); }
    catch (e) {
      last = e;
      if (i < tries) await sleep(700 * i);
    }
  }
  throw new Error(`${label}失败（试了 ${tries} 次）：${last?.message || last}`);
}

async function getJson(url) {
  // 加时间戳绕过 raw.githubusercontent 的缓存，否则刚发的版本可能半小时拿不到
  return await withRetry('获取版本信息', async () => {
    const r = await fetch(`${url}${url.includes('?') ? '&' : '?'}t=${Date.now()}`,
      { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { 'cache-control': 'no-cache' } });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  });
}

async function getBuf(url) {
  return await withRetry('下载文件', async () => {
    const r = await fetch(`${url}${url.includes('?') ? '&' : '?'}t=${Date.now()}`,
      { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  });
}

const fileUrl = (rel) => `${BASE}/${rel.split('/').map(encodeURIComponent).join('/')}`;

// ★ 行尾要自己补回来。
// GitHub 上存的是 blob 原样字节（LF），raw 接口**不会**做 git checkout 时的行尾转换 ——
// 而 .gitattributes 里明明写着 *.cmd / *.bat / *.ps1 要 eol=crlf，因为批处理是 LF 会
// 直接坏掉（仓库里那条 "Must stay ASCII + CRLF" 的红线就是这么来的）。
// 实测确认过：不补的话，更新下来 auto-claim.cmd 会变成纯 LF。
// 这里就照 .gitattributes 的三条规则做，别的文件原样不动。
function normalizeEol(rel, buf) {
  if (!/\.(cmd|bat|ps1)$/i.test(rel)) return buf;
  const s = buf.toString('utf8').replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
  return Buffer.from(s, 'utf8');   // 有 BOM 的 .ps1 也照原样带回来
}

// ---------- 三步 ----------
async function check() {
  const local = readLocalVersion();
  const remote = await getJson(`${BASE}/version.json`);
  const ver = String(remote?.version || '');
  if (!ver) throw new Error('远端 version.json 里没有 version 字段');
  return {
    ok: true, local, remote: ver,
    update: isNewer(ver, local),
    notes: String(remote?.notes || ''),
  };
}

async function apply(parentPid) {
  const c = await check();
  if (!c.update) return { ok: false, error: `已经是最新版本（v${c.local}）` };

  const remote = await getJson(`${BASE}/version.json`);
  const listed = Array.isArray(remote?.files) ? remote.files.map(String) : [];
  const files = listed.filter(isUpdatable);
  const refused = listed.filter((p) => !isUpdatable(p));
  if (!files.length) return { ok: false, error: '远端清单里没有可更新的文件' };
  // version.json 必须在清单里：下面要靠它验"这一轮下载有没有新老混在一起"
  if (!files.includes('version.json')) {
    return { ok: false, error: '远端清单里没有 version.json，没法确认版本，先不更新' };
  }

  const stage = path.join(ROOT, 'logs', `update-${c.remote}`);
  fs.rmSync(stage, { recursive: true, force: true });

  // 全部下到暂存区，一个失败就整个作废 —— 绝不留下半个新版本
  for (const rel of files) {
    const buf = normalizeEol(rel, await getBuf(fileUrl(rel)));
    const dest = path.join(stage, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, buf);
  }

  // 刚 push 完的一两分钟里，GitHub 的 CDN 有传播延迟：不同文件可能一个新一个旧。
  // 下下来的 version.json 如果对不上号，说明这轮是"混的"，作废重来 ——
  // 否则会留下"版本号是新的、代码是旧的"，而且因为版本号已经追平，以后永远不会再更新。
  try {
    const staged = JSON.parse(fs.readFileSync(path.join(stage, 'version.json'), 'utf8'));
    if (String(staged.version || '') !== c.remote) {
      fs.rmSync(stage, { recursive: true, force: true });
      return { ok: false, error: `下载到的版本对不上（期望 v${c.remote}，拿到 v${staged.version}）—— 多半是刚发版、CDN 还没同步，过两分钟再试` };
    }
  } catch (e) {
    fs.rmSync(stage, { recursive: true, force: true });
    return { ok: false, error: `暂存下来的 version.json 读不出来：${e.message}` };
  }

  // 给 commit 阶段留一份清单：那边照着搬，不再信一次网络
  fs.writeFileSync(path.join(stage, '_manifest.json'),
    JSON.stringify({ version: c.remote, files }, null, 2));

  // 拉起独立进程去覆盖 + 重启。必须独立：它要等本界面退出才能动文件。
  const child = spawn(process.execPath,
    [fileURLToPath(import.meta.url), '--commit', '--stage', stage, '--parent', String(parentPid || 0)],
    { detached: true, stdio: 'ignore', cwd: HERE });
  child.unref();

  return { ok: true, version: c.remote, count: files.length, refused };
}

async function commit(stage, parentPid) {
  // 等界面退出。文件其实不会被锁死，但抢这一下不值得 —— 慢几秒换一个确定的状态。
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    let alive = false;
    try { process.kill(Number(parentPid), 0); alive = true; } catch { alive = false; }
    if (!alive) break;
    await sleep(300);
  }
  await sleep(600);   // 再让一拍，等退出时的清理（写日志、删临时文件）跑完

  const man = JSON.parse(fs.readFileSync(path.join(stage, '_manifest.json'), 'utf8'));
  let n = 0;
  for (const rel of man.files) {
    if (!isUpdatable(rel)) continue;                       // 再挡一道
    const src = path.join(stage, rel);
    const dst = path.join(ROOT, rel);
    if (!fs.existsSync(src)) continue;
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    // 先写 .new 再改名：中途断电也不会留下写了一半的脚本
    const tmp = `${dst}.new`;
    fs.copyFileSync(src, tmp);
    fs.renameSync(tmp, dst);
    n++;
  }
  fs.rmSync(stage, { recursive: true, force: true });

  // 重启界面。用 powershell 直接跑 gui.ps1 —— 和 core\备用启动.bat 完全一样，
  // 所以不管用户当初是双击 exe 还是双击 bat，重起来都是同一个东西。
  spawn('powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
     '-File', path.join(ROOT, 'core', 'gui.ps1')],
    { detached: true, stdio: 'ignore', cwd: path.join(ROOT, 'core') }).unref();

  return { ok: true, count: n };
}

// ---------- 入口 ----------
const out = { ok: false, error: null };
try {
  if (has('--check')) {
    Object.assign(out, await check());
  } else if (has('--apply')) {
    Object.assign(out, await apply(argOf('--parent')));
  } else if (has('--commit')) {
    Object.assign(out, await commit(argOf('--stage'), argOf('--parent')));
  } else {
    out.error = '用法：--check | --apply --parent PID | --commit --stage DIR --parent PID';
  }
} catch (e) {
  out.ok = false;
  out.error = e?.message || String(e);
}

// --commit 是脱离界面跑的，没人读它的输出；其余情况输出一行 JSON 给界面
if (!has('--commit')) process.stdout.write(JSON.stringify(out) + '\n');

// ★ 这里**不能**调 process.exit()。
// fetch 的 socket 还在收尾，硬退会在 Windows 上触发 libuv 的
// "Assertion failed: !(handle->flags & UV_HANDLE_CLOSING)"，进程带着 exit=127 崩掉，
// 那行断言还会走 stderr —— 界面把 stderr 当"内部错误"显示，用户就会看到一条
// 莫名其妙的报错。让事件循环自然排空即可，这里没有会吊住它的常驻句柄。
process.exitCode = out.ok ? 0 : 1;
