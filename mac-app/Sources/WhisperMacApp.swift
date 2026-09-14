import AppKit
import Security
import SwiftUI

private enum KeychainToken {
    static let service = "com.whispermac.app"
    static let account = "huggingface-token"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

private struct DetectedSpeaker: Codable, Identifiable {
    let label: String
    var displayName: String
    let embedding: [Double]
    let duration: Double
    var profileId: String?
    var confidence: Double?
    let order: Int

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label, embedding, duration, confidence, order
        case displayName = "display_name"
        case profileId = "profile_id"
    }
}

private struct SpeakerSession: Codable {
    let version: Int
    let source: String
    let speakers: [DetectedSpeaker]
}

private struct VoiceProfile: Codable, Identifiable {
    let id: String
    var name: String
    var samples: [[Double]]
}

private struct VoiceProfileStore: Codable {
    var version = 1
    var profiles: [VoiceProfile] = []
}

final class RuntimeController: ObservableObject {
    @Published var running = false
    @Published var status = "Нужно подготовить приложение"
    @Published var detail = ""
    @Published var progress = 0.0
    @Published var elapsedSeconds = 0
    @Published var hasError = false
    @Published var modelAccessRequired = false
    @Published var errorDetails = ""
    @Published var log = ""
    @Published fileprivate var detectedSpeakers: [DetectedSpeaker] = []
    @Published fileprivate var voiceProfiles: [VoiceProfile] = []

    let supportDirectory: URL
    let modelsDirectory: URL
    private let runtimeDirectory: URL
    private let binDirectory: URL
    private let uvCacheDirectory: URL
    private let pythonDirectory: URL
    private let progressPrefix = "@@WHISPER_MAC_PROGRESS@@"
    private var progressTimer: Timer?
    private var activeProcess: Process?
    private var cancelRequested = false
    private var recognitionSpeed: Double?

    private var profilesURL: URL {
        supportDirectory.appendingPathComponent("speaker-profiles.json")
    }

    private var sessionURL: URL {
        supportDirectory.appendingPathComponent("last-session.json")
    }

    init() {
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDirectory = library.appendingPathComponent("WhisperMac", isDirectory: true)
        modelsDirectory = supportDirectory.appendingPathComponent("models", isDirectory: true)
        runtimeDirectory = supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        binDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        uvCacheDirectory = supportDirectory.appendingPathComponent("uv-cache", isDirectory: true)
        pythonDirectory = supportDirectory.appendingPathComponent("python", isDirectory: true)
        loadVoiceProfiles()
        refreshStatus()
    }

