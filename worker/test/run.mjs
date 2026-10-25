// ローカル結合テスト：本物の Worker ランタイム（wrangler dev / workerd）を起動し、
// OpenAI・Anthropic はローカルのモックサーバーに差し替えて全エンドポイントを叩く。
import { spawn, execSync } from 'node:child_process';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const MOCK_PORT = 8788, WORKER_PORT = 8789;
const WEBHOOK_SECRET = 'whsec_test123';
let upstreamCalls = { openai: 0, anthropic: 0 };

// ── upstream mocks ──
const mock = http.createServer((req, res) => {
  let body = [];
  req.on('data', c => body.push(c));
  req.on('end', () => {
    const buf = Buffer.concat(body);
    if (req.url === '/v1/audio/transcriptions') {
      upstreamCalls.openai++;
      const auth = req.headers.authorization;
      const s = buf.toString('latin1');
      const ok = auth === 'Bearer sk-test-openai' && s.includes('gpt-4o-transcribe') && s.includes('name="language"');
      res.writeHead(ok ? 200 : 401, { 'Content-Type': 'text/plain' });
      return res.end(ok ? 'ベンチプレス80キロ10回\n' : 'bad');
    }
    if (req.url === '/v1/messages') {
      upstreamCalls.anthropic++;
      const j = JSON.parse(buf.toString());
      const ok = req.headers['x-api-key'] === 'sk-ant-test' && j.model === 'claude-haiku-5-5';
      res.writeHead(ok ? 200 : 401, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ content: [{ type: 'text', text: '{"exercise":"スクワット","weight":60,"reps":12,"seconds":null,"set_end":false,"note":null}' }] }));
    }
    res.writeHead(404); res.end();
  });
}).listen(MOCK_PORT);

// ── start worker ──
fs.writeFileSync('.dev.vars', [
  'OPENAI_API_KEY=sk-test-openai', 'ANTHROPIC_API_KEY=sk-ant-test',
  `STRIPE_WEBHOOK_SECRET=${WEBHOOK_SECRET}`, 'ADMIN_KEY=adm', 'IP_SALT=s',
  `OPENAI_BASE=http://127.0.0.1:${MOCK_PORT}`, `ANTHROPIC_BASE=http://127.0.0.1:${MOCK_PORT}`,
  'PAYMENT_LINK_MONTHLY=https://buy.stripe.com/test_m', 'FREE_VOICE_DAYS_PER_MONTH=1', 'TRIAL_DAYS=14',
].join('\n'));
fs.rmSync('.wrangler', { recursive: true, force: true });
execSync('npx wrangler d1 execute talkfit --local --file=schema.sql', { stdio: 'pipe' });
const w = spawn('npx', ['wrangler', 'dev', '--port', String(WORKER_PORT), '--local', '--ip', '127.0.0.1'], { stdio: ['ignore', 'pipe', 'pipe'] });
let wlog = ''; w.stdout.on('data', d => wlog += d); w.stderr.on('data', d => wlog += d);

