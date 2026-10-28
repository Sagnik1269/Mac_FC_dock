import AppKit

let app = NSApplication.shared
let arguments = CommandLine.arguments

// Developer hook for testing conversions without the gesture:
//   FCDock --convert <file> <format> [--builtin]
if let flag = arguments.firstIndex(of: "--convert"), arguments.count > flag + 2 {
    let source = URL(fileURLWithPath: arguments[flag + 1])
    guard let format = FileFormat.with(id: arguments[flag + 2].lowercased()) else {
        fputs("Unknown format \(arguments[flag + 2])\n", stderr)
        exit(2)
    }
    Converter.useIWork = !arguments.contains("--builtin")
    Task { @MainActor in
        do {
            print(try await Converter.convert(source, to: format).path)
            exit(0)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Lists what the wheel would offer for a file and how each conversion would be done:
//   FCDock --routes <file>
if let flag = arguments.firstIndex(of: "--routes"), arguments.count > flag + 1 {
    let file = URL(fileURLWithPath: arguments[flag + 1])
    guard let source = FileFormat.detect(file) else {
        fputs("Unknown file type\n", stderr)
        exit(2)
    }
    let offered = Set(Converter.targets(for: [file]))
    for target in Catalog.targets(for: source) {
        let routes = Converter.routes(from: source, to: target)
        let description = routes.first.map { $0.map { "\($0.engine.name) \($0.from)→\($0.to)" }.joined(separator: " + ") }
        print("\(offered.contains(target) ? "✓" : "✗") \(target.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(description ?? "needs a tool")")
    }
    exit(0)
}

// Counts how much of the catalog this Mac can do, and lists what's missing:
//   FCDock --coverage
if arguments.contains("--coverage") {
    let available = Converter.availableEngines()
    var count = 0
    var missing: [String] = []
    for source in FileFormat.all {
        for target in Catalog.targets(for: source) {
            if Converter.routes(from: source, to: target, using: available).isEmpty {
                missing.append("\(source.label)→\(target.label)")
            } else {
                count += 1
            }
        }
    }
    print("\(count) of \(count + missing.count) conversions available")
    print("Missing: " + missing.joined(separator: " "))
    exit(0)
}

if let flag = arguments.firstIndex(of: "--render-wheel"), arguments.count > flag + 2 {
    Task { @MainActor in
        do {
            try await DevTools.renderWheel(
                for: URL(fileURLWithPath: arguments[flag + 1]),
                into: URL(fileURLWithPath: arguments[flag + 2])
            )
            exit(0)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let flag = arguments.firstIndex(of: "--demo-wheel"), arguments.count > flag + 1 {
    let seconds = arguments.count > flag + 2 ? Double(arguments[flag + 2]) ?? 6 : 6
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        DevTools.demoWheel(for: URL(fileURLWithPath: arguments[flag + 1]), seconds: seconds)
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
