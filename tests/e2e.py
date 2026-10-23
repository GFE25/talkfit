"""End-to-end: real app in Chromium (fake mic) + real Worker runtime (wrangler dev)
with OpenAI/Anthropic replaced by a local mock. Exercises trial → voice set → paywall
→ checkout → webhook → Pro → share card."""
import subprocess, threading, time, json, os, hmac, hashlib, uuid, math, struct, wave, re, sys, shutil
from http.server import BaseHTTPRequestHandler, HTTPServer, SimpleHTTPRequestHandler
from functools import partial
import urllib.request
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, 'worker')
TMP = os.environ.get('E2E_TMP', '/tmp/talkfit-e2e')
shutil.rmtree(TMP, ignore_errors=True); os.makedirs(TMP)
MOCK, WPORT, APORT = 8798, 8799, 8800
SECRET = 'whsec_e2e'
calls = {'openai': 0}

class Mock(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
        if self.path == '/v1/audio/transcriptions':
            calls['openai'] += 1
            self.send_response(200); self.send_header('Content-Type', 'text/plain'); self.end_headers()
            self.wfile.write('ベンチプレス80キロ10回'.encode())
        else:
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps({'content': [{'type': 'text', 'text': '{}'}]}).encode())
threading.Thread(target=HTTPServer(('127.0.0.1', MOCK), Mock).serve_forever, daemon=True).start()

# app copy pointed at the local worker
app_dir = os.path.join(TMP, 'app'); shutil.copytree(ROOT, app_dir, ignore=shutil.ignore_patterns('worker', '.git', 'tests', 'node_modules'))
cfgp = os.path.join(app_dir, 'config.js')
c = open(cfgp, encoding='utf-8').read()
assert "apiBase: ''," in c
open(cfgp, 'w', encoding='utf-8').write(c.replace("apiBase: '',", f"apiBase: 'http://127.0.0.1:{WPORT}',"))
threading.Thread(target=HTTPServer(('127.0.0.1', APORT), partial(SimpleHTTPRequestHandler, directory=app_dir)).serve_forever, daemon=True).start()

