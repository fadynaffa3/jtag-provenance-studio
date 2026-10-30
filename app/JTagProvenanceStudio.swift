// JTag Provenance Studio: a window around tools/detect_ai_provenance.py.
// Add files, choose what to do (remove AI tags, sign with Content Credentials), get the output copies.
// Signing always uses the identity of the person using this Mac; AI content found is always declared.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Tools live inside the app bundle (Contents/Resources); fall back to the repo checkout for dev builds.
let resourcesDir: URL = Bundle.main.resourceURL
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ai-provenance/tools")
let python  = resourcesDir.appendingPathComponent("venv/bin/python3")
let script  = resourcesDir.appendingPathComponent("detect_ai_provenance.py")
let binDir  = resourcesDir.appendingPathComponent("bin")
let accepted = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "heic", "avif", "gif", "bmp", "jp2", "ai", "pdf"]

struct OutputFile: Identifiable {
    let id = UUID()
    let path: String
    let notes: [String]
    let remainingTags: Int
    let signed: Bool
    var watermarked: Bool { notes.contains { $0.hasPrefix("invisible watermark") } }
    var clean: Bool { remainingTags == 0 && !watermarked }
}

@MainActor
final class Studio: ObservableObject {
    @Published var files: [URL] = []
    @Published var strip = true
    @Published var sign = true
    @Published var watermarks = true
    @Published var rename = true
    @Published var outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ai-provenance/output")
    @Published var log = ""
    @Published var running = false
    @Published var results: [OutputFile] = []
    @Published var signer: String?

    init() { refreshIdentity() }

    func add(_ urls: [URL]) {
        for url in urls where accepted.contains(url.pathExtension.lowercased()) && !files.contains(url) {
            files.append(url)
        }
    }

