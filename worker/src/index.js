// TalkFit API — Cloudflare Worker
//
// 役割
//  1. OpenAI / Claude の APIキーをサーバー側に隠す（ユーザーはキー入力不要）
//  2. 無料体験 → 有料プランの利用権を判定する
//  3. Stripe の決済結果を受け取り、引き継ぎコード（ライセンス）を発行する
//  4. 継続率・ファネルを計測する
//
// 端末は X-Device ヘッダー（アプリが生成したUUID）で識別する。ログインはない。

const DAY_MS = 86400000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 0/O, 1/I を除外

// アプリから受け付けるイベント名（それ以外は捨てる）
const EVENT_NAMES = new Set([
  'app_open', 'onboard_done', 'voice_start', 'set_voice', 'set_manual',
  'session_end', 'paywall_view', 'checkout_click', 'checkout_success',
  'share_card', 'restore_ok', 'lp_view', 'lp_cta', 'install_hint', 'pwa_open', 'mic_blocked', 'app_native_open',
]);

// ───────────────────────── helpers ─────────────────────────

function cfgNum(env, key, def) {
  const n = parseFloat(env[key]);
  return isFinite(n) ? n : def;
}

function jstDay(ts = Date.now()) {
  return new Date(ts + 9 * 3600e3).toISOString().slice(0, 10);
}

function corsHeaders(env, req) {
  const origin = req.headers.get('Origin') || '';
  const allowed = (env.ALLOWED_ORIGINS || '*').split(',').map(s => s.trim()).filter(Boolean);
  const allow = allowed.includes('*') ? '*' : (allowed.includes(origin) ? origin : allowed[0] || '');
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Device,X-Audio-Sec',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
}

function json(data, status, cors) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...cors },
  });
}

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}

function newLicenseCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let s = '';
  for (const b of bytes) s += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return s.slice(0, 4) + '-' + s.slice(4);
}

