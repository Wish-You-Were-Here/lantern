import Foundation
import Combine
import SwiftUI

final class UsageModel: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: UsageError?
    private var isFetching = false

    /// Normal interval. The endpoint rate-limits hard — don't poll more often.
    private let normalInterval: TimeInterval = 180
    /// Backoff on 429: 5 min → 15 min → 30 min.
    private let backoffSteps: [TimeInterval] = [300, 900, 1800]
    private var backoffIndex = -1

    private var timer: Timer?
    private var minuteTimer: Timer?

    init() {
        refresh()
        // The countdown ticks every minute, independent of API polling.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
    }

    // MARK: Derived

    /// Severity color for the quota bar.
    static func severityColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7:  return .green
        case ..<0.9:  return .orange
        default:      return .red
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var lastUpdatedText: String? {
        guard let at = snapshot?.fetchedAt else { return nil }
        return "updated \(Self.time.string(from: at))"
    }

    // MARK: Fetching

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            UsageClient.fetch { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isFetching = false
                    switch result {
                    case .success(let snap):
                        self.snapshot = snap
                        self.lastError = nil
                        self.backoffIndex = -1
                        self.schedule(after: self.normalInterval)
                    case .failure(let err):
                        self.lastError = err
                        if case .rateLimited = err {
                            self.backoffIndex = min(self.backoffIndex + 1,
                                                    self.backoffSteps.count - 1)
                            self.schedule(after: self.backoffSteps[self.backoffIndex])
                        } else {
                            // Keep old data if we have any; try again in a while.
                            self.schedule(after: self.normalInterval)
                        }
                    }
                }
            }
        }
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
