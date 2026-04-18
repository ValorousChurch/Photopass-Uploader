import Foundation
import SwiftUI
import AppKit

struct UploadConfig {
    var rockURL = "https://rock.valorouschurch.com"
    var rockAPIKey = ""
    var fileTypeGUID = "db67dde1-e078-4b1b-848f-986110a804b0"
    var workflowTypeID = "256"
    var fileAttributeKey = "Image"
    var codeAttributeKey = "Code"
}

@MainActor
final class PhotoPassViewModel: ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var statusText = "Choose a folder to begin."
    @Published var logText = ""
    @Published var isRunning = false
    @Published var progressCurrent = 0
    @Published var progressTotal = 0
    @Published var progressText = ""
    @Published var dryRunEnabled = false
    @Published var verboseEnabled = false
    @Published var showConfirmationPrompt = false
    @Published var showUploadSettings = false
    @Published var uploadConfig = UploadConfig()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var wasCancelled = false
    private var awaitingConfirmation = false

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("photo_pass.swift")
    }

    private var uploadScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("upload_photos.sh")
    }

    private var uploadConfigURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("upload_config.env")
    }

    var canRun: Bool {
        selectedFolderURL != nil && !isRunning
    }

    var progressFraction: Double? {
        guard progressTotal > 0 else { return nil }
        return Double(progressCurrent) / Double(progressTotal)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the folder of photos to process."

        if panel.runModal() == .OK {
            selectedFolderURL = panel.url
            statusText = "Selected \(panel.url?.lastPathComponent ?? "folder")."
        }
    }

    func loadUploadConfig() {
        uploadConfig = readUploadConfig()
    }

    func openUploadSettings() {
        loadUploadConfig()
        showUploadSettings = true
    }

    func saveUploadSettings() {
        do {
            try writeUploadConfig(uploadConfig)
            statusText = "Upload settings saved."
            showUploadSettings = false
        } catch {
            statusText = "Failed to save upload settings."
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    func runSelectedMode() {
        run()
    }

    func runUpload() {
        guard let folderURL = selectedFolderURL else { return }
        guard !isRunning else { return }

        let dryRun = dryRunEnabled
        let verbose = verboseEnabled
        let savedConfig = readUploadConfig()

        let missingFields = missingUploadConfigFields(savedConfig)
        if !missingFields.isEmpty {
            statusText = "Upload settings are required."
            appendLog("Error: Missing upload settings: \(missingFields.joined(separator: ", ")). Open Upload Settings to configure them.")
            return
        }

        var arguments = [uploadScriptURL.path]
        if dryRun {
            arguments.append("--dry-run")
        }
        if verbose {
            arguments.append("--verbose")
        }
        arguments.append(folderURL.path)

        launchProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: arguments,
            environment: ["UPLOAD_CONFIG_FILE": uploadConfigURL.path],
            startedText: dryRun ? "Upload dry run started..." : "Upload started...",
            successText: dryRun ? "Upload dry run complete." : "Upload complete."
        )
    }

    func stopRun() {
        guard let process, isRunning else { return }
        wasCancelled = true
        statusText = "Stopping..."
        appendLog("Stopping run...")
        process.terminate()
    }

    private func run() {
        guard let folderURL = selectedFolderURL else { return }
        guard !isRunning else { return }

        let dryRun = dryRunEnabled
        let verbose = verboseEnabled

        var arguments = ["swift", scriptURL.path, folderURL.path]
        if dryRun {
            arguments.append("--dry-run")
        }
        if verbose {
            arguments.append("--verbose")
        }

        launchProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments,
            environment: [:],
            startedText: dryRun ? "Sort dry run started..." : "Processing started...",
            successText: dryRun ? "Sort dry run complete." : "Processing complete."
        )
    }

    private func launchProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        startedText: String,
        successText: String
    ) {
        resetOutput()
        isRunning = true
        wasCancelled = false
        statusText = startedText

        let process = Process()
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.consumeOutput(text, isError: false)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.consumeOutput(text, isError: true)
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self?.flushBuffers()
                self?.isRunning = false
                self?.process = nil
                self?.stdinPipe = nil
                self?.awaitingConfirmation = false
                self?.showConfirmationPrompt = false

                if self?.wasCancelled == true {
                    self?.statusText = "Run stopped."
                    self?.appendLog("Run stopped by user.")
                } else if finishedProcess.terminationStatus == 0 {
                    self?.statusText = successText
                } else {
                    self?.statusText = "Run failed with exit code \(finishedProcess.terminationStatus)."
                }
            }
        }

        self.process = process
        self.stdinPipe = stdinPipe

        do {
            try process.run()
        } catch {
            isRunning = false
            statusText = "Failed to start process."
            self.stdinPipe = nil
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    func confirmProcessing() {
        sendConfirmation("y\n")
        showConfirmationPrompt = false
        awaitingConfirmation = false
        statusText = "Moving files..."
    }

    func cancelProcessingPrompt() {
        sendConfirmation("n\n")
        showConfirmationPrompt = false
        awaitingConfirmation = false
        statusText = "Cancelling..."
    }

    private func resetOutput() {
        logText = ""
        stdoutBuffer = ""
        stderrBuffer = ""
        progressCurrent = 0
        progressTotal = 0
        progressText = ""
        wasCancelled = false
        awaitingConfirmation = false
        showConfirmationPrompt = false
    }

    private func consumeOutput(_ text: String, isError: Bool) {
        if isError {
            stderrBuffer += text
            processBufferedLines(isError: true)
            return
        }

        stdoutBuffer += text.replacingOccurrences(of: "\r", with: "\n")
        processBufferedLines(isError: false)
        processBufferedProgressRemainder()
    }

    private func processBufferedLines(isError: Bool) {
        let buffer = isError ? stderrBuffer : stdoutBuffer
        let lines = buffer.components(separatedBy: "\n")
        guard lines.count > 1 else { return }

        let completeLines = lines.dropLast()
        let remainder = lines.last ?? ""

        if isError {
            stderrBuffer = remainder
        } else {
            stdoutBuffer = remainder
        }

        for rawLine in completeLines {
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let line = rawLine.trimmingCharacters(in: .newlines)
            handleLine(line, isError: isError)
        }
    }

    private func processBufferedProgressRemainder() {
        let line = stdoutBuffer.trimmingCharacters(in: .newlines)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if updateProgress(from: line) {
            stdoutBuffer = ""
        }
    }

    private func flushBuffers() {
        let stdoutLine = stdoutBuffer.trimmingCharacters(in: .newlines)
        if !stdoutLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleLine(stdoutLine, isError: false)
        }
        stdoutBuffer = ""

        let stderrLine = stderrBuffer.trimmingCharacters(in: .newlines)
        if !stderrLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleLine(stderrLine, isError: true)
        }
        stderrBuffer = ""
    }

    private func handleLine(_ line: String, isError: Bool) {
        if !isError, line == "Continue with moving files? [y/N]" {
            awaitingConfirmation = true
            showConfirmationPrompt = true
            statusText = "Waiting for confirmation..."
            appendLog(line)
            return
        }

        if !isError, updateProgress(from: line) {
            if line.hasPrefix("Uploading ") {
                appendLog(line)
            }
            return
        }

        appendLog(isError ? "Error: \(line)" : line)
    }

    private func updateProgress(from line: String) -> Bool {
        if let progress = parseProgress(line, prefix: "Scanning ", suffix: " photos") {
            progressCurrent = progress.current
            progressTotal = progress.total
            progressText = "Scanning \(progress.current) of \(progress.total) photos"
            statusText = "\(progressText)..."
            return true
        }

        if let progress = parseProgress(line, prefix: "Uploading ", suffix: " images") {
            progressCurrent = progress.current
            progressTotal = progress.total
            progressText = "Uploading \(progress.current) of \(progress.total) images"
            statusText = "\(progressText)..."
            return true
        }

        return false
    }

    private func parseProgress(_ line: String, prefix: String, suffix: String) -> (current: Int, total: Int)? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            return nil
        }

        let content = line
            .replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: suffix, with: "")
        let pieces = content.components(separatedBy: " of ")
        guard pieces.count == 2,
              let current = Int(pieces[0]),
              let total = Int(pieces[1]) else {
            return nil
        }

        return (current, total)
    }

    private func appendLog(_ line: String) {
        if logText.isEmpty {
            logText = line
        } else {
            logText += "\n\(line)"
        }
    }

    private func sendConfirmation(_ response: String) {
        guard let data = response.data(using: .utf8) else { return }
        stdinPipe?.fileHandleForWriting.write(data)
    }

    private func readUploadConfig() -> UploadConfig {
        var config = UploadConfig()
        guard let contents = try? String(contentsOf: uploadConfigURL, encoding: .utf8) else {
            return config
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = unquoteEnvValue(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))

            switch key {
            case "ROCK_URL":
                config.rockURL = value
            case "ROCK_API_KEY":
                config.rockAPIKey = value
            case "FILE_TYPE_GUID":
                config.fileTypeGUID = value
            case "WORKFLOW_TYPE_ID":
                config.workflowTypeID = value
            case "FILE_ATTRIBUTE_KEY":
                config.fileAttributeKey = value
            case "CODE_ATTRIBUTE_KEY":
                config.codeAttributeKey = value
            default:
                continue
            }
        }

        return config
    }

    private func missingUploadConfigFields(_ config: UploadConfig) -> [String] {
        var missing: [String] = []

        if config.rockURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("ROCK_URL")
        }
        if config.rockAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("ROCK_API_KEY")
        }
        if config.fileTypeGUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("FILE_TYPE_GUID")
        }
        if config.workflowTypeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("WORKFLOW_TYPE_ID")
        }
        if config.fileAttributeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("FILE_ATTRIBUTE_KEY")
        }
        if config.codeAttributeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("CODE_ATTRIBUTE_KEY")
        }

        return missing
    }

    private func writeUploadConfig(_ config: UploadConfig) throws {
        let contents = """
        ROCK_URL=\(quoteEnvValue(config.rockURL))
        ROCK_API_KEY=\(quoteEnvValue(config.rockAPIKey))
        FILE_TYPE_GUID=\(quoteEnvValue(config.fileTypeGUID))
        WORKFLOW_TYPE_ID=\(quoteEnvValue(config.workflowTypeID))
        FILE_ATTRIBUTE_KEY=\(quoteEnvValue(config.fileAttributeKey))
        CODE_ATTRIBUTE_KEY=\(quoteEnvValue(config.codeAttributeKey))
        """

        try contents.write(to: uploadConfigURL, atomically: true, encoding: .utf8)
    }

    private func quoteEnvValue(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func unquoteEnvValue(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }

        let inner = String(value.dropFirst().dropLast())
        var result = ""
        var escaping = false

        for character in inner {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }

        if escaping {
            result.append("\\")
        }

        return result
    }
}

