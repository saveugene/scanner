// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScannerDevice: Decodable, Identifiable {
    let id: String
    let vendor: String
    let model: String
}

struct OptionValues: Decodable {
    var values: [Int]?
    var max: Double?
}

struct ScannerOptions: Decodable {
    let resolution: OptionValues
    let width: OptionValues
    let height: OptionValues
    let status: HardwareState?
}

struct HardwareState: Decodable {
    let code: Int?
    let message: String?
}

private final class ErrorStream: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    func append(_ chunk: Data, progress: @escaping (Double) -> Void) {
        lock.lock()
        data.append(chunk)
        pending += String(decoding: chunk, as: UTF8.self)
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            if line.hasPrefix("PROGRESS "), let value = Double(line.dropFirst(9)) {
                progress(value / 100)
            }
        }
        lock.unlock()
    }
    var message: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("PROGRESS ") }.suffix(8).joined(separator: "\n")
    }
}

@MainActor final class ScanModel: ObservableObject {
    @Published var devices: [ScannerDevice] = []
    @Published var selectedDevice = ""
    @Published var resolutions = [75, 100, 150, 200, 300, 600]
    @Published var dpi = 300
    @Published var mode = "Color"
    @Published var format = "pdf"
    @Published var fullGlass = false
    @Published var busy = false
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var status = "Connect the printer by USB and turn it on."
    @Published var lastFile: URL?
    @Published var error: String?
    private var maxWidth = 215.9
    private var maxHeight = 296.926
    private var process: Process?
    private var cancelled = false

    private var executable: URL {
        Bundle.main.resourceURL!.appendingPathComponent("runtime/bin/hp-scan")
    }

    func run(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        let task = Process()
        let output = Pipe(), errors = Pipe()
        let stream = ErrorStream()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = errors
        process = task
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stream.append(chunk) { value in
                    DispatchQueue.main.async { self.progress = value }
                }
            }
        }
        do {
            try task.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            process = nil
            completion(.failure(error))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            errors.fileHandleForReading.readabilityHandler = nil
            stream.append(errors.fileHandleForReading.readDataToEndOfFile()) { _ in }
            let message = stream.message
            DispatchQueue.main.async {
                self.process = nil
                if task.terminationStatus == 0 {
                    completion(.success(result))
                } else {
                    completion(.failure(NSError(domain: "HPScan", code: Int(task.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "The driver exited with error \(task.terminationStatus)." : message])))
                }
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        status = "Searching for scanners…"
        run(["list"]) { result in
            switch result {
            case .success(let data):
                do {
                    self.devices = try JSONDecoder().decode([ScannerDevice].self, from: data)
                    self.selectedDevice = self.devices.first(where: { $0.id.localizedCaseInsensitiveContains("PSC_1400") })?.id ?? self.devices.first?.id ?? ""
                    if self.devices.isEmpty {
                        self.status = "No scanner found. Check the power and USB cable."
                        self.busy = false
                    } else {
                        self.loadOptions()
                    }
                } catch { self.finishError(error) }
            case .failure(let error): self.finishError(error)
            }
        }
    }

    func loadOptions() {
        guard !selectedDevice.isEmpty else { return }
        busy = true
        status = "Checking the scanner…"
        run(["options", "--device", selectedDevice]) { result in
            self.busy = false
            switch result {
            case .success(let data):
                do {
                    let options = try JSONDecoder().decode(ScannerOptions.self, from: data)
                    if let supported = options.resolution.values, !supported.isEmpty {
                        self.resolutions = supported.filter { $0 >= 75 && $0 <= 600 }
                        if !self.resolutions.contains(self.dpi) { self.dpi = self.resolutions.first ?? 300 }
                    }
                    self.maxWidth = options.width.max ?? 215.9
                    self.maxHeight = options.height.max ?? 296.926
                    if let state = options.status, let code = state.code, code != 1000, code != 1046 {
                        self.status = state.message ?? "Printer status: \(code)"
                    } else {
                        self.status = "Scanner ready. Place the original face down on the glass."
                    }
                } catch { self.finishError(error) }
            case .failure(let error): self.finishError(error)
            }
        }
    }

    func scan() {
        guard !busy, !selectedDevice.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save Scan"
        let types: [String: UTType] = ["pdf": .pdf, "png": .png, "jpg": .jpeg, "tiff": .tiff]
        panel.allowedContentTypes = [types[format]!]
        panel.canCreateDirectories = true
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Scan-\(date.string(from: Date())).\(format)"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; scanning = true; cancelled = false; progress = 0
        status = "Scanning… Please wait until the scanner stops."
        let width = fullGlass ? maxWidth : min(210, maxWidth)
        let height = min(297, maxHeight)
        // NSSavePanel has already confirmed replacement if the file exists.
        run(["scan", "--device", selectedDevice, "--dpi", String(dpi), "--mode", mode,
             "--width", String(width), "--height", String(height), "--output", destination.path, "--overwrite"]) { result in
            self.busy = false; self.scanning = false
            switch result {
            case .success:
                self.progress = 1
                self.lastFile = destination
                self.status = "Saved: \(destination.lastPathComponent)"
                NSWorkspace.shared.open(destination)
            case .failure(let error):
                if self.cancelled { self.status = "Scan cancelled." }
                else { self.finishError(error) }
            }
        }
    }

    func cancel() {
        cancelled = true
        status = "Stopping the scanner…"
        guard let task = process else { return }
        task.terminate()
        // Some legacy hpaio reads never return from a USB timeout. Give normal
        // driver cleanup a chance, then release the child and its USB handles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    func finishError(_ error: Error) {
        busy = false; scanning = false
        status = "The operation could not be completed."
        self.error = error.localizedDescription
    }
}

