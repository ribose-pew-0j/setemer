import Foundation
import os

private let logSubsystem = "local.netpulse.monitor"

/// Логи приложения (Console.app, фильтр по подсистеме local.netpulse.monitor).
enum Log {
    static let monitor = Logger(subsystem: logSubsystem, category: "monitor")
    static let diagnostics = Logger(subsystem: logSubsystem, category: "diagnostics")
    static let commands = Logger(subsystem: logSubsystem, category: "commands")
    static let history = Logger(subsystem: logSubsystem, category: "history")
    static let settings = Logger(subsystem: logSubsystem, category: "settings")
    static let notifications = Logger(subsystem: logSubsystem, category: "notifications")
}

/// Каталог данных приложения: ~/Library/Application Support/Сетеметр
enum AppPaths {
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Сетеметр", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Записывает данные на диске в фоне (атомарно).
func writeInBackground(_ data: Data, to url: URL, log: Logger) {
    Task.detached(priority: .utility) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Не удалось записать \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

/// Запускает утилиту без блокировки главного потока и с таймаутом.
/// По истечении таймаута процесс получает SIGTERM (при необходимости SIGKILL).
/// Возвращает stdout (без краёв-пробелов) или nil, если процесс не запустился или не уложился в таймаут.
func runCommand(_ path: String, _ arguments: [String], timeout: TimeInterval = 3) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ["LC_ALL": "C", "LANG": "C"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                Log.commands.error("Не запустился \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: nil)
                return
            }

            // Вывод читаем параллельно: если буфер pipe переполнится, процесс зависнет.
            let box = OutputBox()
            let readDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                box.data = output.fileHandleForReading.readDataToEndOfFile()
                readDone.signal()
            }

            if exited.wait(timeout: .now() + timeout) == .timedOut {
                Log.commands.error("Таймаут \(path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
                continuation.resume(returning: nil)
                return
            }

            guard readDone.wait(timeout: .now() + 1) == .success else {
                continuation.resume(returning: nil)
                return
            }
            let text = String(decoding: box.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(returning: text)
        }
    }
}
