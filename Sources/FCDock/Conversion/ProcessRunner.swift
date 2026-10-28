import Foundation

/// Runs a command-line tool without blocking, throwing its error output if it fails.
enum ProcessRunner {
    /// Returns everything the tool printed to stdout.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: URL? = nil,
        timeout: TimeInterval = 600
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let input {
            process.standardInput = try FileHandle(forReadingFrom: input)
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Collect output as it arrives so a chatty tool can't fill the pipe and stall.
        let output = OutputBuffer()
        let errors = OutputBuffer()
        let stdout = Pipe()
        let stderr = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
        process.standardOutput = stdout
        process.standardError = stderr

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errors.append(stderr.fileHandleForReading.readDataToEndOfFile())

        guard status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let message = String(decoding: errors.data, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.exportFailed(message.isEmpty ? "\(name) failed" : message)
        }
        return output.data
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
