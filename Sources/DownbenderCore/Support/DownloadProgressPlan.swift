import Foundation

struct DownloadProgressPlan: Equatable, Sendable {
    struct Phase: Equatable, Sendable {
        let sizeBytes: Int64?
        let bitrateKbps: Double?
    }

    let phases: [Phase]

    var weights: [Double] {
        guard phases.count > 1 else { return phases.isEmpty ? [] : [1] }

        let sizes = phases.map { Double($0.sizeBytes ?? 0) }
        if sizes.allSatisfy({ $0 > 0 }) { return normalized(sizes) }

        let bitrates = phases.map { $0.bitrateKbps ?? 0 }
        if bitrates.allSatisfy({ $0 > 0 }) { return normalized(bitrates) }

        return Array(repeating: 1 / Double(phases.count), count: phases.count)
    }

    private func normalized(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }
}

enum DownloadProgressPlanParser {
    static let linePrefix = "DBPLAN"

    /// DBPLAN|requested-0 id/size/tbr|requested-1 id/size/tbr|direct id/size/tbr
    static func parse(line: String) -> DownloadProgressPlan? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 10, fields[0] == linePrefix else { return nil }

        let phases: [DownloadProgressPlan.Phase]
        if available(fields[1]) {
            phases = [phase(size: fields[2], bitrate: fields[3])]
                + (available(fields[4]) ? [phase(size: fields[5], bitrate: fields[6])] : [])
        } else if available(fields[7]) {
            phases = [phase(size: fields[8], bitrate: fields[9])]
        } else {
            return nil
        }
        return DownloadProgressPlan(phases: phases)
    }

    private static func available(_ value: String) -> Bool {
        !value.isEmpty && value != "NA"
    }

    private static func phase(size: String, bitrate: String) -> DownloadProgressPlan.Phase {
        DownloadProgressPlan.Phase(
            sizeBytes: number(size).map(Int64.init),
            bitrateKbps: number(bitrate)
        )
    }

    private static func number(_ value: String) -> Double? {
        guard available(value), let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }
}
