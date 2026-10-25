"""認識精度・学習・断片のつなぎ・マイク停止検知のテスト（実ブラウザ、サーバー不要）。
OpenAI への通信はブラウザ内で横取りして、決まった書き起こしを返す。"""
import http.server, threading, functools, os, sys, json, math, struct, wave, tempfile
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8821
srv = http.server.HTTPServer(('127.0.0.1', PORT), functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()

passed = failed = 0
def check(name, cond, extra=''):
    global passed, failed
    if cond: passed += 1; print('  ✓', name)
    else: failed += 1; print('  ✗', name, extra)

# 偽マイク：1.5秒の音と2.5秒の無音を繰り返す
tmp = tempfile.mkdtemp()
wav = os.path.join(tmp, 'm.wav')
with wave.open(wav, 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    fr = bytearray()
    for i in range(16000 * 30):
        t = i / 16000; on = (t % 4.0) < 1.5
        fr += struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * t)) if on else int(30 * math.sin(i)))
    w.writeframes(bytes(fr))

HIST = """(() => { const now=Date.now(); state.sets=[];
  [80,80,82.5,80,77.5,80].forEach((w,i)=>state.sets.push({id:'h'+i,ts:now-86400000*(i+1),exercise:'ベンチプレス',weight:w,reps:10,transcript:'(manual)',raw:{}}));
  [20,22,20].forEach((w,i)=>state.sets.push({id:'d'+i,ts:now-86400000*(i+1),exercise:'ダンベルカール',weight:w,reps:12,transcript:'(manual)',raw:{}}));
  state.learn={}; state.lastExercise=null; state.lastWeightBy={}; saveState(); _stats=null; })()"""

