import AppKit.NSAppearance
import Foundation

@MainActor
final class ProcessMonitorListModel {
    struct ViewportState: Equatable {
        let startIndex: Int
        let endIndex: Int
        let sortColumn: SortColumn?
        let sortAscending: Bool
        let searchText: String
        let snapshotIndex: UInt64
    }


    enum SortColumn: Equatable {
        case pid
        case command
        case user
        case cpu
        case cpuTime
        case memory
    }

    struct CPUSample {
        let timestamp: TimeInterval
        let user: Double
        let system: Double
        let idle: Double

        var combined: Double {
            let total = user + system
            if total < 0 { return 0 }
            return total
        }
    }

    struct ProcessInfo {
        let pid: Int
        let name: String
    }

    typealias CPUHistoryObserver = (_ samples: [CPUSample], _ logicalCpuCount: Int) -> Void
    var cpuHistory: [CPUSample] {
        didSet {
            notifyCPUHistoryObservers()
        }
    }

    var logicalCpuCount: Int {
        didSet {
            notifyCPUHistoryObservers()
        }
    }

    var selection: CPUHistoryChart.Selection

    var displayedRowCount: Int = 0
    var sortColumn: SortColumn? = .cpu
    var sortAscending: Bool = false
    var visibleRowRange: Range<Int> = 0..<0

    var effectiveAppearance: NSAppearance
    var isWindowActive: Bool = true
    var isTableFirstResponder: Bool = true
    var isShowingHistoricalData = false

    var selectedProcess: ProcessInfo?

    private var cpuHistoryObservers: [CPUHistoryObserver] = []

    init(appearance: NSAppearance,
         cpuHistory: [CPUSample] = [],
         logicalCpuCount: Int = 1,
         selection: CPUHistoryChart.Selection = .none) {
        self.effectiveAppearance = appearance
        self.cpuHistory = cpuHistory
        self.logicalCpuCount = logicalCpuCount
        self.selection = selection
    }

    func addCPUHistoryObserver(_ observer: @escaping CPUHistoryObserver) {
        cpuHistoryObservers.append(observer)
        observer(cpuHistory, logicalCpuCount)
    }

    private func notifyCPUHistoryObservers() {
        for observer in cpuHistoryObservers {
            observer(cpuHistory, logicalCpuCount)
        }
    }
}
