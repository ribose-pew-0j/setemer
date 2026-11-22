import AppKit
import Foundation
import UniformTypeIdentifiers

enum HistoryRange: CaseIterable, Sendable {
    case hour
    case day
    case week

    var interval: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 604_800
        }
    }

    var title: String {
        switch self {
        case .hour: return "Час"
        case .day: return "Сутки"
        case .week: return "Неделя"
        }
    }
}

/// Точка истории. Сырой замер: count == 1. Агрегат (старше часа): одна точка на минуту.
struct HistoryPoint: Codable, Sendable, Equatable {
    /// Время замера (для агрегата — начало минуты).
    let date: Date
    /// Задержка, мс. Для агрегата — среднее по успешным замерам. nil, если все замеры неудачны.
    let ms: Double?
    /// Сколько замеров свёрнуто в точку.
    let count: Int
    /// Сколько из них успешны.
    let okCount: Int

    /// Для сырого замера — успех или нет; для агрегата — успех большинства.
    var ok: Bool { okCount > 0 && okCount * 2 >= count }
}

struct HistoryStats: Sendable, Equatable {
    /// Медиана задержки, мс. По агрегатам — по средним минутным значениям (приближение).
    let medianMs: Double?
    /// 95-й перцентиль задержки, мс (с той же оговоркой).
    let p95Ms: Double?
    /// Доля успешных проверок, %.
    let uptimePercent: Double?
    /// Всего проверок (с учётом агрегатов).
    let checks: Int
}

/// История проверок связи на диске: сырые точки за последний час, по одной точке в минуту до 7 суток.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var allPoints: [HistoryPoint] = []

    private let fileURL = AppPaths.supportDirectory.appendingPathComponent("history.json")
    private let rawWindow: TimeInterval = 3_600
    private let retention: TimeInterval = 7 * 86_400
    private let saveInterval: TimeInterval = 10
    private var dirty = false
    private var lastSave = Date.distantPast
    private var saveTask: Task<Void, Never>?

    private init() {
        load()
    }

    /// Добавляет замер. Запись на диск не чаще раза в 10 с.
    func append(date: Date = .now, milliseconds: Int?) {
        let ms = milliseconds.map { Double($0) }
        allPoints.append(HistoryPoint(date: date, ms: ms, count: 1, okCount: ms == nil ? 0 : 1))
        dirty = true
        scheduleSave()
    }

    /// Сразу записывает накопленное (например, при выходе из приложения).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        lastSave = .now
        compact(now: .now)
        guard let data = try? encoder().encode(allPoints) else {
            Log.history.error("Не удалось закодировать историю")
            return
        }
        writeInBackground(data, to: fileURL, log: Log.history)
    }

    func points(for range: HistoryRange, now: Date = .now) -> [HistoryPoint] {
        let start = now.addingTimeInterval(-range.interval)
        return allPoints.filter { $0.date >= start }
    }

    func stats(for range: HistoryRange, now: Date = .now) -> HistoryStats {
        let slice = points(for: range, now: now)
        let checks = slice.reduce(0) { $0 + $1.count }
        let successes = slice.reduce(0) { $0 + $1.okCount }
        let uptime = checks > 0 ? Double(successes) / Double(checks) * 100 : nil
        let latencies = slice.compactMap { $0.ms }.sorted()
        return HistoryStats(medianMs: median(latencies),
                            p95Ms: percentile(latencies, 0.95),
                            uptimePercent: uptime,
                            checks: checks)
    }

    /// CSV (разделитель «;», UTF-8 с BOM, чтобы Excel открыл кириллицу).
    func exportCSV() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Время;Задержка, мс;Проверок;Успешных;Доля успеха, %"]
        for point in allPoints {
            let ms = point.ms.map { String(Int($0.rounded())) } ?? ""
            let share = point.count > 0 ? Int((Double(point.okCount) / Double(point.count) * 100).rounded()) : 0
            lines.append([formatter.string(from: point.date), ms, String(point.count),
                          String(point.okCount), String(share)].joined(separator: ";"))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    /// Показывает NSSavePanel и сохраняет CSV в выбранный файл.
    func exportCSVWithPanel() {
        let csv = exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Сетеметр-история.csv"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.history.error("Экспорт CSV: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            allPoints = try decoder.decode([HistoryPoint].self, from: data)
            compact(now: .now)
        } catch {
            Log.history.error("Не удалось прочитать history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let wait = max(0, lastSave.addingTimeInterval(saveInterval).timeIntervalSinceNow)
        saveTask = Task { [weak self] in
            if wait > 0 {
                _ = try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.flush()
        }
    }

    private struct Bucket {
        let date: Date
        var count = 0
        var okCount = 0
        var msSum = 0.0
    }

    /// Старше часа — одна точка на минуту (среднее мс и доля успеха); старше 7 суток — удаляются.
    private func compact(now: Date) {
        let rawCutoff = now.addingTimeInterval(-rawWindow)
        let oldest = now.addingTimeInterval(-retention)
        var buckets: [Int: Bucket] = [:]
        for point in allPoints where point.date >= oldest && point.date < rawCutoff {
            let minute = Int(point.date.timeIntervalSince1970 / 60)
            var bucket = buckets[minute] ?? Bucket(date: Date(timeIntervalSince1970: TimeInterval(minute * 60)))
            bucket.count += point.count
            bucket.okCount += point.okCount
            bucket.msSum += (point.ms ?? 0) * Double(point.okCount)
            buckets[minute] = bucket
        }
        let aggregated = buckets.values.map { bucket in
            HistoryPoint(date: bucket.date,
                         ms: bucket.okCount > 0 ? bucket.msSum / Double(bucket.okCount) : nil,
                         count: bucket.count,
                         okCount: bucket.okCount)
        }
        let recent = allPoints.filter { $0.date >= rawCutoff }
        allPoints = (aggregated + recent).sorted { $0.date < $1.date }
    }

    private func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// Замер скорости. Значения в Мбит/с; nil — если такой замер не удался.
struct SpeedRecord: Codable, Sendable, Equatable {
    let date: Date
    let down: Double?
    let up: Double?
}

/// Последние 50 замеров скорости, хранятся в speed-history.json.
@MainActor
final class SpeedHistory {
    static let shared = SpeedHistory()

    private(set) var records: [SpeedRecord] = []

    private let limit = 50
    private let fileURL = AppPaths.supportDirectory.appendingPathComponent("speed-history.json")

    private init() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([SpeedRecord].self, from: data)
        } catch {
            Log.history.error("Не удалось прочитать speed-history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    func append(date: Date = .now, down: Double?, up: Double?) {
        records = Array((records + [SpeedRecord(date: date, down: down, up: up)]).suffix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else {
            Log.history.error("Не удалось закодировать историю скорости")
            return
        }
        writeInBackground(data, to: fileURL, log: Log.history)
    }
}