const base = `http://127.0.0.1:${WORKER_PORT}`;
for (let i = 0; i < 120; i++) {
  try { const r = await fetch(base + '/health'); if (r.ok) break; } catch (_) {}
  await new Promise(r => setTimeout(r, 500));
}

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ✓', name); }
  else { fail++; console.log('  ✗', name, extra !== undefined ? JSON.stringify(extra) : ''); }
}
const sql = s => JSON.parse(execSync(`npx wrangler d1 execute talkfit --local --json --command "${s}"`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString())[0].results;

const dev = crypto.randomUUID();
const H = { 'X-Device': dev };

try {
  console.log('基本');
  check('health', (await fetch(base + '/health')).ok);
  let r = await fetch(base + '/v1/me');
  check('端末IDなしは拒否', r.status === 400);

  r = await (await fetch(base + '/v1/me', { headers: H })).json();
  check('新規端末は trial', r.plan === 'trial' && r.trialDaysLeft === 14, r);
  check('決済リンクを配信', r.config.checkoutMonthly === 'https://buy.stripe.com/test_m');

  console.log('音声認識');
  const fd = () => { const f = new FormData(); f.append('file', new Blob([new Uint8Array(4000)], { type: 'audio/webm' }), 'a.webm'); f.append('prompt', 'ベンチプレス'); return f; };
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: { ...H, 'X-Audio-Sec': '5' }, body: fd() });
  let j = await r.json();
  check('trial中は書き起こしできる', r.status === 200 && j.text === 'ベンチプレス80キロ10回', j);
  check('APIキーはサーバー側で付与', upstreamCalls.openai === 1);

  const tiny = new FormData(); tiny.append('file', new Blob([new Uint8Array(100)]), 'a.webm');
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: H, body: tiny });
  check('極小音声は上流に送らない', (await r.json()).text === '' && upstreamCalls.openai === 1);

  console.log('発話解析');
  r = await fetch(base + '/v1/parse', { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ text: 'スクワット六十で十二', candidates: ['スクワット'], last: '' }) });
  j = await r.json();
  check('Claude経由で構造化', j.result && j.result.reps === 12 && j.result.weight === 60, j);

  console.log('無料プラン（体験終了後）');
  const dev2 = crypto.randomUUID();
  await fetch(base + '/v1/me', { headers: { 'X-Device': dev2 } });
  sql(`UPDATE devices SET created_at = created_at - 20*86400000 WHERE id='${dev2}'`);
  r = await (await fetch(base + '/v1/me', { headers: { 'X-Device': dev2 } })).json();
  check('15日目以降は free', r.plan === 'free' && r.voiceAllowed === true && r.freeVoiceDaysLeft === 1, r);
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: { 'X-Device': dev2 }, body: fd() });
  check('無料枠1日目は使える', r.status === 200);
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: { 'X-Device': dev2 }, body: fd() });
  check('同じ日はそのまま使える', r.status === 200);
  sql(`UPDATE voice_usage SET day = strftime('%Y-%m', 'now', '+9 hours') || '-01' WHERE device_id='${dev2}'`);
  // 当日以外の日に使った扱いにする（月初に移動）。今日が1日なら別日に。
  const today = sql(`SELECT strftime('%Y-%m-%d','now','+9 hours') AS d`)[0].d;
  if (today.endsWith('-01')) sql(`UPDATE voice_usage SET day = strftime('%Y-%m', 'now', '+9 hours') || '-02' WHERE device_id='${dev2}'`);
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: { 'X-Device': dev2 }, body: fd() });
  j = await r.json();
  check('無料枠を使い切ると 402 で課金画面へ', r.status === 402 && j.error === 'paywall', j);

  console.log('Stripe 決済');
  const sign = (payload, secret = WEBHOOK_SECRET, t = Math.floor(Date.now() / 1000)) =>
    `t=${t},v1=${crypto.createHmac('sha256', secret).update(`${t}.${payload}`).digest('hex')}`;
  const post = (evt, sig) => { const p = JSON.stringify(evt); return fetch(base + '/v1/stripe/webhook', { method: 'POST', headers: { 'Stripe-Signature': sig || sign(p) }, body: p }); };
  const evt = { id: 'evt_1', type: 'checkout.session.completed', data: { object: { client_reference_id: dev2, customer: 'cus_1', subscription: 'sub_1', amount_total: 680, customer_details: { email: 'a@example.com' } } } };
  r = await post(evt, sign(JSON.stringify(evt), 'whsec_wrong'));
  check('署名が違えば拒否', r.status === 400);
  r = await post(evt, sign(JSON.stringify(evt), WEBHOOK_SECRET, Math.floor(Date.now() / 1000) - 3600));
  check('古いタイムスタンプは拒否（リプレイ対策）', r.status === 400);
  r = await post(evt);
  check('正しい署名は受理', r.status === 200);
  r = await post(evt);
  check('同じイベントの再送は二重処理しない', r.status === 200 && sql(`SELECT COUNT(*) AS n FROM licenses`)[0].n === 1);
  r = await (await fetch(base + '/v1/me', { headers: { 'X-Device': dev2 } })).json();
  check('決済後は premium・引き継ぎコード発行', r.plan === 'premium' && /^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(r.license) && r.licensePlan === 'monthly', r);
  const code = r.license;
  r = await fetch(base + '/v1/transcribe', { method: 'POST', headers: { 'X-Device': dev2 }, body: fd() });
  check('premium は無料枠に関係なく使える', r.status === 200);

  console.log('機種変更（引き継ぎ）');
  const dev3 = crypto.randomUUID();
  r = await fetch(base + '/v1/restore', { method: 'POST', headers: { 'X-Device': dev3, 'Content-Type': 'application/json' }, body: JSON.stringify({ code: 'ZZZZ-ZZZZ' }) });
  check('存在しないコードは 404', r.status === 404);
  r = await fetch(base + '/v1/restore', { method: 'POST', headers: { 'X-Device': dev3, 'Content-Type': 'application/json' }, body: JSON.stringify({ code: code.toLowerCase().replace('-', ' ') }) });
  j = await r.json();
  check('小文字・区切り違いでも引き継げる', r.status === 200 && j.plan === 'premium', j);

  console.log('解約');
  r = await post({ id: 'evt_2', type: 'customer.subscription.deleted', data: { object: { id: 'sub_1', customer: 'cus_1', status: 'canceled' } } });
  r = await (await fetch(base + '/v1/me', { headers: { 'X-Device': dev3 } })).json();
  check('解約で premium が外れる', r.plan !== 'premium', r);
  r = await post({ id: 'evt_3', type: 'checkout.session.completed', data: { object: { client_reference_id: dev3, customer: 'cus_1', subscription: 'sub_2', amount_total: 5800 } } });
  r = await (await fetch(base + '/v1/me', { headers: { 'X-Device': dev3 } })).json();
  check('再購入は同じコードを再利用（年額）', r.plan === 'premium' && r.license === code && r.licensePlan === 'yearly', r);

  console.log('計測・管理');
  r = await fetch(base + '/v1/event', { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ events: ['app_open', 'set_voice', 'set_voice', 'evil_name'] }) });
  check('イベント受理', r.ok);
  r = await fetch(base + '/v1/event', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'lp_view' }) });
  check('LPからのイベント（端末IDなし）', r.ok);
  check('許可外のイベント名は保存しない', sql(`SELECT COUNT(*) AS n FROM events WHERE name='evil_name'`)[0].n === 0);
  r = await fetch(base + '/admin/stats?key=wrong');
  check('管理画面は鍵なしで拒否', r.status === 403);
  j = await (await fetch(base + '/admin/stats?key=adm')).json();
  check('管理統計：有料1件・年額MRR', j.totals.premium === 1 && j.totals.mrr === 483, j.totals);
  r = await fetch(base + '/admin?key=adm');
  check('管理ダッシュボード表示', r.ok && (await r.text()).includes('TalkFit 管理'));

  console.log('CORS');
  r = await fetch(base + '/v1/me', { method: 'OPTIONS', headers: { Origin: 'https://gfe25.github.io' } });
  check('プリフライト許可', r.status === 204 && r.headers.get('access-control-allow-origin') === 'https://gfe25.github.io');
} catch (e) {
  fail++; console.log('例外', e); console.log(wlog.slice(-3000));
} finally {
  console.log(`\n${pass} passed, ${fail} failed`);
  w.kill(); mock.close(); fs.rmSync('.dev.vars', { force: true });
  process.exit(fail ? 1 : 0);
}