function normalizeCode(c) {
  const s = String(c || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  return s.length === 8 ? s.slice(0, 4) + '-' + s.slice(4) : null;
}

// ───────────────────────── data access ─────────────────────────

async function getOrCreateDevice(env, id) {
  const now = Date.now();
  let d = await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first();
  if (!d) {
    await env.DB.prepare('INSERT OR IGNORE INTO devices (id, created_at, updated_at) VALUES (?,?,?)')
      .bind(id, now, now).run();
    d = { id, created_at: now, license: null, updated_at: now, _new: true };
  }
  return d;
}

async function markActive(env, deviceId) {
  await env.DB.prepare('INSERT OR IGNORE INTO active_days (device_id, day) VALUES (?,?)')
    .bind(deviceId, jstDay()).run();
}

async function bumpEvent(env, name, n = 1) {
  await env.DB.prepare(
    'INSERT INTO events (day, name, n) VALUES (?,?,?) ON CONFLICT(day, name) DO UPDATE SET n = n + excluded.n'
  ).bind(jstDay(), name, n).run();
}

// 端末の利用権を判定する。課金判定のロジックはここに集約する。
async function entitlement(env, device) {
  const now = Date.now();
  const trialDays = cfgNum(env, 'TRIAL_DAYS', 14);
  const freeDays = cfgNum(env, 'FREE_VOICE_DAYS_PER_MONTH', 4);
  const today = jstDay();
  const month = today.slice(0, 7);

  let license = null;
  if (device.license) {
    license = await env.DB.prepare('SELECT * FROM licenses WHERE code=?').bind(device.license).first();
  }
  const premium = !!(license && license.status === 'active');

  const trialEnds = device.created_at + trialDays * DAY_MS;
  const inTrial = now < trialEnds;

  const usedRow = await env.DB.prepare(
    "SELECT COUNT(*) AS n, SUM(CASE WHEN day=? THEN 1 ELSE 0 END) AS today FROM voice_usage WHERE device_id=? AND day LIKE ? AND req>0"
  ).bind(today, device.id, month + '%').first();
  const usedDays = usedRow ? (usedRow.n || 0) : 0;
  const usedToday = usedRow ? (usedRow.today || 0) > 0 : false;

  const plan = premium ? 'premium' : (inTrial ? 'trial' : 'free');
  const freeLeft = Math.max(0, freeDays - usedDays);
  const voiceAllowed = premium || inTrial || usedToday || freeLeft > 0;

  return {
    plan,
    voiceAllowed,
    trialDaysLeft: inTrial ? Math.ceil((trialEnds - now) / DAY_MS) : 0,
    freeVoiceDaysPerMonth: freeDays,
    freeVoiceDaysLeft: plan === 'free' ? (usedToday ? freeLeft : freeLeft) : null,
    usedToday,
    license: premium ? license.code : null,
    licensePlan: premium ? license.plan : null,
  };
}

function publicConfig(env) {
  return {
    priceMonthly: cfgNum(env, 'PRICE_MONTHLY', 680),
    priceYearly: cfgNum(env, 'PRICE_YEARLY', 5800),
    checkoutMonthly: env.PAYMENT_LINK_MONTHLY || '',
    checkoutYearly: env.PAYMENT_LINK_YEARLY || '',
    portalUrl: env.PORTAL_URL || '',
    contact: env.CONTACT_URL || '',
  };
}

// 乱用防止：1日あたりの上限
async function checkCaps(env, req, deviceId, audioSec) {
  const today = jstDay();
  const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
  const ipHash = (await sha256Hex(ip + (env.IP_SALT || 'talkfit'))).slice(0, 16);
  const ipRow = await env.DB.prepare('SELECT req FROM ip_usage WHERE ip_hash=? AND day=?').bind(ipHash, today).first();
  if (ipRow && ipRow.req >= cfgNum(env, 'MAX_REQ_PER_IP_DAY', 3000)) return 'ip_cap';

  const u = await env.DB.prepare('SELECT sec, req FROM voice_usage WHERE device_id=? AND day=?').bind(deviceId, today).first();
  if (u && u.sec + audioSec > cfgNum(env, 'MAX_AUDIO_SEC_PER_DAY', 7200)) return 'daily_cap';

  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO ip_usage (ip_hash, day, req) VALUES (?,?,1) ON CONFLICT(ip_hash, day) DO UPDATE SET req = req + 1'
    ).bind(ipHash, today),
    env.DB.prepare(
      'INSERT INTO voice_usage (device_id, day, sec, req) VALUES (?,?,?,1) ON CONFLICT(device_id, day) DO UPDATE SET sec = sec + excluded.sec, req = req + 1'
    ).bind(deviceId, today, audioSec),
  ]);
  return null;
}

// ───────────────────────── handlers ─────────────────────────

async function handleMe(env, device, cors) {
  const ent = await entitlement(env, device);
  return json({ ...ent, config: publicConfig(env) }, 200, cors);
}

async function handleTranscribe(env, req, device, cors) {
  const ent = await entitlement(env, device);
  if (!ent.voiceAllowed) return json({ error: 'paywall', ...ent, config: publicConfig(env) }, 402, cors);

  const audioSec = Math.min(15, Math.max(0.3, parseFloat(req.headers.get('X-Audio-Sec')) || 8));

  const form = await req.formData();
  const file = form.get('file');
  if (!file || typeof file === 'string') return json({ error: 'no_file' }, 400, cors);
  if (file.size > 3 * 1024 * 1024) return json({ error: 'too_large' }, 413, cors);
  if (file.size < 1500) return json({ text: '' }, 200, cors);

  const cap = await checkCaps(env, req, device.id, audioSec);
  if (cap) return json({ error: cap }, 429, cors);

  const out = new FormData();
  out.append('file', file, file.name || 'audio.webm');
  out.append('model', env.TRANSCRIBE_MODEL || 'gpt-4o-transcribe');
  out.append('response_format', 'text');
  out.append('language', 'ja');
  const prompt = String(form.get('prompt') || '').slice(0, 800);
  if (prompt) out.append('prompt', prompt);

  const base = env.OPENAI_BASE || 'https://api.openai.com';
  let res;
  for (let attempt = 0; attempt < 3; attempt++) {
    res = await fetch(base + '/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + env.OPENAI_API_KEY },
      body: out,
    });
    if (res.status !== 429 && res.status < 500) break;
    await new Promise(r => setTimeout(r, 800 * (attempt + 1)));
  }
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    // 短すぎる音声は物音。エラーとして見せる価値がない
    if (res.status === 400 && /too_short|too short/i.test(body)) return json({ text: '' }, 200, cors);
    console.log('transcribe upstream', res.status, body);
    return json({ error: 'upstream', status: res.status }, 502, cors);
  }
  const text = (await res.text()).trim();
  return json({ text }, 200, cors);
}