struct ContentView: View {
    @StateObject private var viewModel = PhotoPassViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Photo Pass")
                .font(.title.bold())

            HStack(spacing: 12) {
                Button("Choose Folder") {
                    viewModel.chooseFolder()
                }

                Button("Upload Settings") {
                    viewModel.openUploadSettings()
                }

                Text(viewModel.selectedFolderURL?.path ?? "No folder selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                Toggle("Dry Run", isOn: $viewModel.dryRunEnabled)
                    .toggleStyle(.checkbox)

                Toggle("Verbose", isOn: $viewModel.verboseEnabled)
                    .toggleStyle(.checkbox)

                Button(viewModel.dryRunEnabled ? "Sort Dry Run" : "Sort Photos") {
                    viewModel.runSelectedMode()
                }
                .disabled(!viewModel.canRun)

                Button(viewModel.dryRunEnabled ? "Upload Dry Run" : "Upload Photos") {
                    viewModel.runUpload()
                }
                .disabled(!viewModel.canRun)

                Button("Stop") {
                    viewModel.stopRun()
                }
                .disabled(!viewModel.isRunning)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let fraction = viewModel.progressFraction {
                    ProgressView(value: fraction)
                } else if viewModel.isRunning {
                    ProgressView()
                } else {
                    ProgressView(value: 0)
                        .opacity(0)
                }

                Text(viewModel.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !viewModel.progressText.isEmpty {
                    Text(viewModel.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 46)

            TextEditor(text: $viewModel.logText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .disabled(true)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
        .alert("Continue with moving files?", isPresented: $viewModel.showConfirmationPrompt) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelProcessingPrompt()
            }

            Button("Move Files") {
                viewModel.confirmProcessing()
            }
        } message: {
            Text("The scan is complete. Continue with moving the files?")
        }
        .sheet(isPresented: $viewModel.showUploadSettings) {
            UploadSettingsView(viewModel: viewModel)
        }
    }
}

struct UploadSettingsView: View {
    @ObservedObject var viewModel: PhotoPassViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Upload Settings")
                .font(.title2.bold())

            LabeledContent("Rock URL") {
                TextField("https://rock.example.com", text: $viewModel.uploadConfig.rockURL)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Rock API Key") {
                SecureField("Required for upload", text: $viewModel.uploadConfig.rockAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("File Type GUID") {
                TextField("File type GUID", text: $viewModel.uploadConfig.fileTypeGUID)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Workflow Type ID") {
                TextField("Workflow type ID", text: $viewModel.uploadConfig.workflowTypeID)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("File Attribute Key") {
                TextField("Image", text: $viewModel.uploadConfig.fileAttributeKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Code Attribute Key") {
                TextField("Code", text: $viewModel.uploadConfig.codeAttributeKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    viewModel.showUploadSettings = false
                }

                Button("Save") {
                    viewModel.saveUploadSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PhotoPassGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
