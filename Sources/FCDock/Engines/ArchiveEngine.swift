import Foundation

/// Archives are unpacked and packed again with macOS's own tools: bsdtar (libarchive) reads ZIP, 7z,
/// RAR, tar variants, CAB and ISO and writes 7z and tar variants; ditto writes ZIP; hdiutil opens DMGs.
struct ArchiveEngine: Engine {
    let name = "Archives"

    private static let readable: Set<FileFormat> = [.zip, .rar, .sevenZip, .tar, .tarGz, .tarBz2, .tarXz, .tarZst, .cab, .iso, .dmg]
    private static let writable: [FileFormat: [String]] = [
        .tar: [],
        .tarGz: ["-z"],
        .tarBz2: ["-j"],
        .tarXz: ["-J"],
        .tarZst: ["--zstd"],
        .sevenZip: ["--format", "7zip"],
        .zip: [],
    ]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        from != to && Self.readable.contains(from) && Self.writable[to] != nil ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        let contents = output.deletingLastPathComponent().appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        if from == .dmg {
            try await Self.copyDiskImage(input, to: contents)
        } else if from == .zip {
            try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", input.path, contents.path])
        } else {
            try await ProcessRunner.run("/usr/bin/tar", ["-xf", input.path, "-C", contents.path])
        }

        // Pack the same top-level items, so unpacking the new archive gives the same layout.
        let entries = try FileManager.default.contentsOfDirectory(atPath: contents.path)
            .filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
            .sorted()
        guard !entries.isEmpty else { throw ConversionError.exportFailed("the archive is empty") }

        if to == .zip {
            // zip (rather than ditto) so several top-level items stay at the top level.
            try await ProcessRunner.run("/usr/bin/zip", ["-r", "-y", "-q", output.path] + entries, in: contents)
        } else {
            // COPYFILE_DISABLE stops macOS adding ._ resource-fork files.
            try await ProcessRunner.run("/usr/bin/tar", ["-c"] + Self.writable[to]! + ["-f", output.path, "-C", contents.path] + entries,
                                        environment: ["COPYFILE_DISABLE": "1"])
        }
    }

    /// Mounts the image read-only and hidden, copies its files, and ejects it.
    private static func copyDiskImage(_ image: URL, to folder: URL) async throws {
        let mountPoint = folder.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await ProcessRunner.run("/usr/bin/hdiutil", [
            "attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path,
        ], input: nil, timeout: 120)
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: mountPoint.path)
            .filter { !$0.hasPrefix(".") }
        for item in items {
            try await ProcessRunner.run("/usr/bin/ditto", [mountPoint.appendingPathComponent(item).path, folder.appendingPathComponent(item).path])
        }
    }
}
