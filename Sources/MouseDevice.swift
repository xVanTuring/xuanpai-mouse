import Combine
import Foundation
import IOKit
import IOKit.hid

enum MouseError: LocalizedError {
    case notConnected
    case timeout
    case io(IOReturn)
    case rejected(UInt8?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return L("The mouse is not connected.")
        case .timeout: return L("The mouse did not respond. Wake it up by moving it, then try again.")
        case .io(let code): return String(format: L("USB write failed (0x%08x)."), code)
        case .rejected: return L("The mouse rejected the setting.")
        case .badResponse: return L("The mouse sent an unexpected response.")
        }
    }
}

/// 负责与接收器/鼠标的 HID 厂商通道通信。所有 IOKit 回调都在主 RunLoop 上。
/// 命令之间强制间隔，避免把无线鼠标打到无响应（实测间隔太短会让鼠标短暂失联）。
@MainActor
final class MouseDevice: ObservableObject {
    enum Link { case none, wireless, wired }

    @Published private(set) var link: Link = .none
    @Published private(set) var inputAccessDenied = false
    /// 鼠标主动推送的状态变化（电量、DPI 档位）
    let notifications = PassthroughSubject<MouseProtocol.Notification, Never>()

    /// 两条命令之间的最小间隔
    static let minGap: TimeInterval = 1.0
    private static let retryDelay: TimeInterval = 2.0
    private static let responseTimeout: TimeInterval = 3.0

    private struct Waiter {
        let id: Int
        let echo: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private var waiter: Waiter?
    private var waiterSeq = 0
    private var lastSend = Date.distantPast
    private var tail: Task<Void, Never> = Task {}

    deinit { reportBuffer.deallocate() }

    // MARK: - 连接管理

    func start() {
        guard manager == nil else { return }
        inputAccessDenied = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDVendorIDKey: MouseProtocol.vendorID, kIOHIDProductIDKey: MouseProtocol.dongleProductID],
            [kIOHIDVendorIDKey: MouseProtocol.vendorID, kIOHIDProductIDKey: MouseProtocol.wiredProductID],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<MouseDevice>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(dev) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<MouseDevice>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(dev) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func attach(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        let maxOut = IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        guard maxOut >= MouseProtocol.frameLength - 1 else { return } // 只要带厂商通道的那个接口
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 256, { ctx, _, _, _, reportID, report, length in
            // 鼠标移动等普通上报很频繁，只处理厂商应答
            guard reportID == UInt32(MouseProtocol.inputReportID), let ctx else { return }
            let data = Array(UnsafeBufferPointer(start: report, count: length))
            let me = Unmanaged<MouseDevice>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.handleVendorReport(data) }
        }, Unmanaged.passUnretained(self).toOpaque())

        device = dev
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        link = pid == MouseProtocol.wiredProductID ? .wired : .wireless
    }

    private func detach(_ dev: IOHIDDevice) {
        guard let current = device, CFEqual(current, dev) else { return }
        device = nil
        link = .none
        finishWaiter(waiter?.id, .failure(MouseError.notConnected))
    }

    // MARK: - 收发

    private func handleVendorReport(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        // 0x50 是鼠标主动推送的状态通知（含电量、当前 DPI 档），不是命令应答
        if data[1] == MouseProtocol.notificationEcho {
            if let n = MouseProtocol.parseNotification(data) { notifications.send(n) }
            return
        }
        guard let w = waiter else { return }
        if data[1] == w.echo {
            finishWaiter(w.id, .success(data))
        }
    }

    private func finishWaiter(_ id: Int?, _ result: Result<[UInt8], Error>) {
        guard let id, let w = waiter, w.id == id else { return }
        waiter = nil
        w.continuation.resume(with: result)
    }

    private func exchangeOnce(_ payload: [UInt8], echo: UInt8) async throws -> [UInt8] {
        let gap = Self.minGap - Date().timeIntervalSince(lastSend)
        if gap > 0 { try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
        guard let dev = device else { throw MouseError.notConnected }

        let frame = MouseProtocol.frame(payload)
        waiterSeq += 1
        let id = waiterSeq
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            waiter = Waiter(id: id, echo: echo, continuation: cont)
            lastSend = Date()
            let result = frame.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(MouseProtocol.outputReportID),
                                     $0.baseAddress!, frame.count)
            }
            if result != kIOReturnSuccess {
                finishWaiter(id, .failure(MouseError.io(result)))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.responseTimeout * 1_000_000_000))
                self.finishWaiter(id, .failure(MouseError.timeout))
            }
        }
    }

    /// 所有命令串行执行
    private func enqueue<T>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { @MainActor () -> Result<T, Error> in
            await previous.value
            do { return .success(try await op()) } catch { return .failure(error) }
        }
        tail = Task { _ = await job.value }
        return try await job.value.get()
    }

    func transact(_ payload: [UInt8], echo: UInt8) async throws -> [UInt8] {
        try await enqueue { [self] in
            var attempt = 0
            while true {
                do {
                    return try await exchangeOnce(payload, echo: echo)
                } catch MouseError.timeout where attempt < 1 {
                    // 鼠标可能刚从休眠中唤醒，等一会儿重试一次
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                }
            }
        }
    }

    // MARK: - 读写接口

    func read(_ command: MouseProtocol.Command) async throws -> [UInt8] {
        try await transact(MouseProtocol.readRequest(command), echo: command.rawValue)
    }

    func write(_ entries: [[UInt8]]) async throws {
        let r = try await transact(MouseProtocol.container(entries), echo: MouseProtocol.Command.container.rawValue)
        guard MouseProtocol.writeSucceeded(r) else { throw MouseError.rejected(r.count > 2 ? r[2] : nil) }
    }
}
