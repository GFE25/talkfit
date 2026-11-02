"""終了ボタンと結果画面、学習（待ち時間・休憩・言い方・よくやる種目）、種目の誤切り替えの防止のテスト。"""
import http.server, threading, functools, os, json, time
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8833
srv = http.server.HTTPServer(('127.0.0.1', PORT), functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()

passed = failed = 0
def check(name, cond, extra=''):
    global passed, failed
    if cond: passed += 1; print('  ✓', name)
    else: failed += 1; print('  ✗', name, extra)

now = int(time.time() * 1000)
def S(i, ex, w, r, mins_ago, **kw):
    d = {"id": f"t{i}", "ts": now - int(mins_ago * 60000), "exercise": ex, "weight": w, "reps": r, "seconds": None,
         "transcript": kw.pop('tr', f"{ex}{w}キロ{r}回"), "raw": {}}
    d.update(kw); return d
def seed(pg, sets, sessions=None, learn=None, extra=None):
    st = {"sets": sets, "sessions": sessions or [], "weights": [{"ts": now - 86400000, "value": 72}],
          "sessionStart": now - 50 * 60000, "lastExercise": None, "lastWeightBy": {}}
    if learn: st["learn"] = learn
    if extra: st.update(extra)
    pg.evaluate("""(st)=>{localStorage.setItem('talkfit_onboarded_v1','1');
      localStorage.setItem('talkfit_cfg_v6', JSON.stringify({apiKey:'sk-x',cfgVer:14}));
      localStorage.setItem('talkfit_state_v3', JSON.stringify(st)); localStorage.removeItem('talkfit_verify');}""", st)
    pg.reload(); pg.wait_for_timeout(500)

errors = []
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 390, 'height': 844})
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append((e.stack or str(e))[:300]))
    pg.goto(f'http://127.0.0.1:{PORT}/index.html'); pg.wait_for_timeout(300)

    # ───────── 結果画面 ─────────
    print('終了ボタンと結果画面')
    seed(pg, [])
    check('記録が無い時は終了ボタンを出さない', not pg.is_visible('#finishBtn'))
    today = [S(1,'ベンチプレス',60,10,48), S(2,'ベンチプレス',80,8,45), S(3,'ベンチプレス',90,6,42), S(4,'ベンチプレス',90,5,39),
             S(5,'ラットプルダウン',50,12,24), S(6,'ラットプルダウン',55,10,21), S(7,'スクワット',100,8,10), S(8,'スクワット',110,6,6)]
    past = [S(100+i,'ベンチプレス',80,8,60*24*(3+i)+10) for i in range(5)]
    seed(pg, past + today, sessions=[{"id":"s1","ts":now-86400000*3,"vol":9000,"name":"a"},{"id":"s2","ts":now-86400000*7,"vol":9500,"name":"b"}])
    check('記録があれば終了ボタンを出す', pg.is_visible('#finishBtn'))
    vol = sum(s['weight']*s['reps'] for s in today)
    pg.click('#finishBtn'); pg.wait_for_timeout(2200)
    check('結果画面が開く', pg.is_visible('#finish'))
    check('総挙上量がカウントアップして合計に一致', pg.inner_text('#finVol').replace(',', '') == str(vol), pg.inner_text('#finVol'))
    check('自己ベストの見出し（推定1RMが過去最高を超えた）', '自己ベスト' in pg.inner_text('.fin-head'), pg.inner_text('.fin-head'))
    check('セッションを履歴に保存し、録音を止める', pg.evaluate("state.sessions.length") == 3 and pg.evaluate("recState") == 'idle')
    ids = pg.evaluate("[...document.querySelectorAll('#finCards .fin-card')].map(c=>c.dataset.id)")
    check('カードが出る（仕事量・推定1RM・主役・休憩・通算）', all(i in ids for i in ['work','e1rm','focus','rest','total']), ids)

    # 数値の検証（手計算と一致）
    R = pg.evaluate("buildReport()")
    exp_j = sum(s['weight'] * 9.80665 * {'ベンチプレス':0.45,'ラットプルダウン':0.5,'スクワット':0.55}[s['exercise']] * s['reps'] for s in today)
    check('仕事量 W=m·g·h', abs(R['workJ'] - exp_j) < 1, (R['workJ'], exp_j))
    check('推定1RM（Epley）', abs(R['e1']['ベンチプレス']['v'] - 90*(1+6/30)) < 1e-6, R['e1']['ベンチプレス'])
    check('過去の最高との差を持つ', abs(R['e1']['ベンチプレス']['prev'] - 80*(1+8/30)) < 1e-6)

    # 好みの学習
    pg.evaluate("document.querySelector('#finCards .fin-card[data-id=work] button[data-a=like]').click()"); pg.wait_for_timeout(200)
    check('♡で上に出る', pg.evaluate("document.querySelector('#finCards .fin-card').dataset.id") == 'work' and pg.evaluate("learnStore().insight.like.work") == 1)
    pg.evaluate("document.querySelector('#finCards .fin-card[data-id=rest] button[data-a=hide]').click()"); pg.wait_for_timeout(200)
    check('✕で出さない', pg.evaluate("document.querySelector('#finCards .fin-card[data-id=rest]')") is None and pg.evaluate("learnStore().insight.hide.rest") is True)
    pg.evaluate("document.getElementById('finClose').click()"); pg.wait_for_timeout(600)
    pg.evaluate("openSettings()"); pg.wait_for_timeout(300)
    check('設定で非表示のカードを戻せる', pg.evaluate("!document.querySelector('#insightPrefs input[data-id=rest]').checked"))
    pg.evaluate("(()=>{const i=document.querySelector('#insightPrefs input[data-id=rest]'); i.checked=true; i.onchange()})()")
    check('戻すと出る', pg.evaluate("!learnStore().insight.hide.rest"))

    # 例え
    print('例え')
    r = pg.evaluate("[pickCompare(6820,'animal'), pickCompare(50,'science'), pickCompare(9e8,'landmark'), pickCompare(4,'vehicle')]")
    check('一番近い下側の物を選ぶ（6,820kg → アフリカゾウ）', r[0]['name'] == 'アフリカゾウ' and abs(r[0]['ratio'] - 1.364) < 0.01, r[0])
    check('次の目標までの残り', r[0]['next']['name'].startswith('ティラノサウルス') and r[0]['next']['need'] == 1180, r[0]['next'])
    check('小さい重さは最小の物、巨大は最大の物', r[1]['name'] == '牛乳1Lパック' and r[2]['name'].startswith('東京スカイツリー') and r[2]['next'] is None, (r[1], r[2]))
    pg.evaluate("cfg.compareTheme='vehicle'; saveCfg()")
    check('設定のジャンルが効く', pg.evaluate("buildReport().cmp.theme") == 'vehicle')

    # シェア画像
    n = pg.evaluate("""async()=>{const R=buildReport(); const b=await buildFinishImage(R); return b.size}""")
    check('シェア画像を作れる', n > 20000, n)

    # ───────── 休憩 ─────────
    print('休憩（インターバル）')
    gaps = [S(200+i, 'ベンチプレス', 80, 8, 60*24*2 + 10 - i*1.5) for i in range(8)]     # 90秒間隔
    seed(pg, gaps)
    rs = pg.evaluate("(()=>{const r=restStats(); return {n:r.all.length, med:r.med, ex:usualRest('ベンチプレス')}})()")
    check('90秒間隔を学習', rs['n'] == 7 and abs(rs['med'] - 90) < 1 and abs(rs['ex'] - 90) < 1, rs)
    seed(pg, gaps + [S(300, 'ベンチプレス', 80, 8, 0.5)])
    pg.evaluate("state.lastExercise='ベンチプレス'; updateRestBar()")
    txt = pg.inner_text('#restBar')
    check('いまの休憩とふだんの休憩を並べて出す', '休憩' in txt and 'いつもは 1:30' in txt, txt)

    # ───────── 待ち時間（その人の間） ─────────
    print('話し終わりの待ち時間')
    seed(pg, [])
    check('初期値は0.65秒', pg.evaluate("paceTail()") == 650)
    pg.evaluate("paceUpdate(true)")
    check('途中で切れたら100ms延ばす', pg.evaluate("paceTail()") == 750)
    pg.evaluate("for(let i=0;i<12;i++) paceUpdate(false)")
    check('12回安定したら50ms縮める', pg.evaluate("paceTail()") == 700)
    pg.evaluate("for(let i=0;i<30;i++) paceUpdate(true)")
    check('上限は1秒', pg.evaluate("paceTail()") == 1000)
    pg.evaluate("learnStore().pace.tail=500; for(let i=0;i<24;i++) paceUpdate(false)")
    check('下限は0.5秒', pg.evaluate("paceTail()") == 500)
    check('アプリ版にも同じ値を渡す', pg.evaluate("nativeConfig().tailMs") == 500)
    pg.evaluate("learnStore().pace.tail=650; pendingPartial=null")
    pg.evaluate("processTranscript('ベンチ80キロ', {})"); pg.wait_for_timeout(100)
    pg.evaluate("processTranscript('10回', {})"); pg.wait_for_timeout(200)
    check('割れた発話をつなげたら待ち時間を延ばす', pg.evaluate("paceTail()") == 750, pg.evaluate("paceTail()"))

    # ───────── 言い方・よくやる種目 ─────────
    print('言い方とよくやる種目')
    own = [S(400+i, 'ペックデックフライ', 60, 8, 60*24*(2+i), tr='パックン60キロ8回') for i in range(3)]
    seed(pg, own)
    check('同じ言い方が同じ種目に落ち着けば自動で覚える', pg.evaluate("heardProfile().map(h=>h.ex)") == ['ペックデックフライ'], pg.evaluate("heardProfile()"))
    check('次からその言い方で当てる', pg.evaluate("localParse('パックン50キロ10回').exercise") == 'ペックデックフライ')
    check('設定に自動の印つきで出る', 'パックン' in pg.evaluate("(openSettings(), document.getElementById('learnList').innerText)"))
    seed(pg, [S(500, 'ペックデックフライ', 60, 8, 60*24*2, edited=True, tr='パックン60キロ8回'), S(501, 'ペックデックフライ', 60, 8, 60*24*3, edited=True, tr='パックン60キロ8回')])
    check('修正された記録からは自動で覚えない', pg.evaluate("heardProfile().length") == 0)

    seed(pg, [])
    base = pg.evaluate("localParse('フライ60キロ8回').exercise")
    seed(pg, [S(600+i, 'ペックデックフライ', 60, 8, 60*24*(2+i)) for i in range(8)])
    after = pg.evaluate("localParse('フライ60キロ8回').exercise")
    check('「フライ」が曖昧な時は、ふだんよくやる種目を選ぶ', after == 'ペックデックフライ', (base, after))
    seed(pg, [S(700+i, 'ダンベルフライ', 20, 10, 60*24*(2+i)) for i in range(8)])
    check('やっている種目が違う人は、その種目になる', pg.evaluate("localParse('フライ20キロ10回').exercise") == 'ダンベルフライ')
    seed(pg, [S(800+i, 'ラットプルダウン', 50, 10, 60*24*(2+i)) for i in range(5)] + [S(810+i, 'スクワット', 80, 10, 60*24*(2+i)) for i in range(2)])
    pg.evaluate("openPicker(()=>{})"); pg.wait_for_timeout(200)
    check('ピッカーの先頭によくやる種目', 'よくやる種目' in pg.inner_text('#pkList') and pg.inner_text('#pkList').index('ラットプルダウン') < pg.inner_text('#pkList').index('胸'))

    # ───────── 種目の誤切り替え ─────────
    print('種目の誤切り替えの防止')
    seed(pg, [S(900, 'ベンチプレス', 60, 8, 5)], extra={"lastExercise": "ベンチプレス"})
    pg.evaluate("vsStart('web'); recState='live'")
    pg.evaluate("processTranscript('ラットプルダウン', {voicedMs:120})"); pg.wait_for_timeout(150)
    check('声が短い種目名だけの発話では切り替えない', pg.evaluate("state.lastExercise") == 'ベンチプレス' and pg.evaluate("vs.switchIgnored") == 1)
    pg.evaluate("processTranscript('ラットプルダウン', {voicedMs:900})"); pg.wait_for_timeout(150)
    check('声が十分なら切り替える', pg.evaluate("state.lastExercise") == 'ラットプルダウン')
    pg.evaluate("processTranscript('スクワット', {})"); pg.wait_for_timeout(150)
    check('声の長さが不明な経路（タップして話す等）でも切り替わる', pg.evaluate("state.lastExercise") == 'スクワット')
    check('切り替えを理由つきで残す', pg.evaluate("vs.switches.length") == 2)
    # 記録の原因調査用
    pg.evaluate("vsDrop('声が小さく無音扱い', '山9.1/基準12'); processTranscript('えーと今日はいい天気', {})"); pg.wait_for_timeout(150)
    txt = pg.evaluate("vsText(1)")
    check('レポートに捨てた区間の理由', '声が小さく無音扱い1回' in txt, txt)
    check('レポートに記録に至らなかった発話と理由', '「ラットプルダウン」→ 声が短く切り替えず' in txt and '数字なし（雑談扱い）' in txt, txt)
    check('レポートに種目の切り替え', '種目の切り替え：' in txt)
    ctx.close(); b.close()

check('ページエラーなし', not errors, errors)
print(f'\n{passed} passed, {failed} failed')
srv.shutdown()
raise SystemExit(1 if failed else 0)