errors = []
with sync_playwright() as p:
    b = p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
                                f'--use-file-for-fake-audio-capture={wav}'])
    ctx = b.new_context(viewport={'width': 390, 'height': 844}, permissions=['microphone'])
    pg = ctx.new_page()
    pg.on('pageerror', lambda e: errors.append((e.stack or str(e))[:300]))
    reply = {'text': 'ベンチプレス80キロ10回', 'model': None, 'prompt': None}
    def openai(route):
        body = route.request.post_data_buffer or b''
        s = body.decode('utf-8', 'ignore')
        import re
        m = re.search(r'name="model"\r\n\r\n([^\r]+)', s); reply['model'] = m and m.group(1)
        m = re.search(r'name="prompt"\r\n\r\n([^\r]+)', s); reply['prompt'] = m and m.group(1)
        route.fulfill(status=200, body=reply['text'], content_type='text/plain')
    pg.route('https://api.openai.com/**', openai)

    print('設定の移行')
    pg.goto(f'http://127.0.0.1:{PORT}/index.html'); pg.wait_for_timeout(400)
    pg.evaluate("localStorage.setItem('talkfit_onboarded_v1','1'); localStorage.setItem('talkfit_cfg_v6', JSON.stringify({apiKey:'sk-x', model:'whisper-1', cfgVer:13, volThrMode:'floor', micMode:'ptt'}))")
    pg.reload(); pg.wait_for_timeout(500)
    c = pg.evaluate("({model:cfg.model, ver:cfg.cfgVer, mic:cfg.micMode})")
    check('whisper-1 の既存端末を gpt-4o-transcribe に移行', c['model'] == 'gpt-4o-transcribe' and c['ver'] == 14, c)
    check('移行で他の設定（タップして話す）を消さない', c['mic'] == 'ptt', c)
    pg.evaluate("cfg.model='whisper-1'; saveCfg()"); pg.reload(); pg.wait_for_timeout(500)
    check('移行後に自分で選んだモデルは尊重', pg.evaluate("cfg.model") == 'whisper-1')
    pg.evaluate("cfg.model='gpt-4o-transcribe'; cfg.micMode='auto'; saveCfg()"); pg.reload(); pg.wait_for_timeout(500)

    print('語彙ヒント')
    pg.evaluate(HIST)
    pg.evaluate("state.lastExercise='インクラインベンチプレス'")
    pr = pg.evaluate("whisperPrompt()")
    check('例文の数字を入れない', not any(ch.isdigit() for ch in pr), pr)
    check('いまの種目を最後に置く', pr.rstrip('。').endswith('インクラインベンチプレス'), pr)
    check('ふだんの種目を含む', 'ベンチプレス' in pr and 'ダンベルカール' in pr, pr)
    check('短い（ヒントを薄めない）', len(pr) < 260, len(pr))

    print('重量の聞き間違い補正')
    f = lambda w, ex='ベンチプレス': pg.evaluate(f"plausibleWeight('{ex}', {w})")
    r = f(18); check('ベンチ「18キロ」→ 80（十八と八十）', r['fixed'] and r['w'] == 80, r)
    r = f(800); check('「800キロ」→ 80（桁）', r['fixed'] and r['w'] == 80, r)
    r = f(60); check('60キロ（減量セット）は直さない', not r['fixed'], r)
    r = f(20); check('20キロ（アップ）は直さない', not r['fixed'], r)
    r = f(100); check('100キロ（自己ベスト更新）は直さない', not r['fixed'], r)
    r = f(18, 'スクワット'); check('履歴の無い種目は直さない', not r['fixed'], r)

    print('修正から学習')
    pg.evaluate(HIST)
    before = pg.evaluate("localParse('弁当プレス85キロ8回')")
    check('（前提）初見の聞き間違いは種目が取れない', before is None or before.get('exercise') != 'ベンチプレス', before)
    pg.evaluate("""(() => { const row={id:'x1',ts:Date.now(),exercise:null,weight:80,reps:10,transcript:'弁当プレス80キロ10回',raw:{}};
        state.sets.push(row); const before={exercise:row.exercise,weight:row.weight,reps:row.reps};
        row.exercise='ベンチプレス'; window._learned = learnFromCorrection(row, before); })()""")
    check('覚えた内容を返す', len(pg.evaluate("_learned")) == 1, pg.evaluate("_learned"))
    after = pg.evaluate("localParse('弁当プレス 85キロ 8回')")
    check('次からは「弁当プレス」をベンチプレスと読む', after and after['exercise'] == 'ベンチプレス' and after['weight'] == 85, after)
    after2 = pg.evaluate("localParse('弁当プレース85キロ8回')")
    check('少し違う聞こえ方でも当てる', after2 and after2['exercise'] == 'ベンチプレス', after2)

    pg.evaluate("""(() => { const row={id:'x2',ts:Date.now(),exercise:'レッグプレス',weight:14,reps:10,transcript:'レッグプレス14キロ10回',raw:{}};
        const before={exercise:row.exercise,weight:row.weight,reps:row.reps}; row.weight=40; learnFromCorrection(row, before); })()""")
    check('重量の聞き間違いを覚える（14→40）', pg.evaluate("learnStore().numFix[14] && learnStore().numFix[14].to") == 40)

    pg.evaluate("""(() => { const row={id:'x3',ts:Date.now(),exercise:'ベンチプレス',weight:80,reps:10,transcript:'ベンチプレス18キロ10回',raw:{weight_fixed_from:18}};
        const before={exercise:row.exercise,weight:row.weight,reps:row.reps}; row.weight=18; learnFromCorrection(row, before); })()""")
    check('自動補正が外れていたら以後は直さない', not f(18)['fixed'])

    print('設定画面に学習内容を表示')
    pg.evaluate("openSettings()"); pg.wait_for_timeout(500)
    txt = pg.inner_text('#learnList')
    check('覚えた聞き間違いを一覧表示', '弁当' in txt and '14kg → 40kg' in txt, txt)
    n0 = pg.evaluate("Object.keys(learnStore().alias).length")
    pg.click('#learnList .learn-row button'); pg.wait_for_timeout(200)
    check('× で忘れられる', pg.evaluate("Object.keys(learnStore().alias).length") == n0 - 1)
    pg.evaluate("closeSheets()"); pg.wait_for_timeout(400)

    print('記録の流れ（書き起こし後）')
    pg.evaluate(HIST)
    n = lambda: pg.evaluate("todaySets().length")
    pg.evaluate("processTranscript('ベンチプレス18キロ10回', {})"); pg.wait_for_timeout(300)
    last = pg.evaluate("state.sets[state.sets.length-1]")
    check('聞き間違えた重量を履歴で補正して記録', last['weight'] == 80 and last['raw'].get('weight_fixed_from') == 18, last)
    check('補正したことを画面で知らせる', '補正' in pg.inner_text('#transcriptPill'), pg.inner_text('#transcriptPill'))

    pg.evaluate(HIST); c0 = n()
    pg.evaluate("processTranscript('ダンベルカール22キロ', {})"); pg.wait_for_timeout(200)
    check('回数の無い断片は記録せず待つ', n() == c0 and '待って' in pg.inner_text('#transcriptPill'), pg.inner_text('#transcriptPill'))
    pg.evaluate("processTranscript('12回', {})"); pg.wait_for_timeout(300)
    last = pg.evaluate("state.sets[state.sets.length-1]")
    check('次の区間とつなげて1セットに', n() == c0 + 1 and last['exercise'] == 'ダンベルカール' and last['weight'] == 22 and last['reps'] == 12, last)

    pg.evaluate(HIST); c0 = n()
    pg.evaluate("pendingPartial={text:'ベンチプレス80キロ', at:Date.now()-60000}")
    pg.evaluate("processTranscript('12回', {})"); pg.wait_for_timeout(300)
    last = pg.evaluate("state.sets[state.sets.length-1]")
    check('古い断片（7秒以上前）とはつながない', last['weight'] != 80 or last['exercise'] != 'ベンチプレス', last)

    print('実際の録音から記録まで（偽マイク）')
    pg.evaluate(HIST); pg.evaluate("switchTab('record'); lastAddSig=''; lastAddAt=0"); c0 = n()
    reply['text'] = 'ベンチプレス80キロ10回'
    pg.click('#micBtn')
    pg.wait_for_function(f"todaySets().length > {c0}", timeout=25000)
    check('gpt-4o-transcribe で認識', reply['model'] == 'gpt-4o-transcribe', reply['model'])
    check('送ったヒントに数字が無い', reply['prompt'] and not any(ch.isdigit() for ch in reply['prompt']), reply['prompt'])
    log = pg.evaluate("recLog.join('\\n')")
    check('速度の内訳を記録', '速度' in log and '区切り待ち' in log, log[-400:])
    import re
    m = re.search(r'速度 ([\d.]+)秒（区切り待ち([\d.]+)', log)
    check('話し終わりの待ちが1.2秒以内', m and float(m.group(2)) <= 1.2, m and m.group(0))

    print('マイクを止められた時の検知')
    pg.evaluate("mediaStream.getAudioTracks()[0].dispatchEvent(new Event('mute'))"); pg.wait_for_timeout(200)
    check('止められたら赤い案内を出す', pg.is_visible('#micBlocked'))
    check('診断ログに残す', 'マイクが止められた' in pg.evaluate("recLog.join('\\n')"))
    pg.evaluate("mediaStream.getAudioTracks()[0].dispatchEvent(new Event('unmute'))"); pg.wait_for_timeout(200)
    check('戻ったら案内を消す', not pg.is_visible('#micBlocked'))
    pg.evaluate("for(let i=0;i<40;i++){ micSilenceWatch(0); } silentSince=Date.now()-3000; micSilenceWatch(0)")
    check('完全な無音が続いたら止められたと判断', pg.is_visible('#micBlocked'))
    pg.evaluate("micSilenceWatch(0.02)")
    check('音が戻れば解除', not pg.is_visible('#micBlocked'))
    pg.click('#micBtn'); pg.wait_for_timeout(500)
    check('ページエラーなし', not errors, errors)
    b.close()

srv.shutdown()
print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