# fake microphone: loud bursts separated by silence so the chunker cuts
wav = os.path.join(TMP, 'speech.wav')
with wave.open(wav, 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    frames = bytearray()
    for i in range(16000 * 30):
        t = i / 16000; on = (t % 4.0) < 1.6
        v = int(12000 * math.sin(2 * math.pi * 440 * t) * (1 if on else 0)) + int(30 * math.sin(i))
        frames += struct.pack('<h', v)
    w.writeframes(bytes(frames))

# worker
open(os.path.join(WORK, '.dev.vars'), 'w').write('\n'.join([
    'OPENAI_API_KEY=sk', 'ANTHROPIC_API_KEY=sk', f'STRIPE_WEBHOOK_SECRET={SECRET}', 'ADMIN_KEY=adm', 'IP_SALT=s',
    f'OPENAI_BASE=http://127.0.0.1:{MOCK}', f'ANTHROPIC_BASE=http://127.0.0.1:{MOCK}',
    'PAYMENT_LINK_MONTHLY=https://buy.stripe.com/test_m', 'PAYMENT_LINK_YEARLY=https://buy.stripe.com/test_y',
    'PORTAL_URL=https://billing.stripe.com/p/login/test', f'ALLOWED_ORIGINS=http://127.0.0.1:{APORT}', 'FREE_VOICE_DAYS_PER_MONTH=1',
]))
shutil.rmtree(os.path.join(WORK, '.wrangler'), ignore_errors=True)
subprocess.run('npx wrangler d1 execute talkfit --local --file=schema.sql', shell=True, cwd=WORK, check=True, capture_output=True)
wp = subprocess.Popen(f'npx wrangler dev --port {WPORT} --ip 127.0.0.1 --local', shell=True, cwd=WORK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
for _ in range(120):
    try: urllib.request.urlopen(f'http://127.0.0.1:{WPORT}/health'); break
    except Exception: time.sleep(0.5)

def sql(q):
    out = subprocess.run(['npx', 'wrangler', 'd1', 'execute', 'talkfit', '--local', '--json', '--command', q], cwd=WORK, capture_output=True, text=True).stdout
    return json.loads(out)[0]['results']

def webhook(evt):
    body = json.dumps(evt).encode(); t = int(time.time())
    sig = hmac.new(SECRET.encode(), f'{t}.'.encode() + body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(f'http://127.0.0.1:{WPORT}/v1/stripe/webhook', data=body, headers={'Stripe-Signature': f't={t},v1={sig}'})
    return urllib.request.urlopen(req).status

passed = failed = 0
def check(name, cond, extra=''):
    global passed, failed
    if cond: passed += 1; print('  ✓', name)
    else: failed += 1; print('  ✗', name, extra)

errors = []
try:
    with sync_playwright() as p:
        b = p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
                                    f'--use-file-for-fake-audio-capture={wav}', '--autoplay-policy=no-user-gesture-required'])
        ctx = b.new_context(viewport={'width': 390, 'height': 844}, permissions=['microphone'], device_scale_factor=2)
        page = ctx.new_page()
        page.on('pageerror', lambda e: errors.append((e.stack or str(e))[:400]))
        checkout_urls = []
        page.route('https://buy.stripe.com/**', lambda r: (checkout_urls.append(r.request.url), r.fulfill(body='<h1>stripe</h1>', content_type='text/html')))
        page.goto(f'http://127.0.0.1:{APORT}/index.html')
        page.wait_for_timeout(800)

        print('初回起動')
        check('オンボーディング表示', page.is_visible('#onboardOverlay'))
        page.click('#onboardStartBtn'); page.wait_for_timeout(900)
        check('APIキー入力を求めない（設定シートが開かない）', not page.eval_on_selector('#sheetSettings', 'e=>e.classList.contains("on")'))
        page.wait_for_function("document.getElementById('planPill').style.display!=='none'", timeout=8000)
        check('体験中バッジ', '無料体験 残り14日' in page.inner_text('#planPill'), page.inner_text('#planPill'))
        dev = page.evaluate("localStorage.getItem('talkfit_device')")
        check('端末ID生成', bool(re.match(r'^[0-9a-f-]{36}$', dev or '')))
        page.screenshot(path=os.path.join(TMP, '1_record.png'))

        print('声で記録（サーバー経由）')
        page.click('#micBtn')
        try:
            page.wait_for_function("document.getElementById('heroMeta').textContent.startsWith('1 sets')||document.getElementById('heroMeta').textContent.match(/^[1-9]/)", timeout=25000)
            ok = True
        except Exception:
            ok = False
        meta = page.inner_text('#heroMeta')
        check('音声→サーバー→記録まで通る', ok, meta + ' | log: ' + str(page.evaluate("typeof recLog!=='undefined'?recLog.slice(-8):''")))
        check('上流はサーバーのキーで呼ばれた', calls['openai'] >= 1, calls)
        page.screenshot(path=os.path.join(TMP, '2_recorded.png'))
        page.click('#micBtn'); page.wait_for_timeout(1800)
        ev = {r['name']: r['n'] for r in sql('SELECT name, n FROM events')}
        check('計測：app_open / onboard_done / voice_start / set_voice', all(k in ev for k in ['app_open', 'onboard_done', 'voice_start', 'set_voice']), ev)

        print('無料枠切れ → 課金画面')
        sql(f"UPDATE devices SET created_at = created_at - 20*86400000 WHERE id='{dev}'")
        sql(f"UPDATE voice_usage SET day = strftime('%Y-%m','now','+9 hours') || CASE WHEN strftime('%d','now','+9 hours')='01' THEN '-02' ELSE '-01' END WHERE device_id='{dev}'")
        page.reload(); page.wait_for_timeout(1500)
        check('バッジが Proにする に変わる', 'Proにする' in page.inner_text('#planPill'), page.inner_text('#planPill'))
        page.click('#micBtn'); page.wait_for_timeout(1200)
        check('録音を始めず課金画面を出す', page.eval_on_selector('#sheetPlan', 'e=>e.classList.contains("vis")'))
        check('使い切りの文言', '使い切りました' in page.inner_text('#pwTitle'))
        check('年額の割引表示', '%おトク' in page.inner_text('#pwYearlySave'), page.inner_text('#pwYearlySave'))
        page.screenshot(path=os.path.join(TMP, '3_paywall.png'))

        print('決済')
        page.click('#pwMonthly'); page.wait_for_timeout(1500)
        check('Stripeへ端末ID付きで遷移', checkout_urls and f'client_reference_id={dev}' in checkout_urls[0], checkout_urls)
        webhook({'id': 'evt_e2e', 'type': 'checkout.session.completed', 'data': {'object': {'client_reference_id': dev, 'customer': 'cus_e', 'subscription': 'sub_e', 'amount_total': 680}}})
        page.goto(f'http://127.0.0.1:{APORT}/index.html?checkout=success')
        page.wait_for_function("document.getElementById('planPill').textContent==='PRO'", timeout=10000)
        page.wait_for_timeout(800)
        check('戻るとPRO', page.inner_text('#planPill') == 'PRO')
        code = page.inner_text('.pw-code') if page.is_visible('.pw-code') else ''
        check('引き継ぎコードを表示', bool(re.match(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$', code)), code)
        check('解約導線を表示', page.is_visible('#pwPortal'))
        check('URLから checkout パラメータを消す', 'checkout' not in page.url)
        page.screenshot(path=os.path.join(TMP, '4_pro.png'))
        page.click('#pwClose'); page.wait_for_timeout(500)

        print('別端末で引き継ぎ')
        ctx2 = b.new_context(viewport={'width': 390, 'height': 844})
        p2 = ctx2.new_page(); p2.goto(f'http://127.0.0.1:{APORT}/index.html'); p2.wait_for_timeout(800)
        p2.click('#onboardStartBtn'); p2.wait_for_timeout(900)
        p2.click('#planPill'); p2.wait_for_timeout(600)
        p2.fill('#pwCode', code.lower()); p2.click('#pwRestore'); p2.wait_for_timeout(1200)
        check('コード入力でPRO', p2.inner_text('#planPill') == 'PRO', p2.inner_text('#planPill'))

        print('シェア')
        page.evaluate("switchTab('summary')"); page.wait_for_timeout(700)
        with page.expect_download(timeout=8000) as dl:
            page.click('#shareBtn')
        path = os.path.join(TMP, 'share.png'); dl.value.save_as(path)
        check('シェア画像を生成', os.path.getsize(path) > 20000, os.path.getsize(path))
        page.screenshot(path=os.path.join(TMP, '5_summary.png'))

        print('設定')
        page.click('#settingsBtn'); page.wait_for_timeout(600)
        check('APIキー欄は開発者向けに格納', not page.is_visible('#apiKey'))
        page.screenshot(path=os.path.join(TMP, '6_settings.png'))
        check('ページエラーなし', not errors, errors)
        b.close()
finally:
    import signal
    try: os.killpg(wp.pid, signal.SIGTERM)
    except Exception: pass
    subprocess.run(['pkill', '-f', '[w]orkerd serve'], capture_output=True)
    try: os.remove(os.path.join(WORK, '.dev.vars'))
    except Exception: pass
    print(f'\n{passed} passed, {failed} failed  (screenshots: {TMP})')
    sys.exit(1 if failed else 0)