    private func loadVoiceProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let store = try? JSONDecoder().decode(VoiceProfileStore.self, from: data) else {
            voiceProfiles = []
            return
        }
        voiceProfiles = store.profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func saveVoiceProfiles() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(VoiceProfileStore(profiles: voiceProfiles))
        try data.write(to: profilesURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: profilesURL.path
        )
    }

    private func readSessionSpeakers() -> [DetectedSpeaker] {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SpeakerSession.self, from: data) else {
            return []
        }
        return session.speakers.sorted { $0.order < $1.order }
    }

    func rememberSpeaker(label: String, name rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let detectedIndex = detectedSpeakers.firstIndex(where: { $0.label == label }) else {
            return
        }
        let embedding = detectedSpeakers[detectedIndex].embedding
        guard !embedding.isEmpty else { return }

        let profileId: String
        if let profileIndex = voiceProfiles.firstIndex(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            voiceProfiles[profileIndex].samples.append(embedding)
            voiceProfiles[profileIndex].samples = Array(voiceProfiles[profileIndex].samples.suffix(8))
            profileId = voiceProfiles[profileIndex].id
        } else {
            profileId = UUID().uuidString
            voiceProfiles.append(VoiceProfile(id: profileId, name: name, samples: [embedding]))
        }
        voiceProfiles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try saveVoiceProfiles()
        detectedSpeakers[detectedIndex].displayName = name
        detectedSpeakers[detectedIndex].profileId = profileId
        detectedSpeakers[detectedIndex].confidence = 1
    }

    func removeVoiceProfile(id: String) throws {
        voiceProfiles.removeAll { $0.id == id }
        try saveVoiceProfiles()
        for index in detectedSpeakers.indices where detectedSpeakers[index].profileId == id {
            detectedSpeakers[index].profileId = nil
            detectedSpeakers[index].confidence = nil
            detectedSpeakers[index].displayName = "Спикер \(detectedSpeakers[index].order + 1)"
        }
    }

    var pythonExecutable: URL {
        runtimeDirectory.appendingPathComponent("bin/python")
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
    }

    func refreshStatus() {
        status = isInstalled ? "Готово к работе" : "Нужно подготовить приложение"
    }

    var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func begin(_ title: String, detail: String = "") {
        running = true
        status = title
        self.detail = detail
        progress = 0
        elapsedSeconds = 0
        recognitionSpeed = nil
        cancelRequested = false
        hasError = false
        modelAccessRequired = false
        errorDetails = ""
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }
    }

    private func finish(
        _ title: String,
        detail: String = "",
        error: Bool = false,
        modelAccessRequired: Bool = false
    ) {
        progressTimer?.invalidate()
        progressTimer = nil
        running = false
        status = title
        self.detail = detail
        hasError = error
        self.modelAccessRequired = modelAccessRequired
        activeProcess = nil
    }

    private func isModelAccessError(_ error: Error) -> Bool {
        let value = error.localizedDescription.lowercased()
        return value.contains("hf_token") || value.contains("unauthorized") ||
            value.contains("gated") || value.contains("401") || value.contains("403") ||
            value.contains("accept") || value.contains("community-1") ||
            (value.contains("модел") && value.contains("доступ"))
    }

    private func friendlyError(_ error: Error) -> String {
        let value = error.localizedDescription.lowercased()
        if isModelAccessError(error) {
            return "Подтвердите доступ к разделению голосов на Hugging Face и проверьте ключ"
        }
        if value.contains("network") || value.contains("connect") || value.contains("timed out") {
            return "Проверьте интернет-соединение и повторите попытку"
        }
        if value.contains("metal") {
            return "Не удалось включить ускорение Apple Silicon. Перезапустите приложение"
        }
        if value.contains("no space") {
            return "Недостаточно свободного места для загрузки моделей"
        }
        return "Повторите попытку — уже загруженные данные останутся на компьютере"
    }

    private func append(_ text: String) {
        DispatchQueue.main.async {
            self.log += text + (text.hasSuffix("\n") ? "" : "\n")
        }
    }

    private func recordError(_ error: Error) -> String {
        var value = error.localizedDescription
        value = value.replacingOccurrences(
            of: #"hf_[A-Za-z0-9]+"#,
            with: "hf_••••",
            options: .regularExpression
        )
        let usefulLines = value.components(separatedBy: .newlines).filter { line in
            !line.hasPrefix(progressPrefix) && !line.contains("frames/s")
        }
        let cleaned = usefulLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = String(cleaned.suffix(6000))
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try? stored.write(
            to: supportDirectory.appendingPathComponent("last-error.txt"),
            atomically: true,
            encoding: .utf8
        )
        return String(stored.suffix(1800))
    }

    private func environment(token: String = "") -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_CACHE_DIR"] = uvCacheDirectory.path
        env["UV_PYTHON_INSTALL_DIR"] = pythonDirectory.path
        env["HF_HOME"] = modelsDirectory.appendingPathComponent("huggingface").path
        env["HF_HUB_CACHE"] = modelsDirectory.appendingPathComponent("huggingface/hub").path
        env["XDG_CACHE_HOME"] = modelsDirectory.appendingPathComponent("cache").path
        env["MPLCONFIGDIR"] = modelsDirectory.appendingPathComponent("matplotlib").path
        env["WHISPER_MAC_PROGRESS"] = "1"
        env.removeValue(forKey: "FFMPEG_BINARY")
        if !token.isEmpty { env["HF_TOKEN"] = token }
        if let resources = Bundle.main.resourceURL {
            env["PYTHONPATH"] = resources.appendingPathComponent("python").path
        }
        return env
    }

    private func handleOutputLine(_ line: String) {
        guard line.hasPrefix(progressPrefix) else {
            if let percentRange = line.range(of: #"\d+(?=%)"#, options: .regularExpression),
               let percent = Double(line[percentRange]) {
                let speedPattern = #"[0-9]+(?:\.[0-9]+)?(?=frames/s)"#
                let frameSpeed = line.range(of: speedPattern, options: .regularExpression)
                    .flatMap { Double(line[$0]) }
                DispatchQueue.main.async {
                    guard self.status == "Распознаём речь" else { return }
                    self.progress = min(1, max(0, percent / 100))
                    if let frameSpeed {
                        self.detail = String(
                            format: "Обработано %.0f%% · %.1f× реального времени",
                            percent,
                            frameSpeed / 100
                        )
                    } else {
                        self.detail = String(format: "Обработано %.0f%%", percent)
                    }
                }
            }
            if !line.isEmpty { append(line) }
            return
        }
        let payload = String(line.dropFirst(progressPrefix.count))
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stage = event["stage"] as? String else { return }

        DispatchQueue.main.async {
            let reportedProgress = (event["progress"] as? NSNumber)?.doubleValue ?? self.progress
            self.progress = reportedProgress
            switch stage {
            case "preparing":
                self.status = "Подготавливаем запись"
                self.detail = "Проверяем файл"
            case "converting":
                self.status = "Подготавливаем запись"
                self.detail = "Приводим звук к нужному формату"
            case "download_asr":
                self.status = "Загружаем модель распознавания"
                let downloaded = (event["downloaded"] as? NSNumber)?.doubleValue ?? 0
                let total = (event["total"] as? NSNumber)?.doubleValue ?? 0
                if total > 0 {
                    self.progress = downloaded / total
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    let ready = formatter.string(fromByteCount: Int64(downloaded))
                    let all = formatter.string(fromByteCount: Int64(total))
                    self.detail = "Загружено \(ready) из \(all) · сохранится для следующих запусков"
                } else {
                    self.detail = "Получаем сведения о загрузке…"
                }
            case "recognizing":
                self.status = "Распознаём речь"
                self.progress = 0
                self.detail = "Используем ускорение Apple Silicon"
            case "recognized":
                self.recognitionSpeed = (event["speed"] as? NSNumber)?.doubleValue
                self.progress = 1
                if let speed = self.recognitionSpeed {
                    self.detail = String(format: "Речь распознана со скоростью %.1f× реального времени", speed)
                }
            case "loading_diarization":
                self.status = "Готовим разделение голосов"
                self.progress = 0
                self.detail = "При первом запуске необходимые данные будут загружены"
            case "diarizing":
                self.status = "Разделяем участников по голосам"
                self.progress = 0
                if let speed = self.recognitionSpeed {
                    self.detail = String(format: "Распознавание завершено: %.1f× · анализируем голоса", speed)
                } else {
                    self.detail = "Анализируем, кто и когда говорит"
                }
            case "diarization_accelerated":
                self.status = "Разделяем участников по голосам"
                self.progress = 0
                self.detail = "Используем быстрое ускорение Apple Silicon"
            case "diarization_cpu_fallback":
                self.status = "Продолжаем анализ голосов"
                self.progress = 0
                self.detail = "Переключились в совместимый режим"
            case "diarization_progress":
                self.status = "Разделяем участников по голосам"
                self.progress = reportedProgress
                let step = (event["step"] as? String ?? "").lowercased()
                if step.contains("segment") {
                    self.detail = "Находим участки речи"
                } else if step.contains("embedding") {
                    self.detail = "Сравниваем голоса"
                } else if step.contains("cluster") {
                    self.detail = "Группируем реплики по участникам"
                } else {
                    self.detail = "Анализируем голоса"
                }
            case "diarized":
                self.progress = 1
            case "exporting":
                self.status = "Сохраняем результат"
                self.progress = 0.5
                self.detail = "Создаём выбранные файлы"
            case "done":
                self.progress = 1
            case "error":
                let code = event["code"] as? String ?? "processing"
                let message = event["message"] as? String ?? "Неизвестная ошибка"
                self.errorDetails = String(message.prefix(1600))
                self.hasError = true
                if code == "diarization" {
                    self.status = "Не удалось разделить голоса"
                    let lowered = message.lowercased()
                    let accessIssue = lowered.contains("token") || lowered.contains("доступ") ||
                        lowered.contains("access") || lowered.contains("401") ||
                        lowered.contains("403") || lowered.contains("gated") ||
                        lowered.contains("community-1")
                    self.modelAccessRequired = accessIssue
                    self.detail = accessIssue
                        ? "Подтвердите доступ к модели и проверьте сохранённый ключ"
                        : "Модель разделения голосов вернула ошибку"
                }
            default:
                break
            }
        }
    }

    @discardableResult
    private func execute(_ executable: URL, _ arguments: [String], token: String = "") throws -> String {
        append("$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(token: token)
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        activeProcess = process
        var data = Data()
        var pending = ""
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                pending += text
                while let separator = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(pending[..<separator]).trimmingCharacters(in: .newlines)
                    pending.removeSubrange(...separator)
                    handleOutputLine(line)
                }
            }
        }
        if !pending.isEmpty { handleOutputLine(pending) }
        process.waitUntilExit()
        activeProcess = nil
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WhisperMac.Process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Команда завершилась с ошибкой" : output]
            )
        }
        return output
    }

    func installRuntime() {
        guard !running else { return }
        log = ""
        begin("Подготавливаем приложение…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fm = FileManager.default
                for directory in [self.supportDirectory, self.modelsDirectory, self.binDirectory, self.uvCacheDirectory, self.pythonDirectory] {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                let installer = self.supportDirectory.appendingPathComponent("uv-installer.sh")
                try self.execute(
                    URL(fileURLWithPath: "/usr/bin/curl"),
                    ["--proto", "=https", "--tlsv1.2", "-LsSf", "https://astral.sh/uv/0.12.9/install.sh", "-o", installer.path]
                )
                var installEnv = self.environment()
                installEnv["UV_UNMANAGED_INSTALL"] = self.binDirectory.path
                let shell = Process()
                let pipe = Pipe()
                shell.executableURL = URL(fileURLWithPath: "/bin/sh")
                shell.arguments = [installer.path]
                shell.environment = installEnv
                shell.standardOutput = pipe
                shell.standardError = pipe
                try shell.run()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                shell.waitUntilExit()
                self.append(output)
                guard shell.terminationStatus == 0 else { throw NSError(domain: "WhisperMac.uv", code: 1) }

                let uv = self.binDirectory.appendingPathComponent("uv")
                try self.execute(uv, ["python", "install", "3.13"])
                try self.execute(uv, ["venv", self.runtimeDirectory.path, "--python", "3.13", "--clear"])
                try self.execute(
                    uv,
                    [
                        "pip", "install", "--python", self.pythonExecutable.path,
                        "mlx-whisper==0.4.3",
                        "pyannote.audio==4.0.7",
                        "imageio-ffmpeg>=0.6,<0.7",
                        "soundfile>=0.13,<0.14",
                    ]
                )
                DispatchQueue.main.async {
                    self.finish("Всё готово")
                }
            } catch {
                let diagnostics = self.recordError(error)
                self.append("Ошибка: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorDetails = diagnostics
                    self.finish(
                        "Не удалось завершить подготовку",
                        detail: self.friendlyError(error),
                        error: true
                    )
                }
            }
        }
    }

    func prepareModels(asrModel: String, diarization: Bool, token: String) {
        guard isInstalled, !running else { return }
        begin("Загружаем выбранный режим…", detail: "Это потребуется только один раз")
        let script = """
import os, sys
from whisper_mac_cli.core import ensure_huggingface_model, report_progress
ensure_huggingface_model(sys.argv[1], token=os.environ.get("HF_TOKEN") or None)
if sys.argv[2] == "1":
    report_progress("loading_diarization", 0.0)
    try:
        from pyannote.audio import Pipeline
        Pipeline.from_pretrained("pyannote/speaker-diarization-community-1", token=os.environ.get("HF_TOKEN"))
    except Exception as exc:
        report_progress("error", 0.0, code="diarization", message=str(exc))
        raise
print("Модели готовы")
"""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.execute(
                    self.pythonExecutable,
                    ["-c", script, asrModel, diarization ? "1" : "0"],
                    token: token
                )
                DispatchQueue.main.async {
                    self.finish(
                        "Всё готово",
                        detail: "Модели загружены и готовы к работе"
                    )
                }
            } catch {
                let diagnostics = self.recordError(error)
                self.append("Ошибка: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if !self.errorDetails.isEmpty {
                        self.finish(
                            self.status,
                            detail: self.detail,
                            error: true,
                            modelAccessRequired: self.modelAccessRequired
                        )
                    } else {
                        self.errorDetails = diagnostics
                        self.finish(
                            "Не удалось загрузить данные",
                            detail: self.friendlyError(error),
                            error: true,
                            modelAccessRequired: self.isModelAccessError(error)
                        )
                    }
                }
            }
        }
    }

    func transcribe(input: URL, output: URL, arguments: [String], token: String) {
        guard isInstalled, !running else { return }
        detectedSpeakers = []
        begin("Начинаем расшифровку…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try? FileManager.default.removeItem(at: self.sessionURL)
                var args = ["-m", "whisper_mac_cli.cli", input.path, "--backend", "mlx", "--output-dir", output.path]
                args += [
                    "--speaker-profiles", self.profilesURL.path,
                    "--session-result", self.sessionURL.path,
                ]
                args.append(contentsOf: arguments)
                try self.execute(self.pythonExecutable, args, token: token)
                let speakers = self.readSessionSpeakers()
                DispatchQueue.main.async {
                    self.detectedSpeakers = speakers
                    self.finish("Готово", detail: "Файлы сохранены в выбранной папке")
                }
            } catch {
                let diagnostics = self.recordError(error)
                self.append("Ошибка: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if self.cancelRequested {
                        self.finish("Остановлено")
                    } else if !self.errorDetails.isEmpty {
                        self.finish(
                            self.status,
                            detail: self.detail,
                            error: true,
                            modelAccessRequired: self.modelAccessRequired
                        )
                    } else {
                        let accessError = self.isModelAccessError(error)
                        self.errorDetails = diagnostics
                        self.finish(
                            "Не удалось обработать запись",
                            detail: self.friendlyError(error),
                            error: true,
                            modelAccessRequired: accessError
                        )
                    }
                }
            }
        }
    }

    func cancel() {
        guard running else { return }
        cancelRequested = true
        status = "Останавливаем…"
        detail = "Уже загруженные данные останутся в кэше"
        activeProcess?.terminate()
    }

    func clearModels() throws {
        if FileManager.default.fileExists(atPath: modelsDirectory.path) {
            try FileManager.default.removeItem(at: modelsDirectory)
        }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        status = "Загруженные данные удалены"
    }
}