async function handleParse(env, req, device, cors) {
  const body = await req.json().catch(() => ({}));
  const text = String(body.text || '').slice(0, 300);
  if (!text) return json({ result: null }, 200, cors);
  const candidates = Array.isArray(body.candidates) ? body.candidates.slice(0, 200).map(s => String(s).slice(0, 30)) : [];
  const last = String(body.last || '').slice(0, 30);

  const today = jstDay();
  const u = await env.DB.prepare('SELECT req FROM voice_usage WHERE device_id=? AND day=?').bind(device.id, today).first();
  if (u && u.req > cfgNum(env, 'MAX_REQ_PER_DEVICE_DAY', 2000)) return json({ error: 'daily_cap' }, 429, cors);

  const prompt =
`次の日本語発話から筋トレのセット情報を抽出してください。

ルール:
- 数字は漢数字・読み（「ろくじゅっきろ」「じゅっかい」）も解釈する
- 種目が明示されていない場合は exercise を null に
- 「同じで」「もう一回」「また」など相対表現は exercise:null weight:null
- 「セット終わり」「次」など制御発話は set_end:true
- 腕立て・腹筋・懸垂など自重種目は weight:null（回数だけ）
- プランクなど時間で計る種目は seconds に秒数（「1分30秒」→90）、reps:null
- 雑談・無関係な音は全フィールドnull
- weight, reps, seconds は数値または null（文字列は禁止）
- JSONオブジェクトのみを返し、説明文やマークダウンは付けない

種目名の候補: ${candidates.join('、')}
直前の種目: ${last || 'なし'}

発話: "${text.replace(/"/g, '”')}"

キー: exercise(string|null), weight(number|null), reps(number|null), seconds(number|null), set_end(boolean), note(string|null)`;

  const base = env.ANTHROPIC_BASE || 'https://api.anthropic.com';
  const res = await fetch(base + '/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: env.PARSE_MODEL || 'claude-haiku-5-5',
      max_tokens: 200,
      messages: [{ role: 'user', content: prompt }],
    }),
  });
  if (!res.ok) {
    console.log('parse upstream', res.status, (await res.text()).slice(0, 300));
    return json({ error: 'upstream', status: res.status }, 502, cors);
  }
  const data = await res.json();
  const outText = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('');
  const m = outText.match(/\{[\s\S]*\}/);
  let result = null;
  try { result = m ? JSON.parse(m[0]) : null; } catch (_) { result = null; }
  return json({ result }, 200, cors);
}

async function handleRestore(env, req, device, cors) {
  const body = await req.json().catch(() => ({}));
  const code = normalizeCode(body.code);
  if (!code) return json({ error: 'bad_code' }, 400, cors);
  const lic = await env.DB.prepare('SELECT * FROM licenses WHERE code=?').bind(code).first();
  if (!lic) return json({ error: 'not_found' }, 404, cors);
  if (lic.status !== 'active') return json({ error: 'inactive' }, 409, cors);
  await env.DB.prepare('UPDATE devices SET license=?, updated_at=? WHERE id=?').bind(code, Date.now(), device.id).run();
  await bumpEvent(env, 'restore_ok');
  return handleMe(env, { ...device, license: code }, cors);
}

