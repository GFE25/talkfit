"""iPhoneアプリ版の JS 側のテスト。Capacitor とネイティブプラグインを偽物に差し替え、
書き起こしの受け取り・順番・重複・取りこぼし防止・エラー処理を確かめる。"""
import http.server, threading, functools, os, sys
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8831
srv = http.server.HTTPServer(('127.0.0.1', PORT), functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()

FAKE = """
window.__gum = 0;
const _gum = navigator.mediaDevices && navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
if (navigator.mediaDevices) navigator.mediaDevices.getUserMedia = (...a) => { window.__gum++; return _gum(...a); };
window.__native = { listeners:{}, started:null, stopped:0, acked:[], pending:[], cfg:[] };
const N = window.__native;
window.Capacitor = {
  isNativePlatform: () => true,
  Plugins: { TalkFitVoice: {
    addListener: async (ev, cb) => { (N.listeners[ev] = N.listeners[ev] || []).push(cb); return { remove(){} }; },
    start: async (o) => { N.started = o; },
    stop: async () => { N.stopped++; },
    pending: async () => ({ items: N.pending.slice() }),
    ack: async ({ids}) => { N.acked.push(...ids); N.pending = N.pending.filter(x => !ids.includes(x.id)); },
    updateConfig: async (o) => { N.cfg.push(o); },
    chime: async () => {},
  } },
};
window.__emit = (ev, data) => (N.listeners[ev] || []).forEach(cb => cb(data));
"""

passed = failed = 0
def check(name, cond, extra=''):
    global passed, failed
    if cond: passed += 1; print('  ✓', name)
    else: failed += 1; print('  ✗', name, extra)

errors = []
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 390, 'height': 844},
                        user_agent='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148')
    ctx.add_init_script(FAKE)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append((e.stack or str(e))[:300]))
    pg.goto(f'http://127.0.0.1:{PORT}/index.html'); pg.wait_for_timeout(300)
    pg.evaluate("localStorage.setItem('talkfit_onboarded_v1','1'); localStorage.setItem('talkfit_cfg_v6', JSON.stringify({apiKey:'sk-mine', cfgVer:14, volThrMode:'floor'}))")
    # 前回アプリが閉じる前に溜まっていた書き起こしがある状態で起動
    pg.evaluate("localStorage.setItem('talkfit_state_v3', JSON.stringify({sets:[], sessions:[], weights:[]}))")
    pg.add_init_script("window.__native && (window.__native.pending = [{id:'old1', text:'スクワット100キロ5回', ts: Date.now()-60000}])")
    pg.reload(); pg.wait_for_timeout(800)

    print('起動')
    check('アプリ版として認識', pg.evaluate("IS_NATIVE && !!NativeVoice"))
    check('ホーム画面追加の案内は出さない', not pg.is_visible('#installHint'))
    sets = pg.evaluate("state.sets.map(s=>[s.exercise,s.weight,s.reps])")
    check('閉じる前に溜まっていた書き起こしを起動時に記録', sets == [['スクワット', 100, 5]], sets)
    check('記録したものは待ち行列から消す', 'old1' in pg.evaluate("__native.acked"))

    print('録音開始')
    pg.click('#micBtn'); pg.wait_for_timeout(400)
    st = pg.evaluate("__native.started")
    check('ネイティブ録音を開始（Webのマイクは使わない）', st and pg.evaluate("__gum") == 0, st)
    check('自分のキーと認識モデル・語彙ヒントを渡す', st['mode'] == 'direct' and st['apiKey'] == 'sk-mine' and st['model'] == 'gpt-4o-transcribe' and st['prompt'].startswith('筋トレの記録'), st)
    check('録音中の表示', pg.evaluate("recState") == 'live')

    print('書き起こしの受け取り')
    pg.evaluate("__emit('state', {state:'recognizing'})")
    check('認識中を表示', '認識中' in pg.inner_text('#transcriptPill'))
    now = pg.evaluate("Date.now()")
    pg.evaluate(f"__native.pending.push({{id:'a1', text:'ベンチプレス80キロ10回', ts:{now-3000}, speechEndAt:{now-3000}, cutAt:{now-2200}, sendAt:{now-2200}, apiDoneAt:{now-1000}}}); __emit('transcript', __native.pending[__native.pending.length-1])")
    pg.wait_for_timeout(300)
    last = pg.evaluate("state.sets[state.sets.length-1]")
    check('書き起こしを記録', last['exercise'] == 'ベンチプレス' and last['weight'] == 80 and last['reps'] == 10, last)
    check('記録の時刻は発話した時刻', abs(last['ts'] - (now - 3000)) < 5, last['ts'] - now)
    check('速度の内訳を記録', '速度' in pg.evaluate("recLog.join('\\n')"))
    check('処理後に ack', 'a1' in pg.evaluate("__native.acked"))
    check('語彙ヒントを更新', len(pg.evaluate("__native.cfg")) >= 1)

    pg.evaluate("__emit('transcript', {id:'a1', text:'ベンチプレス80キロ10回', ts:Date.now()})"); pg.wait_for_timeout(200)
    check('同じ書き起こしが二度届いても1回だけ記録', pg.evaluate("todaySets().length") == 2)

    print('画面ロック中に溜まった分を、戻った時に順番どおり記録')
    pg.evaluate("""(() => { const t=Date.now(); __native.pending.push(
        {id:'b2', text:'同じで8回', ts:t-2000},
        {id:'b1', text:'インクラインベンチプレス60キロ12回', ts:t-5000}); })()""")
    pg.evaluate("Object.defineProperty(document,'visibilityState',{value:'visible',configurable:true}); document.dispatchEvent(new Event('visibilitychange'))")
    pg.wait_for_timeout(500)
    tail = pg.evaluate("state.sets.slice(-2).map(s=>[s.exercise,s.weight,s.reps])")
    check('時刻順に処理（「同じで8回」が前の種目を引き継ぐ）', tail == [['インクラインベンチプレス', 60, 12], ['インクラインベンチプレス', 60, 8]], tail)
    check('待ち行列が空になる', pg.evaluate("__native.pending.length") == 0)

    print('エラー')
    pg.evaluate("__emit('error', {status:401, message:'bad'})"); pg.wait_for_timeout(200)
    check('キー無効を知らせる', 'キーが無効' in pg.inner_text('#toast'), pg.inner_text('#toast'))
    pg.evaluate("__emit('state', {state:'interrupted'})")
    check('電話などの中断を表示', '中断中' in pg.inner_text('#transcriptPill'))

    print('停止')
    pg.click('#micBtn'); pg.wait_for_timeout(300)
    check('ネイティブ録音を止める', pg.evaluate("__native.stopped") == 1 and pg.evaluate("recState") == 'idle')
    check('ページエラーなし', not errors, errors)
    b.close()

srv.shutdown()
print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
