#!/usr/bin/env node
/**
 * WorkBuddy 积分 Cookie 获取器（方案 A 自动化版）
 *
 * 流程：拉起独立 Chrome → 打开 workbuddy.cn → 你登录 → 自动抓 cookie
 *      → 页面内 fetch 验证登录 → 静默完成（登录态存 .browser-profile）
 *
 * 零依赖（Node 18+，本机 22）。
 *
 * 关键设计：走 --remote-debugging-pipe，不用 TCP 调试端口。
 * 本机实测 127.0.0.1:9333 的连接被丢弃（SYN 超时），pipe 走 stdio 不受影响。
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const path = require('path');

const IS_WIN = process.platform === 'win32';
const IS_MAC = process.platform === 'darwin';
const HERE = __dirname;

// 与 wb_query.js 保持同一套运行态目录规则：
// macOS/Linux 写到用户目录（.app 内部只读），Windows 沿用脚本目录不破坏已有登录态。
function resolveStateDir() {
  if (process.env.WB_STATE_DIR) return process.env.WB_STATE_DIR;
  if (IS_MAC) return path.join(os.homedir(), 'Library', 'Application Support', 'TokenPanel', 'wb');
  if (!IS_WIN) return path.join(os.homedir(), '.local', 'share', 'tokenpanel', 'wb');
  return HERE;
}

const STATE_DIR = resolveStateDir();
try { fs.mkdirSync(STATE_DIR, { recursive: true }); } catch (_) {}

const PROFILE = path.join(STATE_DIR, '.browser-profile');
const CHROME_LOG = path.join(STATE_DIR, 'chrome.log');
const RUN_LOG = path.join(STATE_DIR, 'run.log');
const RESULT_FILE = path.join(STATE_DIR, '.auth-result.json');
const START_URL = 'https://www.workbuddy.cn/';
const API = 'https://www.workbuddy.cn/billing/meter/get-user-resource-summary';
const MAX_WAIT_MS = 6 * 60 * 1000;
const POLL_MS = 5000;

// 授权结果写文件，面板读文件判定。
// 原因：Windows PowerShell 5.1 的 Start-Process -PassThru 读不到 ExitCode（实测恒为 null），
// 只靠退出码会把「用户取消」误判成「成功」。
function writeResult(kind, detail) {
  try {
    fs.writeFileSync(RESULT_FILE, JSON.stringify({
      result: kind,
      detail: detail || '',
      at: new Date().toISOString(),
    }), 'utf8');
  } catch (_) {}
}
try { fs.unlinkSync(RESULT_FILE); } catch (_) {}

const CHROME_CANDIDATES = IS_MAC
  ? [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    ]
  : IS_WIN
  ? [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
      'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    ]
  : [
      '/usr/bin/google-chrome',
      '/usr/bin/google-chrome-stable',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/snap/bin/chromium',
    ];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const _logStream = fs.createWriteStream(RUN_LOG, { flags: 'w' });
function log(msg) {
  console.log(msg);
  try {
    _logStream.write(msg + '\n');
  } catch (_) {}
}
process.on('exit', () => {
  try {
    _logStream.end();
  } catch (_) {}
});

function findBrowser() {
  for (const p of CHROME_CANDIDATES) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// ---------------------------------------------------------------- CDP over pipe

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
      } else if (msg.method && this.onEvent) {
        try {
          this.onEvent(msg);
        } catch (_) {}
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
      }, 20000);
    });
  }
}

// ---------------------------------------------------------------- 主流程

let CHROME = null;
let finishing = false;   // 成功/超时路径主动关浏览器时置位，避免 exit 事件误判成「用户取消」

function closeChrome() {
  finishing = true;
  if (!CHROME || CHROME.killed) return;
  try {
    if (IS_WIN) {
      spawnSync('taskkill', ['/PID', String(CHROME.pid), '/T', '/F'], { stdio: 'ignore' });
    } else {
      spawnSync('pkill', ['-9', '-f', PROFILE], { stdio: 'ignore' });
      try { CHROME.kill('SIGKILL'); } catch (_) {}
    }
  } catch (_) {
    try {
      CHROME.kill();
    } catch (_) {}
  }
}

// 关键：必须按 cookie 的 path 过滤。
// getAllCookies 会把 Keycloak 的登录流程 cookie（path 是 /realms/...）也返回，
// 如果一并塞进请求头，网关会走错鉴权分支，直接 401（实测）。
function pathMatches(cookiePath, reqPath) {
  const p = cookiePath || '/';
  if (p === '/') return true;
  const pp = p.endsWith('/') ? p.slice(0, -1) : p;
  return reqPath === pp || reqPath.startsWith(pp + '/');
}

function buildCookieHeader(cookies, mode) {
  const reqPath = '/billing/meter/get-user-resource-summary';
  const picked = cookies.filter((c) => {
    if (!pathMatches(c.path, reqPath)) return false;
    const d = c.domain || '';
    if (mode === 'workbuddy') return d.includes('workbuddy.cn');
    return true;
  });
  return picked.map((c) => `${c.name}=${c.value}`).join('; ');
}

function printSummary(json) {
  const data = json && json.data ? json.data : null;
  if (!data) {
    log('    响应没有 data：' + JSON.stringify(json).slice(0, 300));
    return;
  }
  const accounts = data.Accounts || data.accounts || [];
  log('    TotalCount = ' + (data.TotalCount ?? data.totalCount ?? '?') + '，Accounts = ' + accounts.length + ' 项');
  accounts.slice(0, 8).forEach((a, i) => {
    const flat = Object.entries(a)
      .filter(([, v]) => v === null || ['string', 'number', 'boolean'].includes(typeof v))
      .map(([k, v]) => `${k}=${v}`)
      .join(', ');
    log(`    [${i}] ${flat}`);
  });
}

async function findPage(cdp, deadline) {
  while (Date.now() < deadline) {
    const { targetInfos } = await cdp.send('Target.getTargets');
    const pages = (targetInfos || []).filter((t) => t.type === 'page');
    const hit = pages.find((t) => (t.url || '').includes('workbuddy.cn'));
    if (hit) return hit;
    if (pages.length) return pages[0];
    await sleep(500);
  }
  return null;
}

async function main() {
  const browser = findBrowser();
  if (!browser) {
    log('[X] 没找到 Chrome / Edge');
    writeResult('fail', 'no-browser');
    process.exit(1);
  }
  log('浏览器：' + browser);
  log('独立配置目录：' + PROFILE);
  log('');

  fs.mkdirSync(PROFILE, { recursive: true });
  const chromeLog = fs.createWriteStream(CHROME_LOG, { flags: 'w' });

  CHROME = spawn(
    browser,
    [
      '--remote-debugging-pipe',
      `--user-data-dir=${PROFILE}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=Translate,MediaRouter',
      '--disable-sync',
      START_URL,
    ],
    { stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'] }
  );
  CHROME.stdout.pipe(chromeLog);
  CHROME.stderr.pipe(chromeLog);
  CHROME.on('error', (e) => log('[X] 启动浏览器失败：' + e.message));

  // 用户关掉浏览器 = 取消授权。必须立即退出（退出码 3），
  // 否则面板的「授权登录」按钮要一直等到 6 分钟超时才恢复可点。
  CHROME.on('exit', (code) => {
    if (finishing) return;
    log('\n[!] 浏览器已关闭，授权已取消。');
    writeResult('cancel', 'browser-closed');
    process.exit(3);
  });

  const cdp = new PipeCDP(CHROME.stdio[3], CHROME.stdio[4]);

  // 等浏览器把调试通道准备好
  let ver = null;
  for (let i = 0; i < 25; i++) {
    try {
      ver = await cdp.send('Browser.getVersion');
      break;
    } catch (_) {
      await sleep(600);
    }
  }
  if (!ver) {
    log('[X] 浏览器调试通道没起来，看 chrome.log');
    writeResult('fail', 'cdp-not-ready');
    closeChrome();
    process.exit(1);
  }
  log('[i] 浏览器就绪：' + ver.product);

  const page = await findPage(cdp, Date.now() + 30000);
  if (!page) {
    log('[X] 找不到页面 target');
    writeResult('fail', 'no-page-target');
    closeChrome();
    process.exit(1);
  }

  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
  await cdp.send('Network.enable', {}, sessionId);

  if ((page.url || '') === 'about:blank') {
    await cdp.send('Page.navigate', { url: START_URL }, sessionId);
  }

  log('[i] 请在浏览器窗口里登录 www.workbuddy.cn');
  log('    登录成功后会自动完成，不用管这个黑框。');
  log('');

  // 诊断模式：看页面状态和 localStorage 里有什么
  if (process.argv.includes('--diag')) {
    await sleep(3000);
    const expr = `JSON.stringify({
      url: location.href,
      title: document.title,
      cookieNames: document.cookie.split('; ').map(s => s.split('=')[0]).filter(Boolean),
      lsKeys: Object.keys(localStorage),
      lsSample: Object.fromEntries(Object.entries(localStorage)
        .filter(([k]) => /token|auth|user|credit|account|session/i.test(k))
        .map(([k, v]) => [k, String(v).slice(0, 60)]))
    })`;
    try {
      const r = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, sessionId);
      log('[诊断] ' + (r.result && r.result.value ? r.result.value : JSON.stringify(r)));
    } catch (e) {
      log('[诊断失败] ' + e.message);
    }
    const all = await cdp.send('Network.getAllCookies', {}, sessionId);
    const names = (all.cookies || []).filter((c) => (c.domain || '').includes('workbuddy'))
      .map((c) => `${c.name}(${c.domain},${c.session ? 'session' : 'persist'})`);
    log('[cookie] ' + names.join(', '));

    // 在页面里直接打接口，抓浏览器真实发出的请求头
    const captured = [];
    cdp.onEvent = (m) => {
      if (m.method === 'Network.requestWillBeSent' && String(m.params.request.url).includes('/billing/')) {
        captured.push(m.params.request);
      }
      if (m.method === 'Network.requestWillBeSentExtraInfo') {
        const h = m.params.headers || {};
        const ck = h.Cookie || h.cookie || '';
        if (ck && ck.length > 500 && ck.length > (global.__bestCookie || '').length) {
          global.__bestCookie = ck;
          log('[浏览器真实 Cookie] ' + ck.length + ' 字符，' + ck.split('; ').length + ' 项');
          log('    ' + ck.split('; ').map((s) => s.split('=')[0]).join(', '));
          fs.writeFileSync(path.join(HERE, '.real-cookie.txt'), ck, 'utf8');
        }
      }
    };
    try {
      const r = await cdp.send(
        'Runtime.evaluate',
        {
          expression: `fetch('/billing/meter/get-user-resource-summary',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(r=>r.status+' '+r.statusText)`,
          awaitPromise: true,
          returnByValue: true,
        },
        sessionId
      );
      log('[页面内 fetch] ' + JSON.stringify(r.result && r.result.value));
    } catch (e) {
      log('[页面内 fetch 失败] ' + e.message);
    }
    await sleep(1500);
    for (const req of captured.slice(0, 2)) {
      log('[真实请求] ' + req.method + ' ' + req.url);
      const hs = req.headers || {};
      for (const [k, v] of Object.entries(hs)) {
        const vv = String(v);
        const shown = /cookie|authorization|token/i.test(k) ? vv.slice(0, 40) + `...(len=${vv.length})` : vv;
        log('    ' + k + ': ' + shown);
      }
    }
    if (!captured.length) log('[!] 没抓到页面请求（页面可能没发这个请求）');

    closeChrome();
    return;
  }

  const deadline = Date.now() + MAX_WAIT_MS;
  let last = '';
  let lastSig = '';

  while (Date.now() < deadline) {
    let cookies = [];
    try {
      const res = await cdp.send('Network.getAllCookies', {}, sessionId);
      cookies = res.cookies || [];
    } catch (e) {
      // 调试通道关闭 = 浏览器没了，没必要空转到 6 分钟超时
      if (cdp.closed || (CHROME && CHROME.exitCode !== null)) {
        log('\n[!] 浏览器已关闭，授权已取消。');
        writeResult('cancel', 'channel-closed');
        process.exit(3);
      }
      process.stdout.write('x');
      await sleep(POLL_MS);
      continue;
    }

    if (!cookies.length) {
      process.stdout.write('.');
      await sleep(POLL_MS);
      continue;
    }

    // 登录成功的标志是业务会话 cookie（session/session_2）出现。
    // 在此之前不打接口，避免 Keycloak 中间态 cookie 变化触发几十次无效请求。
    // 60 秒兜底：万一站点改名，退回「cookie 变化即探测」的旧逻辑。
    const hasSession = cookies.some((c) => c.name === 'session' || c.name === 'session_2');
    if (!hasSession && Date.now() - deadline < MAX_WAIT_MS - 60000) {
      process.stdout.write('.');
      await sleep(POLL_MS);
      continue;
    }

    // 登录判定：在页面上下文里 fetch（走 Chromium 网络栈）。
    // 不能用 curl 带 cookie 打接口——网关按 TLS 指纹拦截外部客户端，永远 401。
    let status = 0;
    try {
      const r = await cdp.send(
        'Runtime.evaluate',
        {
          expression: `fetch('https://www.workbuddy.cn/billing/meter/get-user-resource-summary',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(x=>x.status).catch(()=>'CORS')`,
          awaitPromise: true,
          returnByValue: true,
        },
        sessionId
      );
      status = parseInt(String((r.result && r.result.value) || 0), 10) || 0;
    } catch (e) {
      if (cdp.closed || (CHROME && CHROME.exitCode !== null)) {
        log('\n[!] 浏览器已关闭，授权已取消。');
        writeResult('cancel', 'channel-closed');
        process.exit(3);
      }
      process.stdout.write('!');
      await sleep(POLL_MS);
      continue;
    }

    if (status === 200) {
      log('\n[✓] 登录成功（页面内验证通过）');
      log('[✓] 登录态已保存在 .browser-profile，查询时无需再登录');
      log('');
      writeResult('ok', 'login-verified');
      closeChrome();
      runDetailScript();
      process.exit(0);   // 显式退出：日志流/管道会挂住事件循环
      return;
    }
    const tag = 'probe:' + status;
    if (tag !== last) {
      last = tag;
      log(`\n    页面内验证 HTTP ${status}，继续等登录 `);
    }
    await sleep(POLL_MS);
  }

  log('\n[X] 超时，没拿到有效登录态。');
  writeResult('timeout', 'no-login-in-6min');
  closeChrome();
  process.exit(1);
}

function runDetailScript() {
  const q = path.join(HERE, 'wb_query.js');
  if (!fs.existsSync(q)) return;
  log('--- 立即查询一次（wb_query.js）---');
  const node = process.execPath;
  const r = spawnSync(node, [q], { stdio: 'inherit', cwd: HERE });
  if (r.error) log('[!] 查询失败，可手动跑 查询积分.cmd');
}

main().catch((e) => {
  log('\n[X] ' + (e && e.message ? e.message : String(e)));
  writeResult('fail', e && e.message ? e.message : String(e));
  closeChrome();
  process.exit(1);
});