async function handleEvent(env, req, device, cors) {
  const body = await req.json().catch(() => ({}));
  const names = Array.isArray(body.events) ? body.events : [body.name];
  const counts = {};
  for (const n of names.slice(0, 50)) if (EVENT_NAMES.has(n)) counts[n] = (counts[n] || 0) + 1;
  const stmts = Object.entries(counts).map(([name, n]) => env.DB.prepare(
    'INSERT INTO events (day, name, n) VALUES (?,?,?) ON CONFLICT(day, name) DO UPDATE SET n = n + excluded.n'
  ).bind(jstDay(), name, n));
  if (device && counts.set_voice) {
    stmts.push(env.DB.prepare(
      'INSERT INTO voice_usage (device_id, day, sets) VALUES (?,?,?) ON CONFLICT(device_id, day) DO UPDATE SET sets = sets + excluded.sets'
    ).bind(device.id, jstDay(), counts.set_voice));
  }
  if (stmts.length) await env.DB.batch(stmts);
  return json({ ok: true }, 200, cors);
}

// ── Stripe ──

async function verifyStripe(env, req, raw) {
  const header = req.headers.get('Stripe-Signature') || '';
  const parts = Object.fromEntries(header.split(',').map(kv => {
    const i = kv.indexOf('='); return [kv.slice(0, i).trim(), kv.slice(i + 1)];
  }));
  const sigs = header.split(',').filter(kv => kv.trim().startsWith('v1=')).map(kv => kv.trim().slice(3));
  const t = parseInt(parts.t, 10);
  if (!t || !sigs.length || !env.STRIPE_WEBHOOK_SECRET) return false;
  if (Math.abs(Date.now() / 1000 - t) > 300) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.STRIPE_WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`));
  const expected = [...new Uint8Array(mac)].map(b => b.toString(16).padStart(2, '0')).join('');
  return sigs.some(s => s.length === expected.length && timingSafeEqual(s, expected));
}

function timingSafeEqual(a, b) {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const ACTIVE_SUB = new Set(['active', 'trialing', 'past_due']);

async function handleStripe(env, req) {
  const raw = await req.text();
  if (!(await verifyStripe(env, req, raw))) return new Response('bad signature', { status: 400 });
  const evt = JSON.parse(raw);

  const seen = await env.DB.prepare('SELECT id FROM stripe_events WHERE id=?').bind(evt.id).first();
  if (seen) return new Response('ok');
  await env.DB.prepare('INSERT INTO stripe_events (id, created_at) VALUES (?,?)').bind(evt.id, Date.now()).run();

  const obj = evt.data && evt.data.object || {};
  const now = Date.now();

  if (evt.type === 'checkout.session.completed') {
    const deviceId = obj.client_reference_id;
    // 同じ顧客の既存ライセンスがあれば再利用（再購入・プラン変更で増殖させない）
    let lic = obj.customer
      ? await env.DB.prepare('SELECT * FROM licenses WHERE stripe_customer=?').bind(obj.customer).first()
      : null;
    const plan = (obj.amount_total || 0) >= cfgNum(env, 'PRICE_YEARLY', 5800) ? 'yearly' : 'monthly';
    const email = (obj.customer_details && obj.customer_details.email) || obj.customer_email || null;
    let code;
    if (lic) {
      code = lic.code;
      await env.DB.prepare('UPDATE licenses SET status=?, plan=?, stripe_sub=?, email=COALESCE(?, email), updated_at=? WHERE code=?')
        .bind('active', plan, obj.subscription || lic.stripe_sub, email, now, code).run();
    } else {
      code = newLicenseCode();
      await env.DB.prepare('INSERT INTO licenses (code, status, plan, stripe_customer, stripe_sub, email, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)')
        .bind(code, 'active', plan, obj.customer || null, obj.subscription || null, email, now, now).run();
    }
    if (deviceId && UUID_RE.test(deviceId)) {
      await env.DB.prepare('INSERT OR IGNORE INTO devices (id, created_at, updated_at) VALUES (?,?,?)').bind(deviceId, now, now).run();
      await env.DB.prepare('UPDATE devices SET license=?, updated_at=? WHERE id=?').bind(code, now, deviceId).run();
    }
    await bumpEvent(env, 'checkout_success');
  } else if (evt.type === 'customer.subscription.updated' || evt.type === 'customer.subscription.deleted') {
    const status = evt.type === 'customer.subscription.deleted' ? 'canceled' : (ACTIVE_SUB.has(obj.status) ? 'active' : 'canceled');
    await env.DB.prepare('UPDATE licenses SET status=?, updated_at=? WHERE stripe_sub=? OR (stripe_sub IS NULL AND stripe_customer=?)')
      .bind(status, now, obj.id, obj.customer || '').run();
  }
  return new Response('ok');
}

// ── Admin ──

async function adminStats(env) {
  const since = jstDay(Date.now() - 27 * DAY_MS);
  const q = (sql, ...b) => env.DB.prepare(sql).bind(...b).all().then(r => r.results || []);
  const one = (sql, ...b) => env.DB.prepare(sql).bind(...b).first();

  const [devices, premium, byPlan, dau, newDev, events, voiceDays] = await Promise.all([
    one('SELECT COUNT(*) AS n FROM devices'),
    one("SELECT COUNT(*) AS n FROM licenses WHERE status='active'"),
    q("SELECT plan, COUNT(*) AS n FROM licenses WHERE status='active' GROUP BY plan"),
    q('SELECT day, COUNT(*) AS n FROM active_days WHERE day>=? GROUP BY day ORDER BY day', since),
    q("SELECT strftime('%Y-%m-%d', (created_at/1000)+32400, 'unixepoch') AS day, COUNT(*) AS n FROM devices WHERE created_at>=? GROUP BY day ORDER BY day", Date.now() - 28 * DAY_MS),
    q('SELECT day, name, n FROM events WHERE day>=? ORDER BY day', since),
    q('SELECT day, COUNT(*) AS users, SUM(sets) AS sets, ROUND(SUM(sec)/60.0,1) AS minutes FROM voice_usage WHERE day>=? GROUP BY day ORDER BY day', since),
  ]);

  // 新規の7日後継続率（D7）：作成から7〜13日後に一度でも開いた割合
  const d7 = await one(
    `SELECT COUNT(DISTINCT d.id) AS cohort,
            COUNT(DISTINCT CASE WHEN a.day IS NOT NULL THEN d.id END) AS retained
     FROM devices d
     LEFT JOIN active_days a ON a.device_id = d.id
       AND a.day >= strftime('%Y-%m-%d', (d.created_at/1000)+32400+7*86400, 'unixepoch')
       AND a.day <  strftime('%Y-%m-%d', (d.created_at/1000)+32400+14*86400, 'unixepoch')
     WHERE d.created_at < ? AND d.created_at >= ?`,
    Date.now() - 14 * DAY_MS, Date.now() - 60 * DAY_MS
  );

  const pm = cfgNum(env, 'PRICE_MONTHLY', 680), py = cfgNum(env, 'PRICE_YEARLY', 5800);
  const mrr = byPlan.reduce((s, r) => s + r.n * (r.plan === 'yearly' ? py / 12 : pm), 0);
  return {
    totals: { devices: devices.n, premium: premium.n, mrr: Math.round(mrr), goal: 100000 },
    byPlan, dau, newDevices: newDev, voiceDays, events,
    retentionD7: d7 && d7.cohort ? { cohort: d7.cohort, retained: d7.retained, rate: d7.retained / d7.cohort } : null,
  };
}

function adminPage() {
  return new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TalkFit 管理</title>
<style>body{font:14px -apple-system,system-ui,sans-serif;background:#0c0c0e;color:#f2f2f7;margin:0;padding:16px;max-width:900px}
h1{font-size:18px}h2{font-size:14px;color:#8e8e93;margin-top:24px}.k{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px}
.c{background:#1c1c1e;border-radius:12px;padding:12px}.c b{display:block;font-size:24px;margin-top:4px}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}td,th{padding:4px 6px;border-bottom:1px solid #2c2c2e;text-align:right}td:first-child,th:first-child{text-align:left}
.bar{height:6px;background:#2c2c2e;border-radius:3px;overflow:hidden;margin-top:8px}.bar i{display:block;height:100%;background:#4f7fff}</style>
<h1>TalkFit 管理ダッシュボード</h1><div id="o">読み込み中…</div>
<script>
const key=new URLSearchParams(location.search).get('key');
fetch('/admin/stats?key='+encodeURIComponent(key)).then(r=>r.json()).then(s=>{
 const t=s.totals, pct=Math.min(100,t.mrr/t.goal*100);
 const days=[...new Set([...s.dau.map(r=>r.day),...s.events.map(r=>r.day)])].sort().reverse();
 const names=[...new Set(s.events.map(r=>r.name))];
 const ev=(d,n)=>(s.events.find(r=>r.day===d&&r.name===n)||{}).n||'';
 const dau=d=>(s.dau.find(r=>r.day===d)||{}).n||'';
 const nd=d=>(s.newDevices.find(r=>r.day===d)||{}).n||'';
 const vs=d=>(s.voiceDays.find(r=>r.day===d)||{});
 document.getElementById('o').innerHTML=
 '<div class="k"><div class="c">MRR<b>¥'+t.mrr.toLocaleString()+'</b><div class="bar"><i style="width:'+pct+'%"></i></div>目標 ¥'+t.goal.toLocaleString()+'</div>'
 +'<div class="c">有料会員<b>'+t.premium+'</b></div><div class="c">累計端末<b>'+t.devices+'</b></div>'
 +'<div class="c">D7継続率<b>'+(s.retentionD7?Math.round(s.retentionD7.rate*100)+'%':'—')+'</b>'+(s.retentionD7?s.retentionD7.retained+'/'+s.retentionD7.cohort:'')+'</div></div>'
 +'<h2>日別</h2><div style="overflow-x:auto"><table><tr><th>日</th><th>新規</th><th>DAU</th><th>音声利用</th><th>音声記録</th><th>分</th>'+names.map(n=>'<th>'+n+'</th>').join('')+'</tr>'
 +days.map(d=>'<tr><td>'+d.slice(5)+'</td><td>'+nd(d)+'</td><td>'+dau(d)+'</td><td>'+(vs(d).users||'')+'</td><td>'+(vs(d).sets||'')+'</td><td>'+(vs(d).minutes||'')+'</td>'+names.map(n=>'<td>'+ev(d,n)+'</td>').join('')+'</tr>').join('')+'</table></div>';
}).catch(e=>{document.getElementById('o').textContent='読み込めません（キーを確認）'});
</script>`, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

// ───────────────────────── router ─────────────────────────

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const cors = corsHeaders(env, req);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

    try {
      if (url.pathname === '/health') return json({ ok: true }, 200, cors);
      if (url.pathname === '/v1/stripe/webhook' && req.method === 'POST') return await handleStripe(env, req);

      if (url.pathname.startsWith('/admin')) {
        if (!env.ADMIN_KEY || url.searchParams.get('key') !== env.ADMIN_KEY) return new Response('forbidden', { status: 403 });
        if (url.pathname === '/admin/stats') return json(await adminStats(env), 200, {});
        return adminPage();
      }

      // LPなど端末IDを持たない計測
      if (url.pathname === '/v1/event' && req.method === 'POST' && !req.headers.get('X-Device')) {
        return await handleEvent(env, req, null, cors);
      }

      const deviceId = req.headers.get('X-Device') || '';
      if (!UUID_RE.test(deviceId)) return json({ error: 'no_device' }, 400, cors);
      const device = await getOrCreateDevice(env, deviceId.toLowerCase());
      await markActive(env, device.id);

      if (url.pathname === '/v1/me' && req.method === 'GET') return await handleMe(env, device, cors);
      if (url.pathname === '/v1/transcribe' && req.method === 'POST') return await handleTranscribe(env, req, device, cors);
      if (url.pathname === '/v1/parse' && req.method === 'POST') return await handleParse(env, req, device, cors);
      if (url.pathname === '/v1/restore' && req.method === 'POST') return await handleRestore(env, req, device, cors);
      if (url.pathname === '/v1/event' && req.method === 'POST') return await handleEvent(env, req, device, cors);

      return json({ error: 'not_found' }, 404, cors);
    } catch (e) {
      console.log('error', e && e.stack || e);
      return json({ error: 'server' }, 500, cors);
    }
  },
};
