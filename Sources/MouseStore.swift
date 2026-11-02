import Combine
import Foundation

@MainActor
final class MouseStore: ObservableObject {
    let device = MouseDevice()

    @Published private(set) var info: MouseProtocol.DeviceInfo?
    @Published private(set) var rate: PollingRate?
    @Published private(set) var lod: Int?
    @Published private(set) var debounce: Int?
    @Published private(set) var dpi: MouseProtocol.DPIConfig?

    /// DPI 编辑草稿，点「应用」后才写入
    @Published var dpiDraft: [Int] = []
    @Published var currentLevelDraft = 1

    @Published private(set) var busyText: String?
    @Published var errorText: String?

    private var cancellable: AnyCancellable?
    private var notificationCancellable: AnyCancellable?
    private var batteryTimer: Timer?

    var isBusy: Bool { busyText != nil }

    var dpiDraftChanged: Bool {
        guard let dpi else { return false }
        return dpiDraft != dpi.levels || currentLevelDraft != dpi.current
    }

    /// 无线最高 4000Hz，8000Hz 仅有线可用（与官方驱动一致）
    var availableRates: [PollingRate] {
        device.link == .wired ? PollingRate.allCases : PollingRate.allCases.filter { $0 != .hz8000 }
    }

    /// 当前使用档位对应的 DPI 值
    var currentDPI: Int? {
        guard let dpi, dpi.current >= 1, dpi.current <= dpi.levels.count else { return nil }
        return dpi.levels[dpi.current - 1]
    }

    init() {
        cancellable = device.$link.removeDuplicates().sink { [weak self] link in
            guard let self else { return }
            if link == .none {
                self.clear()
            } else {
                Task { await self.refresh() }
            }
        }
        notificationCancellable = device.notifications.sink { [weak self] n in
            self?.apply(n)
        }
        // 电量变化平时靠鼠标推送；再每 5 分钟静默读一次，防止漏掉
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshBatterySilently() }
        }
        device.start()
    }

    private func apply(_ n: MouseProtocol.Notification) {
        if let battery = n.battery { info?.battery = battery }
        if let level = n.dpiLevel, dpi != nil {
            let wasDirty = dpiDraftChanged
            dpi?.current = level
            if !wasDirty { currentLevelDraft = min(max(level, 1), max(dpiDraft.count, 1)) }
        }
    }

    private func refreshBatterySilently() async {
        guard device.link != .none, !isBusy else { return }
        if let r = try? await device.read(.deviceInfo), let fresh = MouseProtocol.parseDeviceInfo(r) {
            info?.battery = fresh.battery
        }
    }

    private func clear() {
        info = nil; rate = nil; lod = nil; debounce = nil; dpi = nil
        dpiDraft = []
    }

    // MARK: - 读取

    func refresh() async {
        await run(L("Reading settings…")) {
            let infoReply = try await self.device.read(.deviceInfo)
            self.info = MouseProtocol.parseDeviceInfo(infoReply)
            self.rate = MouseProtocol.parseRate(try await self.device.read(.readRate))
            self.lod = MouseProtocol.parseLOD(try await self.device.read(.readLOD))
            self.debounce = MouseProtocol.parseDebounce(try await self.device.read(.readDebounce))
            self.dpi = MouseProtocol.parseDPI(try await self.device.read(.readDPI))
            if let dpi = self.dpi {
                self.dpiDraft = dpi.levels
                self.currentLevelDraft = min(max(dpi.current, 1), max(dpi.levels.count, 1))
            }
        }
    }

    // MARK: - 写入（写完回读确认）

    func setRate(_ value: PollingRate) async {
        await run(L("Applying…")) {
            try await self.device.write([MouseProtocol.rateEntry(value)])
            self.rate = MouseProtocol.parseRate(try await self.device.read(.readRate))
        }
    }

    func setLOD(_ mm: Int) async {
        await run(L("Applying…")) {
            try await self.device.write([MouseProtocol.lodEntry(mm)])
            self.lod = MouseProtocol.parseLOD(try await self.device.read(.readLOD))
        }
    }

    func setDebounce(_ ms: Int) async {
        await run(L("Applying…")) {
            try await self.device.write([MouseProtocol.debounceEntry(ms)])
            self.debounce = MouseProtocol.parseDebounce(try await self.device.read(.readDebounce))
        }
    }

    func applyDPI() async {
        let levels = dpiDraft.map(MouseProtocol.clampDPI)
        let current = min(max(currentLevelDraft, 1), levels.count)
        guard !levels.isEmpty else { return }
        await run(L("Applying…")) {
            try await self.device.write([MouseProtocol.dpiEntry(current: current, levels: levels)])
            self.dpi = MouseProtocol.parseDPI(try await self.device.read(.readDPI))
            if let dpi = self.dpi {
                self.dpiDraft = dpi.levels
                self.currentLevelDraft = min(max(dpi.current, 1), max(dpi.levels.count, 1))
            }
        }
    }

    func revertDPIDraft() {
        guard let dpi else { return }
        dpiDraft = dpi.levels
        currentLevelDraft = min(max(dpi.current, 1), max(dpi.levels.count, 1))
    }

    // MARK: -

    private func run(_ text: String, _ work: @escaping () async throws -> Void) async {
        guard busyText == nil else { return }
        busyText = text
        errorText = nil
        do { try await work() } catch { errorText = error.localizedDescription }
        busyText = nil
    }
}
