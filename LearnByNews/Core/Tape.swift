import Foundation
import AVFoundation
import MediaPlayer

/// 표현장 테이프 (goni 2026-11-18 "읽어 주고 뜻 말해 주는 음악 테이프 같은 기능, 무심코 틀어 두고 듣게"):
/// 영어 표현(기본 두 번) → 한국어 뜻 → (옵션) 원문 문장 → 사이 → 다음. AVSpeechSynthesizer(en-US·ko-KR, 가능하면 고품질 목소리),
/// AVAudioSession playback + UIBackgroundModes audio로 화면이 꺼져도·다른 앱에 가도 계속, 잠금 화면/제어 센터(MPRemoteCommandCenter·MPNowPlayingInfo).
@MainActor
final class TapePlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TapePlayer()
    enum Bucket: String, CaseIterable { case pending, mastered, all }
    enum Order: String, CaseIterable { case shuffle, recent }

    @Published private(set) var items: [Phrase] = []
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published private(set) var step = 0            // 지금 읽는 단계: 0..<repeats 표현, repeats 뜻, repeats+1 원문
    @Published var err: String?
    // 설정 (기억)
    @Published var bucket: Bucket = Bucket(rawValue: UserDefaults.standard.string(forKey: "lbn_tape_bucket") ?? "") ?? .pending { didSet { UserDefaults.standard.set(bucket.rawValue, forKey: "lbn_tape_bucket") } }
    @Published var order: Order = Order(rawValue: UserDefaults.standard.string(forKey: "lbn_tape_order") ?? "") ?? .shuffle { didSet { UserDefaults.standard.set(order.rawValue, forKey: "lbn_tape_order") } }
    @Published var rate: Double = UserDefaults.standard.object(forKey: "lbn_tape_rate") as? Double ?? 1.0 { didSet { UserDefaults.standard.set(rate, forKey: "lbn_tape_rate") } }        // 0.8~1.25×
    @Published var gap: Double = UserDefaults.standard.object(forKey: "lbn_tape_gap") as? Double ?? 1.5 { didSet { UserDefaults.standard.set(gap, forKey: "lbn_tape_gap") } }          // 사이 0.6~3초
    @Published var repeats: Int = UserDefaults.standard.object(forKey: "lbn_tape_repeats") as? Int ?? 2 { didSet { UserDefaults.standard.set(repeats, forKey: "lbn_tape_repeats") } }   // 표현 반복 1~3
    @Published var sentence: Bool = UserDefaults.standard.object(forKey: "lbn_tape_sentence") as? Bool ?? false { didSet { UserDefaults.standard.set(sentence, forKey: "lbn_tape_sentence") } }
    /// 번호 범위(붙인 순서 seq, goni 2026-11-18): nil이면 전부. 범위 안은 번호 순이 기본, 섞음이면 그 안에서
    @Published var range: ClosedRange<Int>? = RangePick.load("lbn_tape_range") { didSet { RangePick.save(range, "lbn_tape_range") } }
    var maxSeq: Int { all.compactMap(\.seq).max() ?? 0 }

    private let synth = AVSpeechSynthesizer()
    private var all: [Phrase] = []
    private var gapTask: Task<Void, Never>?
    private var remoteSetUp = false
    private lazy var enVoice = Self.bestVoice(lang: "en-US", prefer: ["Samantha", "Ava", "Zoe", "Allison"])
    private lazy var koVoice = Self.bestVoice(lang: "ko-KR", prefer: ["Yuna", "Suhyun", "Sora"])

    private override init() { super.init(); synth.delegate = self }

    var current: Phrase? { index < items.count ? items[index] : nil }
    var pendingCount: Int { all.filter { !$0.isMastered }.count }
    var masteredCount: Int { all.filter(\.isMastered).count }

    /// 표현장 전체를 받아(오프라인이면 캐시) 묶음·순서대로 목록을 만든다. 재생 중이면 멈춘다
    func load() async {
        stop()
        if all.isEmpty, let c = Cache.shared.phrases(q: "") { all = c }
        do { all = try await API.shared.phrases(); err = nil }
        catch let e as APIError where e.isNetwork { if all.isEmpty { err = e.localizedDescription } }
        catch { err = error.localizedDescription }
        rebuild()
    }
    func rebuild() {
        let pool = all.filter { bucket == .all || ($0.isMastered == (bucket == .mastered)) }
            .filter { p in range.map { r in p.seq.map(r.contains) ?? false } ?? true }
        let base = range != nil ? pool.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) } : pool   // 범위 안은 번호 순, 아니면 GET /api/phrases의 최신순
        items = order == .shuffle ? base.shuffled() : base
        index = 0; step = 0
    }
    func set(bucket b: Bucket) { stop(); bucket = b; rebuild() }
    func set(order o: Order) { stop(); order = o; rebuild() }
    func set(range r: ClosedRange<Int>?) { stop(); range = r; rebuild() }

    // MARK: 재생
    func play() {
        guard !items.isEmpty else { return }
        if index >= items.count { index = 0; step = 0 }
        activateSession(); setUpRemote()
        playing = true
        speakStep()
    }
    func pause() {
        playing = false
        gapTask?.cancel(); gapTask = nil
        synth.stopSpeaking(at: .immediate)
        updateNowPlaying()
    }
    func toggle() { playing ? pause() : play() }
    /// 완전히 멈춤 (목록이 바뀔 때)
    func stop() { pause(); step = 0 }
    func next() { guard !items.isEmpty else { return }; jump(to: (index + 1) % items.count) }
    func prev() { guard !items.isEmpty else { return }; jump(to: (index - 1 + items.count) % items.count) }
    func jump(to i: Int) {
        gapTask?.cancel(); gapTask = nil
        synth.stopSpeaking(at: .immediate)
        index = i; step = 0
        if playing { speakStep() } else { updateNowPlaying() }
    }

    /// 지금 단계를 읽는다. 끝나면 delegate가 다음 단계로
    private func speakStep() {
        guard playing, let p = current else { playing = false; return }
        let hasSentence = sentence && !(p.sentenceText ?? "").isEmpty
        let steps = repeats + 1 + (hasSentence ? 1 : 0)
        if step >= steps { afterGap { self.index = (self.index + 1) % self.items.count; self.step = 0; self.speakStep() }; return }
        let u: AVSpeechUtterance
        if step < repeats { u = AVSpeechUtterance(string: p.phrase); u.voice = enVoice }
        else if step == repeats { u = AVSpeechUtterance(string: p.meaning.isEmpty ? "뜻 없음" : p.meaning); u.voice = koVoice }
        else { u = AVSpeechUtterance(string: p.sentenceText ?? ""); u.voice = enVoice }
        u.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        u.postUtteranceDelay = 0
        updateNowPlaying()
        synth.speak(u)
    }
    private func afterGap(_ then: @escaping @MainActor () -> Void) {
        gapTask?.cancel()
        gapTask = Task { [gap] in
            try? await Task.sleep(for: .seconds(gap))
            guard !Task.isCancelled else { return }
            then()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.playing else { return }
            self.step += 1
            // 표현 반복 사이는 짧게, 뜻·원문 뒤는 설정한 사이
            let short = self.step < self.repeats
            self.gapTask?.cancel()
            self.gapTask = Task { [gap = short ? 0.35 : self.gap] in
                try? await Task.sleep(for: .seconds(gap))
                guard !Task.isCancelled else { return }
                self.speakStep()
            }
        }
    }

    // MARK: 오디오 세션·잠금 화면
    private func activateSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .spokenAudio, options: [])
            try s.setActive(true)
        } catch { AppLog.shared.warn("tape", "audio session: \(error.localizedDescription)") }
    }
    private func setUpRemote() {
        guard !remoteSetUp else { return }
        remoteSetUp = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.prev() }; return .success }
    }
    private func updateNowPlaying() {
        guard let p = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: (p.seq.map { "#\($0) · " } ?? "") + p.phrase,
            MPMediaItemPropertyArtist: p.meaning,
            MPMediaItemPropertyAlbumTitle: "표현장 테이프 · \(index + 1)/\(items.count)",
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        #if targetEnvironment(macCatalyst)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
    }
    /// 가능하면 고품질(premium > enhanced) 목소리, 이름이 맞으면 그것부터
    private static func bestVoice(lang: String, prefer: [String]) -> AVSpeechSynthesisVoice? {
        let vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        func q(_ v: AVSpeechSynthesisVoice) -> Int { v.quality == .premium ? 2 : v.quality == .enhanced ? 1 : 0 }
        let sorted = vs.sorted { a, b in
            let (pa, pb) = (prefer.firstIndex { a.name.contains($0) } ?? 99, prefer.firstIndex { b.name.contains($0) } ?? 99)
            return q(a) != q(b) ? q(a) > q(b) : pa < pb
        }
        return sorted.first ?? AVSpeechSynthesisVoice(language: lang)
    }
}
