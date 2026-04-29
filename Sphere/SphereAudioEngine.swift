//
//  SphereAudioEngine.swift
//  Sphere
//
//  Audio engine с AVAudioEngine + AVAudioUnitEQ для эквалайзера.
//  Заменяет прямое использование AVPlayer для воспроизведения треков.
//

import AVFoundation
import Combine

final class SphereAudioEngine: ObservableObject {
    static let shared = SphereAudioEngine()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 6)

    /// Текущий аудиофайл
    private var audioFile: AVAudioFile?
    /// Длительность текущего файла в секундах
    @Published private(set) var duration: TimeInterval = 0
    /// true если playerNode играет
    @Published private(set) var isPlaying: Bool = false

    /// Частоты полос эквалайзера
    private let frequencies: [Float] = [60, 150, 400, 1000, 2400, 15000]

    /// Сохранённые значения EQ (0…1, 0.5 = flat)
    @Published var eqValues: [CGFloat] = {
        if let data = UserDefaults.standard.data(forKey: "sphere_eq_values"),
           let vals = try? JSONDecoder().decode([CGFloat].self, from: data),
           vals.count == 6 {
            return vals
        }
        return [0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
    }() {
        didSet { applyEQ(); saveEQ() }
    }

    /// Семплрейт текущего файла (нужен для sampleTime → секунды)
    private var fileSampleRate: Double = 44100

    /// Фрейм, с которого начали последний play (для расчёта currentTime)
    private var segmentStartFrame: AVAudioFramePosition = 0
    /// Смещение "виртуальное" от seek, пока playerNode стоит
    private var seekOffsetFrame: AVAudioFramePosition = 0

    private init() {
        setupEngine()
    }

    // MARK: - Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(eq)

        // Настраиваем полосы EQ
        for (i, freq) in frequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.gain = 0 // flat
            band.bypass = false
        }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        engine.prepare()
    }

    // MARK: - Apply EQ

    /// Преобразует значение 0…1 в gain в дБ: 0.5 = 0 дБ, 0 = -12 дБ, 1 = +12 дБ
    private func applyEQ() {
        for (i, val) in eqValues.enumerated() where i < eq.bands.count {
            let db = Float((val - 0.5) * 24) // диапазон -12…+12 дБ
            eq.bands[i].gain = db
        }
    }

    func saveEQ() {
        if let data = try? JSONEncoder().encode(eqValues) {
            UserDefaults.standard.set(data, forKey: "sphere_eq_values")
        }
    }

    // MARK: - Загрузка и воспроизведение

    /// Загружает аудиофайл. Возвращает true при успехе.
    @discardableResult
    func load(url: URL) -> Bool {
        stop()

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            fileSampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / fileSampleRate
            segmentStartFrame = 0
            seekOffsetFrame = 0

            // Перезапускаем engine с правильным форматом файла
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(eq)
            engine.connect(playerNode, to: eq, format: file.processingFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)
            engine.prepare()
            applyEQ()
            return true
        } catch {
            NSLog("[SphereAudioEngine] load error: %@", error.localizedDescription)
            audioFile = nil
            duration = 0
            return false
        }
    }

    func play() {
        guard let file = audioFile else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            NSLog("[SphereAudioEngine] engine start error: %@", error.localizedDescription)
            return
        }

        // Считаем, откуда начинать
        let startFrame = seekOffsetFrame
        let totalFrames = file.length
        let remainingFrames = totalFrames - startFrame
        guard remainingFrames > 0 else { return }

        playerNode.stop()
        file.framePosition = startFrame
        segmentStartFrame = startFrame

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames),
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
            }
        }
        playerNode.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        // Запоминаем текущую позицию
        let pos = currentFrame
        playerNode.stop()
        seekOffsetFrame = pos
        isPlaying = false
    }

    func stop() {
        playerNode.stop()
        // Не останавливаем engine — он пригодится при следующем play()
        isPlaying = false
        segmentStartFrame = 0
        seekOffsetFrame = 0
    }

    // MARK: - Позиция

    /// Текущий фрейм в файле
    private var currentFrame: AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return seekOffsetFrame
        }
        return segmentStartFrame + playerTime.sampleTime
    }

    /// Текущее время воспроизведения в секундах
    var currentTime: TimeInterval {
        guard fileSampleRate > 0 else { return 0 }
        let frame = isPlaying ? currentFrame : seekOffsetFrame
        return max(0, Double(frame) / fileSampleRate)
    }

    /// Прогресс 0…1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// Seek к позиции 0…1
    func seek(to progress: Double) {
        guard let file = audioFile else { return }
        let clamped = min(max(progress, 0), 1)
        let targetFrame = AVAudioFramePosition(clamped * Double(file.length))

        let wasPlaying = isPlaying
        if wasPlaying {
            playerNode.stop()
        }

        seekOffsetFrame = targetFrame
        segmentStartFrame = targetFrame

        if wasPlaying {
            let remainingFrames = file.length - targetFrame
            guard remainingFrames > 0 else {
                isPlaying = false
                return
            }
            file.framePosition = targetFrame
            playerNode.scheduleSegment(
                file,
                startingFrame: targetFrame,
                frameCount: AVAudioFrameCount(remainingFrames),
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                }
            }
            playerNode.play()
        }
    }

    /// Seek к позиции в секундах
    func seek(toTime time: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: time / duration)
    }

    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }
}
