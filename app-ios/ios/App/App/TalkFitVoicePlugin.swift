import Foundation
import AVFoundation
import UIKit
import Capacitor

/// 声の録音・区切り・書き起こしをネイティブで行うプラグイン。
///
/// なぜネイティブか：iPhone の Web アプリでは、録音中に Spotify などが音楽を流すと
/// iOS にマイクを止められる。ここでは音声セッションを「他のアプリと共存（mixWithOthers）」
/// に設定するため、音楽を流したまま録音でき、画面ロック中（ポケットの中）も動き続ける。
///
/// 流れ：マイク → 16kHz に変換 → 音量で発話区間を切り出す → WAV にして書き起こし API へ
///       → 結果を端末内の待ち行列に保存し JS に通知（JS が止まっていても失われない）
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
    ]

    // ── 録音 ──
    // 音声システムがリセットされると古いエンジンは使えなくなるので、作り直せるよう var にする
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var chimeBuffer: AVAudioPCMBuffer?
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

    private let pendingKey = "talkfit.pending"

    // MARK: - JS から呼ばれるメソッド

    @objc func start(_ call: CAPPluginCall) {
        applyConfig(call)
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
            self.teardownEngine()
            self.unobserve()
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

        engine.prepare()
        try engine.start()
        running = true
        work.async { self.resetVad() }
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
        teardownEngine()
        do {
            try startEngine()
        } catch {
            emit("error", ["status": 0, "message": "録音を再開できません（\(reason)）: \(error.localizedDescription)"])
        }
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
            self.engine = AVAudioEngine()
            self.player = AVAudioPlayerNode()
            self.restart("media services reset")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
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
            // 電話・アラームなど。終わったら自動で再開する
            running = false
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
        emit("state", ["state": "recognizing"])
        transcribe(audio, meta: meta)
    }

    // MARK: - 書き起こし

    private func transcribe(_ samples: [Float], meta: [String: Double]) {
        let wav = TalkFitVoicePlugin.wavData(samples, sampleRate: 16000)
        let sec = Double(samples.count) / 16000
        let boundary = "talkfit-\(UUID().uuidString)"
        var fields: [(String, String)] = [("response_format", "text"), ("language", language)]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }

        var req: URLRequest
        if mode == "server" {
            guard let url = URL(string: apiBase + "/v1/transcribe") else {
                emit("error", ["status": 0, "message": "サーバーのURLが正しくありません"])
                return
            }
            req = URLRequest(url: url)
            req.setValue(deviceId, forHTTPHeaderField: "X-Device")
            req.setValue(String(format: "%.1f", sec), forHTTPHeaderField: "X-Audio-Sec")
        } else {
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            fields.append(("model", model))
            fields.append(("temperature", "0"))
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = TalkFitVoicePlugin.multipart(boundary: boundary, fields: fields, file: wav)

        var m = meta
        m["sendAt"] = ms(Date())
        send(req, attempt: 0, meta: m)
    }

    private func send(_ req: URLRequest, attempt: Int, meta: [String: Double]) {
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""

            // 通信の瞬断・混雑は一度だけ待ってやり直す（残高不足の 429 は除く）
            let retryable = err != nil || status >= 500 || (status == 429 && !body.contains("insufficient_quota"))
            if retryable && attempt < 1 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    self.send(req, attempt: attempt + 1, meta: meta)
                }
                return
            }
            guard err == nil, (200..<300).contains(status) else {
                if status == 400 && body.contains("too_short") {
                    self.emit("state", ["state": "listening"])
                    return
                }
                var message = err?.localizedDescription ?? String(body.prefix(200))
                if body.contains("insufficient_quota") { message = "insufficient_quota" }
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
            self.deliver(text: text, meta: m)
        }.resume()
    }

    private func deliver(text: String, meta: [String: Double]) {
        emit("state", ["state": "listening"])
        guard text.count >= 2 else { return }
        var item: [String: Any] = [
            "id": UUID().uuidString,
            "text": text,
            "ts": meta["speechEndAt"] ?? ms(Date()),
        ]
        for (k, v) in meta { item[k] = v }

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