struct ContentView: View {
    @StateObject private var model = ScanModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "scanner.fill")
                    .font(.system(size: 36)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HP Scan").font(.largeTitle.bold())
                    Text("PSC 1410 · USB scanning").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh connection").disabled(model.busy)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    if model.devices.count > 1 {
                        Picker("Scanner", selection: $model.selectedDevice) {
                            ForEach(model.devices) { device in Text(device.model).tag(device.id) }
                        }
                        .onChange(of: model.selectedDevice) { _, _ in model.loadOptions() }
                    }
                    HStack {
                        Label(model.selectedDevice.isEmpty ? "Printer not connected" : "HP PSC 1400 series", systemImage: "cable.connector")
                        Spacer()
                        Text(model.selectedDevice.isEmpty ? "Offline" : "USB").foregroundStyle(.secondary)
                    }
                    Divider()
                    Picker("Resolution", selection: $model.dpi) {
                        ForEach(model.resolutions, id: \.self) { dpi in
                            Text("\(dpi) DPI\(dpi == 300 ? " · documents" : dpi == 600 ? " · photos" : "")").tag(dpi)
                        }
                    }
                    Picker("Color mode", selection: $model.mode) {
                        Text("Color").tag("Color")
                        Text("Grayscale").tag("Gray")
                    }
                    Picker("Scan area", selection: $model.fullGlass) {
                        Text("A4").tag(false)
                        Text("Full glass").tag(true)
                    }
                    Picker("File format", selection: $model.format) {
                        Text("PDF").tag("pdf")
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpg")
                        Text("TIFF").tag("tiff")
                    }
                }.padding(12)
            }.disabled(model.busy)
            VStack(alignment: .leading, spacing: 10) {
                if model.scanning {
                    if model.progress > 0 { ProgressView(value: model.progress) }
                    else { ProgressView().controlSize(.small) }
                } else if model.busy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            HStack {
                if let file = model.lastFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Spacer()
                if model.scanning {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Scan…") { model.scan() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || model.selectedDevice.isEmpty)
                }
            }
        }
        .padding(28).frame(width: 490)
        .onAppear { model.refresh() }
        .alert("Scanning Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@main struct HPScanApp: App {
    init() {
        // Keep system-provided dialogs and menus in the app's only language.
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    }

    var body: some Scene {
        WindowGroup("HP Scan") { ContentView().environment(\.locale, Locale(identifier: "en")) }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