private struct AppCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }
}

struct ContentView: View {
    @StateObject private var runtime = RuntimeController()
    @AppStorage("modelProfile") private var modelProfile = "balanced"
    @AppStorage("customModel") private var customModel = ""
    @AppStorage("language") private var language = "ru"
    @AppStorage("diarization") private var diarization = true
    @AppStorage("fastDiarization") private var fastDiarization = true
    @AppStorage("speakerCount") private var speakerCount = "2"
    @AppStorage("formatTXT") private var formatTXT = true
    @AppStorage("formatMD") private var formatMD = true
    @AppStorage("formatJSON") private var formatJSON = true
    @AppStorage("formatSRT") private var formatSRT = true
    @AppStorage("formatVTT") private var formatVTT = false
    @AppStorage("prompt") private var prompt = ""
    @State private var token = ""
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var message = ""
    @State private var confirmClear = false
    @State private var showingErrorDetails = false
    @State private var speakerNames: [String: String] = [:]
    @State private var profilePendingDeletion: VoiceProfile?

    private var selectedModel: String {
        switch modelProfile {
        case "quality": return "mlx-community/whisper-large-v3-mlx"
        case "custom": return customModel.isEmpty ? "mlx-community/whisper-large-v3-turbo" : customModel
        default: return "mlx-community/whisper-large-v3-turbo"
        }
    }

