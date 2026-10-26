"""検証レポートのテスト。録音1回分（検証セッション）の数え方と、判定・コピー用の文章を確かめる。
Web版は関数を直接呼び、アプリ版は Capacitor とネイティブプラグインを偽物に差し替える。"""
import http.server, threading, functools, os, json
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8832
srv = http.server.HTTPServer(('127.0.0.1', PORT), functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()

passed = failed = 0
def check(name, cond, extra=''):
    global passed, failed
    if cond: passed += 1; print('  ✓', name)
    else: failed += 1; print('  ✗', name, extra)

BASE = "localStorage.setItem('talkfit_onboarded_v1','1'); localStorage.setItem('talkfit_cfg_v6', JSON.stringify({apiKey:'sk-test', cfgVer:14, volThrMode:'floor'})); localStorage.setItem('talkfit_state_v3', JSON.stringify({sets:[], sessions:[], weights:[]})); localStorage.removeItem('talkfit_verify');"

FAKE_NATIVE = """
window.__native = { listeners:{}, started:null, stopped:0, acked:[], pending:[], diag:null };
const N = window.__native;
window.Capacitor = {
  isNativePlatform: () => true,
  Plugins: { TalkFitVoice: {
    addListener: async (ev, cb) => { (N.listeners[ev] = N.listeners[ev] || []).push(cb); return { remove(){} }; },
    start: async (o) => { N.started = o; N.diag = { sid:o.sid, stats:{}, events:[] }; },
    stop: async () => { N.stopped++; },
    pending: async () => ({ items: N.pending.slice() }),
    ack: async ({ids}) => { N.acked.push(...ids); N.pending = N.pending.filter(x => !ids.includes(x.id)); },
    updateConfig: async () => {},
    chime: async () => {},
    diag: async () => N.diag || { sid:'', stats:{}, events:[] },
  } },
};
window.__emit = (ev, data) => (N.listeners[ev] || []).forEach(cb => cb(data));
"""

errors = []
with sync_playwright() as p:
    b = p.chromium.launch()

    # ───────── Web版 ─────────
    ctx = b.new_context(viewport={'width': 390, 'height': 844})
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append((e.stack or str(e))[:300]))
    pg.goto(f'http://127.0.0.1:{PORT}/index.html'); pg.wait_for_timeout(300)
    pg.evaluate(BASE); pg.reload(); pg.wait_for_timeout(600)

    print('Web版：1回の録音を数える')
    pg.evaluate("vsStart('web'); recState='live'")
    t0 = pg.evaluate("Date.now()")
    # 正しく取れた記録（速さ付き）
    pg.evaluate(f"processTranscript('ベンチプレス80キロ10回', {{speechEndAt:{t0}-1500, cutAt:{t0}-700, blobAt:{t0}-700, sendAt:{t0}-700, apiDoneAt:{t0}-200}})")
    pg.wait_for_timeout(150)
    pg.evaluate("lastAddSig=''; processTranscript('スクワット100キロ5回', {})"); pg.wait_for_timeout(150)
    pg.evaluate("lastAddSig=''; processTranscript('デッドリフト120キロ3回', {})"); pg.wait_for_timeout(150)
    # 記録できなかった発話
    pg.evaluate("processTranscript('12時に行く', {})"); pg.wait_for_timeout(150)
    rows = pg.evaluate("state.sets.map(r=>({id:r.id, src:r.src, sid:r.sid}))")
    sid = pg.evaluate("vs.id")
    check('声の記録に検証セッションの印を付ける', len(rows) == 3 and all(r['src'] == 'voice' and r['sid'] == sid for r in rows), rows)
    check('速さを記録', pg.evaluate("vs.lat.length") == 1)
    check('記録できなかった発話を残す', pg.evaluate("vs.unparsed") == ['12時に行く'], pg.evaluate("vs.unparsed"))

    # 手で直す（重量の聞き間違い）
    pg.evaluate("openSetSheet(state.sets[1])")
    pg.evaluate("document.getElementById('mW').value='90'"); pg.evaluate("document.getElementById('mSave').click()"); pg.wait_for_timeout(150)
    r1 = pg.evaluate("state.sets[1]")
    check('修正した記録は最初の内容を残す', r1['edited'] and r1['orig']['weight'] == 100 and r1['weight'] == 90, r1)
    # 何も変えずに保存しても修正に数えない
    pg.evaluate("openSetSheet(state.sets[0])"); pg.evaluate("document.getElementById('mSave').click()"); pg.wait_for_timeout(150)
    check('変更なしの保存は修正に数えない', not pg.evaluate("state.sets[0].edited"))
    # 削除
    pg.evaluate("openSetSheet(state.sets[2])"); pg.evaluate("document.getElementById('mDelete').click()"); pg.wait_for_timeout(150)
    # 録音中に手で追加＝声で取れなかった
    pg.evaluate("openSetSheet(null)")
    pg.evaluate("setPickedExercise('ラットプルダウン')")
    pg.evaluate("document.getElementById('mW').value='50'; document.getElementById('mR').value='12'"); pg.evaluate("document.getElementById('mSave').click()"); pg.wait_for_timeout(150)
    check('録音中の手入力を取りこぼしとして数える', pg.evaluate("vs.manual") == 1)

    # 音楽でマイクを止められた時間
    pg.evaluate("setMicBlocked(true,'track muted','track'); micBlockedSince=Date.now()-12000; setMicBlocked(false,'','track')")
    check('止められた回数と時間', pg.evaluate("vs.blockedN") == 1 and pg.evaluate("vs.blockedMs") >= 11000)
    # エラーを数える
    pg.evaluate("logEvent('API 500 server_error')")
    check('エラーを数える', pg.evaluate("vs.errors") == 1)

    m = pg.evaluate("vsSummary(vs)")
    check('記録3・修正1・削除1・取りこぼし1', (m['rec'], m['edited'], m['deleted'], m['misses']) == (3, 1, 1, 1), m)
    check('精度＝正しく取れた1 / 言った4', m['ok'] == 1 and m['said'] == 4 and abs(m['acc'] - 0.25) < 1e-9, m)

    print('雑談の数字を記録しない')
    r = pg.evaluate("[localParse('12時に行く'), localParse('今日は3月'), localParse('45度'), localParse('スクワット80 5'), localParse('10'), localParse('プランク1分30秒')]")
    check('「12時」「3月」「45度」はセットにしない', r[0] is None and r[1] is None and r[2] is None, r[:3])
    check('単位なしの「80 5」「10」は今まで通り', r[3]['weight'] == 80 and r[3]['reps'] == 5 and r[4]['reps'] == 10, r[3:5])
    check('「1分30秒」は秒数のまま', r[5]['seconds'] == 90, r[5])

    print('学習の効果を数える')
    pg.evaluate("learnStore().alias[nameKeyOf('ペンチ')] = {ex:'ベンチプレス', n:1, at:Date.now()}")
    pg.evaluate("lastAddSig=''; processTranscript('ペンチ80キロ8回', {})"); pg.wait_for_timeout(150)
    last = pg.evaluate("state.sets[state.sets.length-1]")
    check('覚えた言い方で当てた記録に印', last['exercise'] == 'ベンチプレス' and last['raw'].get('learned_alias'), last)
    check('学習で直した件数', pg.evaluate("vs.learned") == 1)

    print('終了と再開')
    pg.evaluate("stopCapture()")
    s_end = pg.evaluate("vsAll()[vsAll().length-1]")
    check('止めるとセッションを締める', s_end['end'] and pg.evaluate("vs") is None)
    pg.evaluate("vsStart('web')")
    check('5分以内の再開は同じセッションの続き', pg.evaluate("vs.id") == sid and pg.evaluate("vs.resumes") == 1)
    pg.evaluate("vsEnd()")

    print('レポート')
    txt = pg.evaluate("vsText(5)")
    check('判定を出す', '精度' in txt and '学習' in txt and '速さ' in txt and '音楽・連続' in txt, txt[:300])
    check('記録の中身と最初の内容', '「スクワット100キロ5回」' in txt and '最初は スクワット 100kg×5回' in txt, txt)
    check('記録できなかった発話を載せる', '「12時に行く」' in txt)
    check('覚えた言い方の印', '[覚えた言い方]' in txt)
    pg.evaluate("openSettings()"); pg.wait_for_timeout(200)
    check('設定画面に一覧を表示', pg.locator('#verifyList .vs-card').count() == 1 and '精度' in pg.inner_text('#verifyList'))
    check('コピーボタンがある', pg.is_visible('#copyVerify'))

    print('アプリが途中で閉じた時')
    pg.evaluate("vsStart('web'); vs.start=Date.now()-3600000; vs.ids=['x']; vsSave(); vs=null")
    pg.reload(); pg.wait_for_timeout(600)
    last = pg.evaluate("vsAll()[vsAll().length-1]")
    check('次の起動で締めて印を付ける', last['end'] and last['abrupt'], last)
    check('レポートに途中終了と出る', '途中でアプリが閉じた' in pg.evaluate("vsText(1)"))
    ctx.close()

    # ───────── アプリ版 ─────────
    print('アプリ版')
    ctx = b.new_context(viewport={'width': 390, 'height': 844})
    ctx.add_init_script(FAKE_NATIVE)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append((e.stack or str(e))[:300]))
    pg.goto(f'http://127.0.0.1:{PORT}/index.html'); pg.wait_for_timeout(300)
    pg.evaluate(BASE); pg.reload(); pg.wait_for_timeout(600)
    pg.click('#micBtn'); pg.wait_for_timeout(300)
    st = pg.evaluate("__native.started")
    check('検証セッションのIDを録音側に渡す', st and st['sid'] and st['sid'] == pg.evaluate("vs.id"), st)
    now = pg.evaluate("Date.now()")
    pg.evaluate(f"__emit('transcript', {{id:'b1', text:'ベンチプレス80キロ10回', ts:{now-4000}, speechEndAt:{now-4000}, cutAt:{now-3200}, sendAt:{now-3200}, apiDoneAt:{now-2500}, bg:1}})")
    pg.wait_for_timeout(200)
    pg.evaluate(f"__emit('transcript', {{id:'b2', text:'スクワット100キロ5回', ts:{now-600000}, speechEndAt:{now-600000}, cutAt:{now-599000}, sendAt:{now-1000}, apiDoneAt:{now-500}, bg:1, late:1}})")
    pg.wait_for_timeout(200)
    check('画面ロック中の記録を数える', pg.evaluate("vs.bg") == 2)
    check('通信が戻ってから記録した分を数える', pg.evaluate("vs.late") == 1)
    check('あとで送った分は速さに含めない', pg.evaluate("vs.lat.length") == 1)
    # 録音側の記録（中断と再開）を返すようにして止める
    pg.evaluate(f"__native.diag = {{ sid: vs.id, stats: {{ interrupts:1, downMs:8000, queued:1, restarts:1 }}, events: [{{t:{now}-5000, k:'interrupt', m:'', bg:1}}, {{t:{now}-1000, k:'resume', m:'8秒止まっていた', bg:1}}], retryWaiting:0 }}")
    pg.evaluate("stopCapture()"); pg.wait_for_timeout(600)
    s = pg.evaluate("vsAll()[vsAll().length-1]")
    check('止めた時に録音側の記録を取り込む', s.get('native') and s['native']['stats'].get('interrupts') == 1, s.get('native'))
    txt = pg.evaluate("vsText(1)")
    check('画面ロック中の判定', '○ 画面ロック中：2件記録' in txt, txt)
    check('止まっていた時間に録音側の分を含む', '止まっていた 8秒（1回）' in txt, txt)
    check('録音側の出来事を載せる', '中断（画面ロック中）' in txt and '再開（画面ロック中） 8秒止まっていた' in txt, txt)
    check('通信の内訳', '端末に保存1件・あとで記録1件' in txt, txt)
    ctx.close()
    b.close()

check('ページエラーなし', not errors, errors)
print(f'\n{passed} passed, {failed} failed')
srv.shutdown()
raise SystemExit(1 if failed else 0)
