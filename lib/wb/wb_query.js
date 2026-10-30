#!/usr/bin/env node
/**
 * WorkBuddy 积分查询（headless Chrome 版）
 *
 * 为什么不用 HTTP 库直接请求：
 *   实测同样的 cookie，浏览器页面内 fetch 返回 200，curl / Python 一律 401。
 *   网关（APISIX）按 TLS/HTTP 指纹区分客户端，普通 HTTP 客户端过不去。
 *   所以这里开一个无头 Chrome，在页面上下文里发请求——走 Chromium 自己的网络栈。
 *
 * 前提：.browser-profile 里已有登录态（跑过 获取Cookie.cmd 并登录）。
 * 用法：node wb_query.js [--json]
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const PROFILE = path.join(HERE, '.browser-profile');
const RUN_LOG = path.join(HERE, 'query.log');
// 默认加载 robots.txt（纯文本文档，不跑首页的营销 JS/埋点，内存峰值 515MB -> 382MB）
// fetch 的 origin 仍是 www.workbuddy.cn，同源请求不受影响
const START_URL = process.argv.includes('--heavy')
  ? 'https://www.workbuddy.cn/'
  : 'https://www.workbuddy.cn/robots.txt';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';

const APIS = [
  ['账号积分汇总', '/billing/meter/get-user-resource-summary'],
  ['免费资源包', '/billing/meter/get-user-resource-free-packages'],
  ['付费资源包', '/billing/meter/get-user-resource-paid-packages'],
  ['签到状态', '/billing/meter/checkin-status'],
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const T0 = Date.now();
const mark = (m) => console.error('[t] +' + (Date.now()-T0) + 'ms ' + m);
const _log = fs.createWriteStream(RUN_LOG, { flags: 'w' });
function log(m) {
  console.log(m);
  try {
    _log.write(m + '\n');
  } catch (_) {}
}

class PipeCDP {
  constructor(writable, readable) {
    this.w = writable;
    this.r = readable;
    this.id = 0;
    this.pending = new Map();
    this.buf = '';
    this.closed = false;
    readable.on('data', (d) => this._onData(d));
    readable.on('close', () => {
      this.closed = true;
      for (const [, p] of this.pending) p.reject(new Error('调试通道已关闭'));
      this.pending.clear();
    });
  }
  _onData(d) {
    this.buf += d.toString('utf8');
    let i;
    while ((i = this.buf.indexOf('\0')) >= 0) {
      const raw = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (!raw.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch (_) {
        continue;
      }
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message || 'CDP 错误'));
        else p.resolve(msg.result);
      }
    }
  }
  send(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(new Error('调试通道已关闭'));
    const id = ++this.id;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.w.write(JSON.stringify(payload) + '\0');
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(method + ' 超时'));
        }
      }, 25000);
    });
  }
}

let CHROME = null;
function closeChrome() {
  if (!CHROME || CHROME.killed) return;
  try {
    spawnSync('taskkill', ['/PID', String(CHROME.pid), '/T', '/F'], { stdio: 'ignore' });
  } catch (_) {}
}

function findBrowser() {
  for (const p of [
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  ]) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function summarize(data, prefix = '', depth = 0, out = []) {
  if (depth > 4) return out;
  if (data && typeof data === 'object') {
    if (Array.isArray(data)) {
      data.slice(0, 5).forEach((v, i) => summarize(v, `${prefix}[${i}]`, depth + 1, out));
      if (data.length > 5) out.push([prefix, `... 共 ${data.length} 项`]);
    } else {
      for (const [k, v] of Object.entries(data)) {
        summarize(v, prefix ? `${prefix}.${k}` : k, depth + 1, out);
      }
    }
  } else {
    out.push([prefix, data]);
  }
  return out;
}

async function main() {
  const browser = findBrowser();
  if (!browser) {
    log('[X] 没找到 Chrome');
    process.exit(1);
  }
  if (!fs.existsSync(PROFILE)) {
    log('[X] 没有登录态。先双击 获取Cookie.cmd 登录一次。');
    process.exit(2);
  }

  const chromeLog = fs.createWriteStream(path.join(HERE, 'query-chrome.log'), { flags: 'w' });
  CHROME = spawn(
    browser,
    [
      '--headless=new',
      '--remote-debugging-pipe',
      `--user-data-dir=${PROFILE}`,
      `--user-agent=${UA}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
      '--disable-extensions',
      '--blink-settings=imagesEnabled=false',
      '--disable-background-networking',
      '--disk-cache-size=8388608',
      '--renderer-process-limit=1',
      '--disable-features=site-per-process,CalculateNativeWinOcclusion',
      '--js-flags=--max-old-space-size=256',
      'about:blank',
    ],
    { stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'] }
  );
  CHROME.stdout.pipe(chromeLog);
  CHROME.stderr.pipe(chromeLog);
  CHROME.on('error', (e) => log('[X] 启动浏览器失败：' + e.message));

  const cdp = new PipeCDP(CHROME.stdio[3], CHROME.stdio[4]);

  let ver = null;
  for (let i = 0; i < 25; i++) {
    try {
      ver = await cdp.send('Browser.getVersion');
      break;
    } catch (_) {
      await sleep(500);
    }
  }
  if (!ver) {
    log('[X] 浏览器没起来，看 query-chrome.log（可能是浏览器正在运行、占着配置目录）');
    closeChrome();
    process.exit(1);
  }

  const { targetInfos } = await cdp.send('Target.getTargets');
  const page = (targetInfos || []).find((t) => t.type === 'page');
  if (!page) {
    log('[X] 没有页面 target');
    closeChrome();
    process.exit(1);
  }
  mark('page found: ' + (page.url||''));
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
  mark('attached');
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);

  await cdp.send('Page.navigate', { url: START_URL }, sessionId);
  mark('navigated');
  for (let i = 0; i < 40; i++) {
    await sleep(500);
    const r = await cdp.send(
      'Runtime.evaluate',
      { expression: 'location.host + "|" + document.readyState', returnByValue: true },
      sessionId
    );
    const v = String((r.result && r.result.value) || '');
    if (v.startsWith('www.workbuddy.cn') && v.includes('complete')) { mark('doc ready: ' + v); break; }
  }

  const expr = `(async () => {
    const apis = ${JSON.stringify(APIS.map((x) => x[1]))};
    const out = {};
    for (const p of apis) {
      try {
        const r = await fetch(p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
        out[p] = { status: r.status, body: (await r.text()).slice(0, 4000) };
      } catch (e) { out[p] = { status: 0, body: '', error: String(e) }; }
    }
    return JSON.stringify(out);
  })()`;

  mark('start fetch');
  let raw;
  try {
    const r = await cdp.send(
      'Runtime.evaluate',
      { expression: expr, awaitPromise: true, returnByValue: true },
      sessionId
    );
    raw = r.result && r.result.value;
  } catch (e) {
    log('[X] 页面内请求失败：' + e.message);
    closeChrome();
    process.exit(1);
  }
  mark('fetch done');
  closeChrome();

  if (!raw) {
    log('[X] 没有拿到数据');
    process.exit(1);
  }

  const result = JSON.parse(raw);
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(result, null, 2));
    process.exit(0);   // 同样要显式退出，见下
  }

  let okCount = 0;
  for (const [label, p] of APIS) {
    const item = result[p] || {};
    console.log('='.repeat(60));
    console.log(`${label}  ${p}  ->  HTTP ${item.status}`);
    console.log('='.repeat(60));
    if (item.status !== 200) {
      console.log(`鉴权失败或接口异常。${item.body ? item.body.slice(0, 200) : ''}\n`);
      continue;
    }
    okCount++;
    let json = null;
    try {
      json = JSON.parse(item.body);
    } catch (_) {}
    if (!json) {
      console.log(item.body.slice(0, 500) + '\n');
      continue;
    }
    console.log(JSON.stringify(json, null, 2).slice(0, 1500));
    const fields = summarize(json);
    if (fields.length) {
      console.log('\n-- 字段摘要 --');
      for (const [k, v] of fields) console.log(`  ${String(k).padEnd(44)} = ${v}`);
    }
    console.log('');
  }
  console.log(`成功接口：${okCount} / ${APIS.length}`);
  if (!okCount) log('[!] 全部失败，登录态可能过期，重跑 获取Cookie.cmd');
  // 关键：日志流和 Chrome 管道会挂住事件循环，实测进程拖 24s 才自然退出
  // 必须显式退出，否则面板每次刷新要多等 20 多秒
  process.exit(0);
}

main().catch((e) => {
  log('[X] ' + (e && e.message ? e.message : String(e)));
  closeChrome();
  process.exit(1);
});