    private var runArguments: [String] {
        var args = ["--model", selectedModel, "--language", language]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        if diarization {
            args += ["--diarization-device", fastDiarization ? "mps" : "cpu"]
            if let count = Int(speakerCount) {
                args += ["--min-speakers", String(count), "--max-speakers", String(count)]
            }
        } else {
            args.append("--no-diarize")
        }
        let formats = [(formatTXT, "txt"), (formatMD, "md"), (formatJSON, "json"), (formatSRT, "srt"), (formatVTT, "vtt")]
        for (enabled, name) in formats where enabled { args += ["--format", name] }
        return args
    }

    private var hasOutputFormat: Bool {
        formatTXT || formatMD || formatJSON || formatSRT || formatVTT
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.16), Color.cyan.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()

            if runtime.isInstalled {
                workspace
            } else {
                welcome
            }
        }
        .frame(minWidth: 760, minHeight: 720)
        .tint(.indigo)
        .onAppear { token = KeychainToken.load(); runtime.refreshStatus() }
        .alert("Удалить загруженные модели?", isPresented: $confirmClear) {
            Button("Удалить", role: .destructive) {
                do { try runtime.clearModels() } catch { message = error.localizedDescription }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("При необходимости приложение сможет загрузить их снова.")
        }
        .alert("Что произошло", isPresented: $showingErrorDetails) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(runtime.errorDetails)
        }
        .alert("Забыть голос?", isPresented: Binding(
            get: { profilePendingDeletion != nil },
            set: { if !$0 { profilePendingDeletion = nil } }
        )) {
            Button("Забыть", role: .destructive) {
                do {
                    if let profile = profilePendingDeletion {
                        try runtime.removeVoiceProfile(id: profile.id)
                    }
                    message = "Профиль удалён"
                } catch {
                    message = "Не удалось удалить профиль"
                }
                profilePendingDeletion = nil
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Имя «\(profilePendingDeletion?.name ?? "")» больше не будет подставляться автоматически.")
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(.indigo.gradient).frame(width: 104, height: 104)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white)
            }.shadow(color: .indigo.opacity(0.3), radius: 24, y: 12)

            VStack(spacing: 10) {
                Text("Расшифровывайте записи на Mac")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Текст, спикеры и субтитры — локально на вашем компьютере.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            if runtime.running {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(runtime.status).foregroundStyle(.secondary)
                }
            } else {
                Button("Подготовить приложение") { runtime.installRuntime() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Это нужно сделать один раз. Понадобится подключение к интернету.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(60)
    }

    private var workspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.indigo.gradient).frame(width: 52, height: 52)
                        Image(systemName: "waveform.and.mic").font(.title2).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whisper Mac").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(runtime.status).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Скачать выбранный режим для офлайн-работы") {
                            saveToken()
                            runtime.prepareModels(asrModel: selectedModel, diarization: diarization, token: token)
                        }
                        .disabled(runtime.running || (diarization && token.isEmpty))
                        Button("Обновить компоненты приложения") { runtime.installRuntime() }
                        Divider()
                        Button("Показать загруженные данные") { NSWorkspace.shared.open(runtime.modelsDirectory) }
                        Button("Освободить место…", role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2)
                    }.menuStyle(.borderlessButton)
                }

                if runtime.running {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(runtime.status, systemImage: "waveform")
                                .font(.headline)
                            Spacer()
                            Text(runtime.elapsedText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: runtime.progress, total: 1)
                            .progressViewStyle(.linear)
                        HStack(spacing: 12) {
                            Text(runtime.detail.isEmpty ? "Пожалуйста, подождите…" : runtime.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Остановить", role: .cancel) { runtime.cancel() }
                        }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.indigo.opacity(0.22), lineWidth: 1)
                    }
                }

                if !runtime.running && !runtime.detail.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: runtime.hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(runtime.hasError ? .orange : .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(runtime.hasError ? "Нужно ваше действие" : runtime.status)
                                .font(.headline)
                            Text(runtime.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if runtime.modelAccessRequired {
                            Button("Открыть доступ") {
                                NSWorkspace.shared.open(
                                    URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!
                                )
                            }
                        }
                        if !runtime.errorDetails.isEmpty {
                            Button("Подробнее") { showingErrorDetails = true }
                        }
                    }
                    .padding(16)
                    .background(
                        (runtime.hasError ? Color.orange : Color.green).opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }

                AppCard("Запись", icon: "doc.badge.plus") {
                    Button { chooseInput() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: inputURL == nil ? "plus.circle.fill" : "waveform")
                                .font(.title2).foregroundStyle(.indigo)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(inputURL?.lastPathComponent ?? "Выберите аудио или видео")
                                    .font(.headline).foregroundStyle(.primary)
                                Text(inputURL == nil ? "MP3, M4A, WAV, MP4 и другие форматы" : "Нажмите, чтобы выбрать другой файл")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }

                HStack(alignment: .top, spacing: 18) {
                    AppCard("Качество и язык", icon: "slider.horizontal.3") {
                        Picker("Качество", selection: $modelProfile) {
                            Text("Быстрее").tag("balanced")
                            Text("Точнее").tag("quality")
                            Text("Своя").tag("custom")
                        }.pickerStyle(.segmented)
                        if modelProfile == "custom" {
                            TextField("Адрес или путь к модели", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("Язык записи", selection: $language) {
                            Text("Русский").tag("ru")
                            Text("Определить автоматически").tag("auto")
                            Text("English").tag("en")
                            Text("Українська").tag("uk")
                            Text("Deutsch").tag("de")
                            Text("Français").tag("fr")
                        }
                        TextField("Имена и специальные слова (необязательно)", text: $prompt)
                            .textFieldStyle(.roundedBorder)
                    }

                    AppCard("Участники", icon: "person.2.wave.2") {
                        Toggle("Разделять текст по голосам", isOn: $diarization)
                        if diarization {
                            Toggle("Быстрое разделение голосов", isOn: $fastDiarization)
                            Picker("Сколько участников", selection: $speakerCount) {
                                Text("Определить автоматически").tag("auto")
                                ForEach(2...20, id: \.self) { count in
                                    Text(speakerCountTitle(count)).tag(String(count))
                                }
                            }
                            SecureField("Ключ доступа", text: $token)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Text("Нужен для загрузки разделения голосов")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Сохранить") { saveToken() }
                            }
                            Button("Проверить доступ и загрузить") {
                                saveToken()
                                runtime.prepareModels(
                                    asrModel: selectedModel,
                                    diarization: true,
                                    token: token
                                )
                            }
                            .disabled(runtime.running || token.isEmpty)
                        }
                    }
                }

                if !runtime.detectedSpeakers.isEmpty {
                    AppCard("Голоса в этой записи", icon: "person.wave.2") {
                        Text("Дайте участнику имя — в следующих записях приложение попробует узнать его автоматически.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        ForEach(runtime.detectedSpeakers) { speaker in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill((speaker.profileId == nil ? Color.indigo : Color.green).opacity(0.13))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: speaker.profileId == nil ? "person.fill" : "checkmark")
                                        .foregroundStyle(speaker.profileId == nil ? .indigo : .green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(speaker.displayName).font(.headline)
                                    Text(speakerDuration(speaker.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if speaker.profileId != nil {
                                    Label("Запомнен", systemImage: "checkmark.circle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.green)
                                } else {
                                    TextField("Имя участника", text: speakerNameBinding(speaker.label))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 230)
                                    Button("Запомнить") {
                                        do {
                                            try runtime.rememberSpeaker(
                                                label: speaker.label,
                                                name: speakerNames[speaker.label] ?? ""
                                            )
                                            speakerNames[speaker.label] = ""
                                            message = "Голос сохранён для следующих записей"
                                        } catch {
                                            message = "Не удалось сохранить голос"
                                        }
                                    }
                                    .disabled((speakerNames[speaker.label] ?? "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(.vertical, 3)
                        }

                        Text("Аудио не сохраняется — на компьютере остаётся только компактный профиль голоса.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !runtime.voiceProfiles.isEmpty {
                    AppCard("Знакомые голоса", icon: "person.crop.circle.badge.checkmark") {
                        ForEach(runtime.voiceProfiles) { profile in
                            HStack {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.indigo)
                                Text(profile.name).font(.headline)
                                Spacer()
                                Button(role: .destructive) {
                                    profilePendingDeletion = profile
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Забыть этот голос")
                            }
                        }
                    }
                }

                AppCard("Результат", icon: "square.and.arrow.down") {
                    HStack(spacing: 18) {
                        Toggle("Текст", isOn: $formatTXT)
                        Toggle("Markdown", isOn: $formatMD)
                        Toggle("Данные", isOn: $formatJSON)
                        Toggle("SRT", isOn: $formatSRT)
                        Toggle("VTT", isOn: $formatVTT)
                    }.toggleStyle(.checkbox)

                    Button { chooseOutput() } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.indigo)
                            Text(outputURL?.path ?? "Выберите папку для результатов")
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                            Spacer()
                            Text("Выбрать").foregroundStyle(.indigo)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }

                HStack {
                    if !message.isEmpty {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        guard let inputURL, let outputURL else { return }
                        saveToken()
                        runtime.transcribe(input: inputURL, output: outputURL, arguments: runArguments, token: token)
                    } label: {
                        Label("Создать расшифровку", systemImage: "sparkles")
                            .frame(minWidth: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(runtime.running || inputURL == nil || outputURL == nil || !hasOutputFormat || (diarization && token.isEmpty))
                }
            }.padding(24)
        }
    }

    private func saveToken() {
        do { try KeychainToken.save(token); message = token.isEmpty ? "Ключ удалён" : "Ключ сохранён" }
        catch { message = "Не удалось сохранить ключ" }
    }

    private func speakerCountTitle(_ count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        let noun: String
        if (11...14).contains(lastTwo) {
            noun = "участников"
        } else if last == 1 {
            noun = "участник"
        } else if (2...4).contains(last) {
            noun = "участника"
        } else {
            noun = "участников"
        }
        return "\(count) \(noun)"
    }

    private func speakerDuration(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let remainder = rounded % 60
        return minutes > 0
            ? "В записи: \(minutes) мин \(remainder) сек"
            : "В записи: \(remainder) сек"
    }

    private func speakerNameBinding(_ label: String) -> Binding<String> {
        Binding(
            get: { speakerNames[label] ?? "" },
            set: { speakerNames[label] = $0 }
        )
    }

    private func chooseInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { inputURL = panel.url }
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { outputURL = panel.url }
    }
}

@main
struct WhisperMacApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