    func refreshIdentity() {
        let out = runSync(["--show-identity"])
        if let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            signer = obj["name"] as? String
        } else {
            signer = nil
        }
        if signer == nil { sign = false }
    }

    func createIdentity(_ name: String) -> String? {
        let out = runSync(["--create-identity", name])
        refreshIdentity()
        if signer == nil { return out.isEmpty ? "Setup failed." : out }
        sign = true
        return nil
    }

    func run() {
        guard !files.isEmpty, strip || sign else { return }
        running = true
        results = []
        log = ""
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("provenance-\(UUID().uuidString).json")
        var args = files.map(\.path) + ["--out", outDir.path, "--json", report.path]
        if strip { args.append("--strip") }
        if sign { args.append("--sign") }
        if rename { args.append("--rename") }
        if !watermarks { args.append("--no-watermarks") }

        let process = makeProcess(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.log += text }
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.log += rest
                if proc.terminationStatus != 0 { self.log += "\nStopped with an error (code \(proc.terminationStatus)).\n" }
                self.results = Self.readResults(report)
                try? FileManager.default.removeItem(at: report)
                self.running = false
            }
        }
        do { try process.run() } catch {
            log = "Could not start the tool: \(error.localizedDescription)\nLooked for engine at \(script.path)"
            running = false
        }
    }

    static func readResults(_ url: URL) -> [OutputFile] {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.filter { ($0["kind"] as? String) == "output" }.map { row in
            let notes = row["notes"] as? [String] ?? []
            let hits = (row["metadata_hits"] as? [String: Any])?.keys.filter { !$0.lowercased().contains("c2pa") && !$0.lowercased().contains("jumbf") }.count ?? 0
            return OutputFile(path: row["path"] as? String ?? "?", notes: notes, remainingTags: hits,
                              signed: notes.contains { $0.hasPrefix("signed by") })
        }
    }

    private func makeProcess(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        // Prefer bundled binaries; fall back to Homebrew for dev builds without a full bundle.
        let fallback = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = binDir.path + ":" + fallback + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // exiftool is a Perl script; point it at its bundled lib tree (or Homebrew's as fallback).
        let exiftoolLib = resourcesDir.appendingPathComponent("exiftool-lib").path
        env["PERLLIB"] = FileManager.default.fileExists(atPath: exiftoolLib)
            ? exiftoolLib : "/opt/homebrew/Cellar/exiftool/\(installedExiftoolVersion())/libexec/lib"
        env["PYTHONUNBUFFERED"] = "1"
        // Point Python at the bundled stdlib + site-packages so it runs without any system Python.
        let stdlib = resourcesDir.appendingPathComponent("python3.14-stdlib").path
        let sitePkgs = resourcesDir.appendingPathComponent("venv/lib/python3.14/site-packages").path
        let fwkDylib = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.14/Python").path
        if FileManager.default.fileExists(atPath: stdlib) {
            env["PYTHONPATH"] = stdlib + ":" + sitePkgs
        }
        // Rewrite pyvenv.cfg whenever the bundled framework exists (covers stdlib-present and
        // stdlib-absent bundles alike). Build wrote placeholder paths; this makes them absolute.
        if FileManager.default.fileExists(atPath: fwkDylib) {
            fixPyvenvCfg()
        }
        process.environment = env
        process.currentDirectoryURL = resourcesDir
        return process
    }

    private func fixPyvenvCfg() {
        let cfg = resourcesDir.appendingPathComponent("venv/pyvenv.cfg")
        let pythonBin = python.path
        let content = """
home = \(python.deletingLastPathComponent().path)
include-system-site-packages = false
version = 3.14.6
executable = \(pythonBin)
"""
        try? content.write(to: cfg, atomically: true, encoding: .utf8)
    }

    private func installedExiftoolVersion() -> String {
        let dir = URL(fileURLWithPath: "/opt/homebrew/Cellar/exiftool")
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.last ?? "13.55_1"
    }

    private func runSync(_ args: [String]) -> String {
        let process = makeProcess(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct IdentitySheet: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var name = NSFullUserName()
    @State private var confirmed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your signing identity").font(.title2.bold())
            Text("Content Credentials you add will be signed in this name. The private key is created on this Mac and never leaves it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Your full name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("This is my own name, and I'm the only one who signs with this Mac account", isOn: $confirmed)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    error = studio.createIdentity(name)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmed || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ContentView: View {
    @StateObject private var studio = Studio()
    @State private var showIdentity = false
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            filesSection
            optionsSection
            HStack {
                Button(studio.running ? "Working…" : "Process \(studio.files.count) file\(studio.files.count == 1 ? "" : "s")") { studio.run() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(studio.running || studio.files.isEmpty || !(studio.strip || studio.sign))
                if studio.running { ProgressView().controlSize(.small) }
                Spacer()
                if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("v\(v)").foregroundStyle(.secondary).font(.caption)
                }
                Button("Open Output Folder") { NSWorkspace.shared.open(studio.outDir) }
            }
            if !studio.results.isEmpty { resultsSection }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(studio.log.isEmpty ? "Details appear here while files are processed." : studio.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(studio.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: studio.log) { proxy.scrollTo("end") }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 640)
        .sheet(isPresented: $showIdentity) { IdentitySheet(studio: studio) }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                Button("Add Files…") { pickFiles() }
                Button("Clear") { studio.files = [] }.disabled(studio.files.isEmpty)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.5))
                if studio.files.isEmpty {
                    Text("Drop images, .ai or .pdf files here").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(studio.files, id: \.self) { url in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                                Text(url.lastPathComponent)
                                Spacer()
                                Button { studio.files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .padding(4)
                }
            }
            .frame(height: 140)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in studio.add([url]) } }
                    }
                }
                return true
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to do").font(.headline)
            Toggle("Remove AI metadata tags", isOn: $studio.strip)
            Toggle("Rename files with AI-generator names (e.g. \"ChatGPT Image …\")", isOn: $studio.rename)
            HStack {
                Toggle("Add Content Credentials", isOn: $studio.sign).disabled(studio.signer == nil)
                if let signer = studio.signer {
                    Text("signed as \(signer)").foregroundStyle(.secondary)
                } else {
                    Button("Set Up Signing Identity…") { showIdentity = true }
                }
            }

            Toggle("Check invisible watermarks (slower, more thorough AI detection)", isOn: $studio.watermarks)
            HStack {
                Text("Output folder:")
                Text(studio.outDir.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { pickOutput() }
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output").font(.headline)
            ForEach(studio.results) { file in
                HStack(alignment: .top) {
                    Image(systemName: file.clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(file.clean ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text((file.path as NSString).lastPathComponent).bold()
                        ForEach(file.notes, id: \.self) { note in
                            Text(note).font(.caption)
                                .foregroundStyle(note.hasPrefix("invisible watermark") ? .orange : .secondary)
                        }
                        if file.remainingTags > 0 { Text("\(file.remainingTags) AI tags still present").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                }
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = accepted.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { studio.add(panel.urls) }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { studio.outDir = url }
    }
}

@main
struct JTagProvenanceStudioApp: App {
    var body: some Scene {
        WindowGroup("JTag Provenance Studio") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
