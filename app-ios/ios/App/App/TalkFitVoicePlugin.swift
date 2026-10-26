import Foundation
import AVFoundation
import UIKit
import Capacitor
import UserNotifications

/// 声の録音・区切り・書き起こしをネイティブで行うプラグイン。
///
/// なぜネイティブか：iPhone の Web アプリでは、録音中に Spotify などが音楽を流すと
/// iOS にマイクを止められる。ここでは音声セッションを「他のアプリと共存（mixWithOthers）」
/// に設定するため、音楽を流したまま録音でき、画面ロック中（ポケットの中）も動き続ける。
///
/// 流れ：マイク → 16kHz に変換 → 音量で発話区間を切り出す → WAV にして書き起こし API へ
///       → 結果を端末内の待ち行列に保存し JS に通知（JS が止まっていても失われない）
///
/// 2時間の連続録音のための備え：
/// - 見張り（2秒ごと）：音が5秒届かなければ録り直す。中断から戻れなければ10秒ごとに再開を試す
/// - 止まったまま30秒たったら通知で知らせる（ポケットの中でも気づける）
/// - 通信できなかった発話は端末に保存し、通信が戻ったら送る（地下のジムでも取りこぼさない）
/// - 中断・再開・失敗は端末に記録し、検証レポートに出す（画面ロック中は JS が止まっているため）
@objc(TalkFitVoicePlugin)
public class TalkFitVoicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TalkFitVoicePlugin"
    public let jsName = "TalkFitVoice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pending", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateConfig", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "chime", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "diag", returnType: CAPPluginReturnPromise),
    ]

    // ── 録音 ──
    // 音声システムがリセットされると古いエンジンは使えなくなるので、作り直せるよう var にする
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var chimeBuffer: AVAudioPCMBuffer?
    private var errorBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: 1, interleaved: false)!
    private let work = DispatchQueue(label: "talkfit.voice.work")
    private let store = DispatchQueue(label: "talkfit.voice.store")
    private var running = false      // エンジンが動いているか
    private var wanted = false       // 利用者が録音を求めているか（中断からの自動再開に使う）
    private var observers: [NSObjectProtocol] = []
    private var appActive = true

    // ── 設定（JS から渡される）──
    private var mode = "direct"      // "direct" = 自分の OpenAI キー / "server" = TalkFit サーバー経由
    private var apiKey = ""
    private var apiBase = ""
    private var deviceId = ""
    private var model = "gpt-4o-transcribe"
    private var language = "ja"
    private var prompt = ""
    private var tailMs = 800.0       // 話し終わってからこれだけ静かなら区切る
    private var marginDb: Float = 12 // 周囲の騒音よりこれだけ大きい音を声とみなす

    // ── 発話区間の検出（work キューだけで触る）──
    private let frameLen = 320       // 20ms @16kHz
    private let prerollMax = 4800    // 発話の頭 0.3 秒を取りこぼさない
    private var carry: [Float] = []
    private var dbHist: [Float] = []
    private var floorDb: Float = -60
    private var frameCount = 0
    private var preroll: [Float] = []
    private var seg: [Float] = []
    private var inSeg = false
    private var voicedRun = 0
    private var voicedFrames = 0
    private var lastVoiceFrame = 0
    private var segStartFrame = 0
    private var lastLevelAt = Date.distantPast
    private var lastBufferAt = Date()   // 最後にマイクの音が届いた時刻（work キュー）

    private let pendingKey = "talkfit.pending"

    // ── 見張り・止まっていた時間（メインスレッドだけで触る）──
    private var watchdog: DispatchSourceTimer?
    private var downSince: Date?
    private var lastRestartTry = Date.distantPast
    private var lastFlushTry = Date.distantPast
    private var flushing = false
    private var lastFailMsg = ""
    private var lastFailAt = Date.distantPast
    private let stoppedNoticeId = "talkfit.stopped"

    // ── 検証用の記録（store キューだけで触る）──
    private let diagKey = "talkfit.diag"
    private var sid = ""
    private var stats: [String: Double] = [:]
    private var events: [[String: Any]] = []

    private static let retryDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("talkfit-retry", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var diagLoaded = false

    /// 前回の記録を読み込む（アプリが途中で終了していても、検証レポートに残すため）。store キューで呼ぶ
    private func loadDiagIfNeeded() {
        guard !diagLoaded else { return }
        diagLoaded = true
        if let d = UserDefaults.standard.dictionary(forKey: diagKey) {
            sid = (d["sid"] as? String) ?? ""
            stats = (d["stats"] as? [String: Double]) ?? [:]
            events = (d["events"] as? [[String: Any]]) ?? []
        }
    }

    // MARK: - JS から呼ばれるメソッド

    @objc func start(_ call: CAPPluginCall) {
        applyConfig(call)
        let newSid = call.getString("sid") ?? ""
        store.sync {
            self.loadDiagIfNeeded()
            // 同じ検証セッションの続き（マイクの取り直し等）なら記録を引き継ぐ
            if newSid.isEmpty || newSid != self.sid {
                self.sid = newSid
                self.stats = ["startedAt": self.ms(Date())]
                self.events = []
            }
            self.persistDiag()
        }
        requestMic { granted in
            guard granted else {
                call.reject("マイクの使用が許可されていません。設定アプリ → TalkFit → マイク をオンにしてください", "denied")
                return
            }
            DispatchQueue.main.async {
                do {
                    self.wanted = true
                    self.observe()
                    try self.startEngine()
                    self.startWatchdog()
                    self.note("start", "")
                    // 録音が止まった時に知らせるための許可（初回だけ確認が出る）
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    call.resolve(["running": true])
                } catch {
                    self.wanted = false
                    call.reject("録音を開始できません: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.wanted = false
            self.markUp(silent: true)
            self.stopWatchdog()
            self.teardownEngine()
            self.unobserve()
            self.setStat("lastAudioAt", self.ms(self.work.sync { self.lastBufferAt }))
            self.note("stop", "")
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self.emit("state", ["state": "stopped"])
            call.resolve()
        }
    }

    @objc func pending(_ call: CAPPluginCall) {
        let items = store.sync { self.loadPending() }
        call.resolve(["items": items])
    }

    @objc func ack(_ call: CAPPluginCall) {
        let ids = Set((call.getArray("ids") ?? []).compactMap { $0 as? String })
        store.sync {
            self.savePending(self.loadPending().filter { !ids.contains(($0["id"] as? String) ?? "") })
        }
        call.resolve()
    }

    @objc func updateConfig(_ call: CAPPluginCall) {
        applyConfig(call)
        call.resolve()
    }

    @objc func chime(_ call: CAPPluginCall) {
        playChime()
        call.resolve()
    }

    @objc func diag(_ call: CAPPluginCall) {
        var out: [String: Any] = store.sync { () -> [String: Any] in
            self.loadDiagIfNeeded()
            return ["sid": self.sid, "stats": self.stats, "events": self.events]
        }
        out["retryWaiting"] = retryFiles().count
        call.resolve(out)
    }

    private func applyConfig(_ call: CAPPluginCall) {
        if let v = call.getString("mode") { mode = v }
        if let v = call.getString("apiKey") { apiKey = v }
        if let v = call.getString("apiBase") { apiBase = v.hasSuffix("/") ? String(v.dropLast()) : v }
        if let v = call.getString("device") { deviceId = v }
        if let v = call.getString("model"), !v.isEmpty { model = v }
        if let v = call.getString("language") { language = v }
        if let v = call.getString("prompt") { prompt = v }
        if let v = call.getDouble("tailMs") { tailMs = max(400, min(3000, v)) }
        if let v = call.getDouble("marginDb") { marginDb = Float(max(4, min(30, v))) }
    }

    private func requestMic(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { done($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
        }
    }

    // MARK: - エンジン

    private func startEngine() throws {
        if running { return }
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：Spotify 等を止めず、止められもしない（この設定が今回の肝）
        // allowBluetoothA2DP：AirPods の音質を落とさない（入力は iPhone 本体のマイク）
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "TalkFit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "マイクが見つかりません"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        // 記録できた合図の音。音楽と重ねて鳴らす
        if player.engine == nil { engine.attach(player) }
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        if chimeBuffer == nil { chimeBuffer = makeChime(format: outFormat) }
        if errorBuffer == nil { errorBuffer = makeErrorTone(format: outFormat) }

        engine.prepare()
        try engine.start()
        running = true
        work.async { self.resetVad(); self.lastBufferAt = Date() }
        markUp(silent: false)
        emit("state", ["state": "listening"])
    }

    private func teardownEngine() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    private func restart(_ reason: String) {
        guard wanted else { return }
        lastRestartTry = Date()
        teardownEngine()
        do {
            try startEngine()
            bump("restarts")
        } catch {
            markDown(since: Date())
            let msg = "\(reason): \(error.localizedDescription)"
            // 同じ失敗を10秒ごとに記録し続けないよう、1分に1回にまとめる
            if msg != lastFailMsg || Date().timeIntervalSince(lastFailAt) > 60 {
                lastFailMsg = msg; lastFailAt = Date()
                note("restart_fail", msg, count: "restartFails")
                emit("error", ["status": 0, "message": "録音を再開できません（\(reason)）: \(error.localizedDescription)"])
            }
        }
    }

    // MARK: - 見張り（メインスレッド）

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func tick() {
        guard wanted else { return }
        let now = Date()
        if running {
            let last = work.sync { self.lastBufferAt }
            setStat("lastAudioAt", ms(last))
            if now.timeIntervalSince(last) > 5 {
                // 録音中のはずなのに音が届かない（他のアプリにマイクを取られた等）
                note("stall", "\(Int(now.timeIntervalSince(last)))秒", count: "stalls")
                markDown(since: last)
                restart("音が届かない")
            }
        } else if now.timeIntervalSince(lastRestartTry) >= 10 {
            restart("再開の再試行")
        }
        if now.timeIntervalSince(lastFlushTry) >= 30 {
            lastFlushTry = now
            flushRetry()
        }
    }

    /// 録音が止まった。30秒たっても戻らなければ通知が出るよう予約しておく
    /// （止まっている間はアプリ自体が眠らされることがあるので、先に予約する）
    private func markDown(since: Date) {
        guard downSince == nil else { return }
        downSince = since
        let c = UNMutableNotificationContent()
        c.title = "TalkFit の録音が止まっています"
        c.body = "アプリを開くと再開します"
        c.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: stoppedNoticeId, content: c, trigger: trigger))
    }

    /// 録音が戻った。止まっていた時間を記録し、予約した通知を取り消す
    private func markUp(silent: Bool) {
        guard let d = downSince else { return }
        downSince = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [stoppedNoticeId])
        center.removeDeliveredNotifications(withIdentifiers: [stoppedNoticeId])
        let downMs = max(0, Date().timeIntervalSince(d) * 1000)
        bump("downMs", downMs)
        store.async {
            self.stats["maxDownMs"] = max(self.stats["maxDownMs"] ?? 0, downMs)
            self.persistDiag()
        }
        if !silent { note("resume", "\(Int(downMs / 1000))秒止まっていた") }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] n in
            self?.onInterruption(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] n in
            self?.onRouteChange(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.running = false
            self.note("reset", "", count: "resets")
            self.markDown(since: Date())
            self.engine = AVAudioEngine()
            self.player = AVAudioPlayerNode()
            self.restart("media services reset")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.appActive = true
            // 画面ロック中に戻れなかった録音は、開いた瞬間に再開する
            if self.wanted && !self.running { self.restart("アプリを開いた") }
            self.flushRetry()
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false
        })
    }

    private func unobserve() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func onInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            // 電話・アラーム・Siri など。終わったら自動で再開する
            running = false
            markDown(since: Date())
            note("interrupt", "", count: "interrupts")
            emit("state", ["state": "interrupted"])
        } else {
            restart("interruption ended")
        }
    }

    private func onRouteChange(_ n: Notification) {
        guard running,
              let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // イヤホンの抜き差しで入力の形式が変わると、タップが無音になることがある。
        // categoryChange は自分の setCategory でも起きるので対象外（再起動が止まらなくなる）
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
            note("route", reason == .newDeviceAvailable ? "つながった" : "外れた")
            restart("route change")
        }
    }

    // MARK: - 音声処理（オーディオスレッド → work キュー）

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        work.async { self.process(samples) }
    }

    private func resetVad() {
        carry = []; dbHist = []; floorDb = -60; frameCount = 0
        preroll = []; seg = []; inSeg = false; voicedRun = 0; voicedFrames = 0
        lastVoiceFrame = 0; segStartFrame = 0
    }

    private func process(_ samples: [Float]) {
        lastBufferAt = Date()
        carry.append(contentsOf: samples)
        var i = 0
        while carry.count - i >= frameLen {
            processFrame(Array(carry[i..<(i + frameLen)]))
            i += frameLen
        }
        if i > 0 { carry.removeFirst(i) }
    }

    private func processFrame(_ f: [Float]) {
        frameCount += 1
        var sum: Float = 0
        for s in f { sum += s * s }
        let db = 20 * log10(max(sqrt(sum / Float(f.count)), 1e-7))

        // 騒音レベル＝直近4秒の下位15%。発話で上振れしても下位側は環境音のまま動かない
        dbHist.append(db)
        if dbHist.count > 200 { dbHist.removeFirst(dbHist.count - 200) }
        if frameCount % 10 == 0 && dbHist.count >= 20 {
            let sorted = dbHist.sorted()
            floorDb = sorted[Int(Float(sorted.count) * 0.15)]
        }
        let speaking = db > floorDb + marginDb && db > -55
        emitLevel(db)

        if !inSeg {
            preroll.append(contentsOf: f)
            if preroll.count > prerollMax { preroll.removeFirst(preroll.count - prerollMax) }
            voicedRun = speaking ? voicedRun + 1 : 0
            if voicedRun >= 3 {                       // 60ms 続いたら発話の始まり
                inSeg = true
                seg = preroll
                preroll = []
                voicedFrames = voicedRun
                lastVoiceFrame = frameCount
                segStartFrame = frameCount
                emit("state", ["state": "hearing"])
            }
            return
        }

        seg.append(contentsOf: f)
        if speaking {
            voicedFrames += 1
            lastVoiceFrame = frameCount
        }
        let silentMs = Double(frameCount - lastVoiceFrame) * 20
        let segMs = Double(frameCount - segStartFrame) * 20
        if silentMs >= tailMs || segMs >= 12000 {
            finishSegment(silentMs: silentMs)
        }
    }

    private func finishSegment(silentMs: Double) {
        inSeg = false
        voicedRun = 0
        // 末尾の無音は 0.2 秒だけ残して捨てる（送る量が減り、認識が速くなる）
        let trimFrames = max(0, Int((silentMs - 200) / 20))
        let keep = max(0, seg.count - trimFrames * frameLen)
        let audio = Array(seg.prefix(keep))
        seg = []
        let voicedSec = Double(voicedFrames) * 0.02
        voicedFrames = 0
        guard voicedSec >= 0.25 else {             // 物音
            emit("state", ["state": "listening"])
            return
        }
        let now = Date()
        let meta: [String: Double] = [
            "speechEndAt": ms(now.addingTimeInterval(-silentMs / 1000)),
            "cutAt": ms(now),
        ]
        bump("segments")
        emit("state", ["state": "recognizing"])
        transcribe(audio, meta: meta)
    }

    // MARK: - 書き起こし

    private func transcribe(_ samples: [Float], meta: [String: Double]) {
        let wav = TalkFitVoicePlugin.wavData(samples, sampleRate: 16000)
        var m = meta
        m["sec"] = Double(samples.count) / 16000
        m["sendAt"] = ms(Date())
        send(wav: wav, meta: m, attempt: 0, savedId: nil)
    }

    private func makeRequest(wav: Data, sec: Double) -> URLRequest? {
        let boundary = "talkfit-\(UUID().uuidString)"
        var fields: [(String, String)] = [("response_format", "text"), ("language", language)]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }

        var req: URLRequest
        if mode == "server" {
            guard let url = URL(string: apiBase + "/v1/transcribe") else { return nil }
            req = URLRequest(url: url)
            req.setValue(deviceId, forHTTPHeaderField: "X-Device")
            req.setValue(String(format: "%.1f", sec), forHTTPHeaderField: "X-Audio-Sec")
        } else {
            guard !apiKey.isEmpty else { return nil }
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            fields.append(("model", model))
            fields.append(("temperature", "0"))
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = TalkFitVoicePlugin.multipart(boundary: boundary, fields: fields, file: wav)
        return req
    }

    /// savedId：端末に保存しておいた発話を送り直している時のファイル名
    private func send(wav: Data, meta: [String: Double], attempt: Int, savedId: String?) {
        guard let req = makeRequest(wav: wav, sec: meta["sec"] ?? 1) else {
            if savedId != nil { DispatchQueue.main.async { self.flushing = false } }
            else { emit("error", ["status": 0, "message": "サーバーのURLかキーが設定されていません"]) }
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let quota = body.contains("insufficient_quota")

            // 通信の瞬断・混雑：2回まで待ってやり直し、だめなら端末に保存して後で送る
            let retryable = err != nil || status >= 500 || (status == 429 && !quota)
            if retryable {
                if savedId != nil {                    // まだ通信が戻っていない。次の機会に
                    DispatchQueue.main.async { self.flushing = false }
                    return
                }
                if attempt < 2 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + (attempt == 0 ? 1.5 : 4)) {
                        self.send(wav: wav, meta: meta, attempt: attempt + 1, savedId: nil)
                    }
                    return
                }
                self.saveRetry(wav: wav, meta: meta)
                self.note("queued", err?.localizedDescription ?? "HTTP \(status)", count: "queued")
                self.emit("state", ["state": "listening"])
                return
            }
            guard err == nil, (200..<300).contains(status) else {
                if let id = savedId { self.deleteRetry(id); DispatchQueue.main.async { self.flushing = false; self.flushRetry() } }
                if status == 400 && body.contains("too_short") {
                    self.emit("state", ["state": "listening"])
                    return
                }
                var message = err?.localizedDescription ?? String(body.prefix(200))
                if quota { message = "insufficient_quota" }
                // 画面ロック中は JS に届かないので、端末の記録と「ブブッ」という音で残す
                self.note("fail", "HTTP \(status) \(message.prefix(80))", count: "failed")
                self.playErrorTone()
                self.emit("error", ["status": status, "message": message])
                self.emit("state", ["state": "listening"])
                return
            }

            var text = body
            if self.mode == "server",
               let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                text = (obj["text"] as? String) ?? ""
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var m = meta
            m["apiDoneAt"] = self.ms(Date())
            if let id = savedId {
                m["late"] = 1
                self.deleteRetry(id)
                self.note("late", text, count: "late")
            }
            self.bump("ok")
            self.deliver(text: text, meta: m)
            // 通信できている今のうちに、保存しておいた分も送る
            DispatchQueue.main.async {
                if savedId != nil { self.flushing = false }
                self.flushRetry()
            }
        }.resume()
    }

    // MARK: - 通信できなかった発話の保存と送り直し

    private func retryFiles() -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: TalkFitVoicePlugin.retryDir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func saveRetry(wav: Data, meta: [String: Double]) {
        // ファイル名の先頭を時刻にして、古い順に送れるようにする
        let id = String(format: "%013.0f", ms(Date())) + "-" + String(UUID().uuidString.prefix(8))
        let dir = TalkFitVoicePlugin.retryDir
        guard let json = try? JSONSerialization.data(withJSONObject: meta) else { return }
        try? wav.write(to: dir.appendingPathComponent(id + ".wav"))
        try? json.write(to: dir.appendingPathComponent(id + ".json"))
        let files = retryFiles()
        if files.count > 60 {
            for f in files.prefix(files.count - 60) { deleteRetry(f.deletingPathExtension().lastPathComponent) }
        }
    }

    private func deleteRetry(_ id: String) {
        let dir = TalkFitVoicePlugin.retryDir
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".wav"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
    }

    /// 保存しておいた発話を1件ずつ送る（メインスレッド）
    private func flushRetry() {
        guard !flushing, let f = retryFiles().first else { return }
        let id = f.deletingPathExtension().lastPathComponent
        guard let md = try? Data(contentsOf: f),
              let meta = (try? JSONSerialization.jsonObject(with: md)) as? [String: Double],
              let wav = try? Data(contentsOf: TalkFitVoicePlugin.retryDir.appendingPathComponent(id + ".wav")) else {
            deleteRetry(id)
            return
        }
        flushing = true
        var m = meta
        m["sendAt"] = ms(Date())
        send(wav: wav, meta: m, attempt: 0, savedId: id)
    }

    private func deliver(text: String, meta: [String: Double]) {
        emit("state", ["state": "listening"])
        guard text.count >= 2 else { return }
        // URLSession の完了処理はメイン以外で動くので、メインに問い合わせてよい
        let bg = Thread.isMainThread ? !appActive : DispatchQueue.main.sync { !self.appActive }
        var item: [String: Any] = [
            "id": UUID().uuidString,
            "text": text,
            "ts": meta["speechEndAt"] ?? ms(Date()),
            "bg": bg ? 1 : 0,
        ]
        for (k, v) in meta { item[k] = v }
        if bg { bump("bgDelivered") }

        // JS が止まっていても（画面ロック中など）失わないよう、先に端末へ保存する
        store.sync {
            var q = self.loadPending()
            q.append(item)
            if q.count > 300 { q.removeFirst(q.count - 300) }
            self.savePending(q)
        }
        // 数字が聞き取れた＝記録になる見込みの発話なら、画面を見なくても分かるよう合図を鳴らす
        if text.range(of: "[0-9０-９一二三四五六七八九十百]", options: .regularExpression) != nil {
            playChime()
        }
        emit("transcript", item, always: true)
    }

    // MARK: - 検証用の記録

    private func persistDiag() {
        UserDefaults.standard.set(["sid": sid, "stats": stats, "events": events], forKey: diagKey)
    }

    private func bump(_ key: String, _ by: Double = 1) {
        store.async {
            self.stats[key, default: 0] += by
            self.persistDiag()
        }
    }

    private func setStat(_ key: String, _ v: Double) {
        store.async {
            self.stats[key] = v
            self.persistDiag()
        }
    }

    private func note(_ kind: String, _ message: String, count: String? = nil) {
        let e: [String: Any] = ["t": ms(Date()), "k": kind, "m": String(message.prefix(120)), "bg": appActive ? 0 : 1]
        store.async {
            self.events.append(e)
            if self.events.count > 150 { self.events.removeFirst(self.events.count - 150) }
            if let c = count { self.stats[c, default: 0] += 1 }
            self.persistDiag()
        }
    }

    // MARK: - 待ち行列

    private func loadPending() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]]) ?? []
    }

    private func savePending(_ q: [[String: Any]]) {
        UserDefaults.standard.set(q, forKey: pendingKey)
    }

    // MARK: - JS への通知

    /// 画面が見えていない間は表示用の通知を送らない（再開時に大量に溜まって固まるため）
    private func emit(_ event: String, _ data: [String: Any], always: Bool = false) {
        DispatchQueue.main.async {
            guard always || self.appActive else { return }
            self.notifyListeners(event, data: data)
        }
    }

    private func emitLevel(_ db: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) >= 0.1 else { return }
        lastLevelAt = now
        emit("level", ["db": Double(db), "floor": Double(floorDb)])
    }

    // MARK: - 合図の音

    private func makeChime(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let n = AVAudioFrameCount(sr * 0.3)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let ch = b.floatChannelData?[0] else { return nil }
        b.frameLength = n
        var phase = 0.0
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let f = t < 0.09 ? 1046.5 : 1318.5          // ド → ミ
            phase += 2 * Double.pi * f / sr
            let env = min(1, t / 0.01) * exp(-max(0, t - 0.01) * 12)
            ch[i] = Float(sin(phase) * env * 0.22)
        }
        return b
    }

    /// 認識に失敗して記録できなかった時の音（低い「ブブッ」）
    private func makeErrorTone(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let n = AVAudioFrameCount(sr * 0.32)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let ch = b.floatChannelData?[0] else { return nil }
        b.frameLength = n
        var phase = 0.0
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let on = t < 0.12 || (t > 0.18 && t < 0.30)
            phase += 2 * Double.pi * 220 / sr
            ch[i] = on ? Float(sin(phase) * 0.18) : 0
        }
        return b
    }

    private func playErrorTone() {
        DispatchQueue.main.async {
            guard self.running, let b = self.errorBuffer else { return }
            self.player.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
            if !self.player.isPlaying { self.player.play() }
        }
    }

    private func playChime() {
        DispatchQueue.main.async {
            guard self.running, let b = self.chimeBuffer else { return }
            self.player.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
            if !self.player.isPlaying { self.player.play() }
        }
    }

    // MARK: - ユーティリティ

    private func ms(_ d: Date) -> Double {
        return d.timeIntervalSince1970 * 1000
    }

    static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    static func multipart(boundary: String, fields: [(String, String)], file: Data) -> Data {
        var body = Data()
        func line(_ s: String) { body.append(contentsOf: Array(s.utf8)) }
        for (k, v) in fields {
            line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        line("Content-Type: audio/wav\r\n\r\n")
        body.append(file)
        line("\r\n--\(boundary)--\r\n")
        return body
    }
}
