import Foundation
import MetricKit

struct CrashReport: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let summary: String
    let details: String
}

/// Collects Apple's crash diagnostics (MetricKit) so crashes can be copied from Settings.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private let queue = DispatchQueue(label: "qorvex.crashes")

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crashes.json")
    }

    func start() {
        MXMetricManager.shared.add(self)
        ingest(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { ingest(payloads) }

    static func loadReports() -> [CrashReport] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: fileURL)).flatMap { try? dec.decode([CrashReport].self, from: $0) } ?? []
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }

    private func ingest(_ payloads: [MXDiagnosticPayload]) {
        var new: [CrashReport] = []
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                var parts: [String] = []
                parts.append("v\(c.metaData.applicationVersion)")
                if let t = c.exceptionType { parts.append("exception \(t)") }
                if let sig = c.signal { parts.append("signal \(sig)") }
                if let r = c.terminationReason, !r.isEmpty { parts.append(r) }
                let details = String(decoding: c.jsonRepresentation(), as: UTF8.self)
                new.append(CrashReport(date: p.timeStampEnd, summary: parts.joined(separator: " · "), details: details))
            }
        }
        guard !new.isEmpty else { return }
        queue.async {
            var all = CrashReporter.loadReports()
            let existing = Set(all.map { "\($0.date.timeIntervalSince1970)\($0.summary)" })
            all.insert(contentsOf: new.filter { !existing.contains("\($0.date.timeIntervalSince1970)\($0.summary)") }, at: 0)
            if all.count > 10 { all = Array(all.prefix(10)) }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try? enc.encode(all).write(to: CrashReporter.fileURL, options: .atomic)
        }
    }
}
