import Foundation

/// 玄熊猫 P1 NearLink 的 HID 配置协议（由官方驱动还原，见 work/PROTOCOL.md）。
/// 全部是纯函数，不接触设备，便于单元测试。
enum MouseProtocol {
    static let vendorID = 0x369B
    static let dongleProductID = 0x00B3
    static let wiredProductID = 0x00C4

    static let outputReportID: UInt8 = 0xA0
    static let inputReportID: UInt8 = 0xA1
    static let frameLength = 64
    /// 鼠标主动推送的状态通知（A1 50 …），不是命令应答
    static let notificationEcho: UInt8 = 0x50

    enum Command: UInt8 {
        case deviceInfo = 0x02
        case readRate = 0x41
        case readDPI = 0x45
        case readLOD = 0x4D
        case readDebounce = 0x4F
        case container = 0xDF
    }

    enum Tag: UInt8 {
        case rate = 0x40
        case dpi = 0x44
        case lod = 0x4C
        case debounce = 0x4E
    }

    // MARK: - 组包

    /// 64 字节整帧：A0 + 载荷，零填充
    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: frameLength)
        f[0] = outputReportID
        for (i, b) in payload.prefix(frameLength - 1).enumerated() { f[i + 1] = b }
        return f
    }

    /// 读取请求载荷：设备信息只发 `02`，其余为 `命令号 FF`
    static func readRequest(_ command: Command) -> [UInt8] {
        command == .deviceInfo ? [command.rawValue] : [command.rawValue, 0xFF]
    }

    /// 厂商容器：DF [条目数] [总长] 条目…
    static func container(_ entries: [[UInt8]]) -> [UInt8] {
        let body = entries.flatMap { $0 }
        return [Command.container.rawValue, UInt8(entries.count), UInt8(body.count)] + body
    }

    static func rateEntry(_ rate: PollingRate) -> [UInt8] { [Tag.rate.rawValue, 0x03, rate.code] }
    static func lodEntry(_ mm: Int) -> [UInt8] { [Tag.lod.rawValue, 0x03, UInt8(mm)] }
    static func debounceEntry(_ ms: Int) -> [UInt8] { [Tag.debounce.rawValue, 0x03, UInt8(ms)] }

    static let dpiSlots = 7
    static let dpiRange = 200...26000
    static let dpiStep = 100
    /// 官方驱动的默认指示灯颜色（蓝、绿、黄、青、橙、紫、白）
    static let defaultDPIColors: [[UInt8]] = [
        [0x00, 0x00, 0xFF], [0x00, 0xFF, 0x00], [0xFF, 0xFF, 0x00], [0x00, 0xFF, 0xFF],
        [0xFF, 0xA5, 0x00], [0xEC, 0x4C, 0xFF], [0xFF, 0xFF, 0xFF],
    ]

    /// DPI 条目：当前档(1起) + 7×(DPI/100, 小端16位) + 00 + 7×档位序号 + 7×RGB
    static func dpiEntry(current: Int, levels: [Int]) -> [UInt8] {
        var v: [UInt8] = [UInt8(max(1, min(current, dpiSlots)))]
        for i in 0..<dpiSlots {
            let units = i < levels.count ? clampDPI(levels[i]) / 100 : 0
            v += [UInt8(units & 0xFF), UInt8(units >> 8)]
        }
        v.append(0x00)
        v += (1...dpiSlots).map { UInt8($0) }
        for i in 0..<dpiSlots {
            v += i < levels.count ? defaultDPIColors[i] : [0, 0, 0]
        }
        return [Tag.dpi.rawValue, UInt8(v.count)] + v
    }

    static func clampDPI(_ dpi: Int) -> Int {
        let snapped = (dpi / dpiStep) * dpiStep
        return min(max(snapped, dpiRange.lowerBound), dpiRange.upperBound)
    }

    // MARK: - 解析（r 为完整 64 字节应答，r[0]=A1，r[1]=命令回显）

    struct DeviceInfo: Equatable {
        var vendorID: Int
        var productID: Int
        var serial: String
        var battery: Int
        var workMode: Int
    }

    static func parseDeviceInfo(_ r: [UInt8]) -> DeviceInfo? {
        guard r.count >= 26, r[0] == inputReportID, r[1] == Command.deviceInfo.rawValue else { return nil }
        var info = DeviceInfo(vendorID: 0, productID: 0, serial: "", battery: 0, workMode: 0)
        var i = 6
        while i + 1 < r.count, r[i] == 0x02 {
            let tag = r[i + 1]
            let len: Int
            switch tag {
            case 0x11: len = 4
            case 0x13: len = 6
            case 0x25, 0x26: len = 1
            default: len = -1
            }
            guard len > 0, i + 2 + len <= r.count else { break }
            let v = Array(r[(i + 2)..<(i + 2 + len)])
            switch tag {
            case 0x11:
                info.productID = Int(v[0]) | Int(v[1]) << 8
                info.vendorID = Int(v[2]) | Int(v[3]) << 8
            case 0x13: info.serial = String(decoding: v, as: UTF8.self)
            case 0x25: info.battery = Int(v[0])
            default: info.workMode = Int(v[0])
            }
            i += 2 + len
        }
        return info
    }

    static func parseRate(_ r: [UInt8]) -> PollingRate? {
        guard r.count >= 4, r[0] == inputReportID, r[1] == Command.readRate.rawValue else { return nil }
        return PollingRate(code: r[2])
    }

    static func parseLOD(_ r: [UInt8]) -> Int? {
        guard r.count >= 3, r[0] == inputReportID, r[1] == Command.readLOD.rawValue, (1...2).contains(r[2]) else { return nil }
        return Int(r[2])
    }

    static func parseDebounce(_ r: [UInt8]) -> Int? {
        guard r.count >= 3, r[0] == inputReportID, r[1] == Command.readDebounce.rawValue, r[2] > 0 else { return nil }
        return Int(r[2])
    }

    struct DPIConfig: Equatable {
        var current: Int          // 1 起
        var maxLevels: Int
        var minDPI: Int
        var maxDPI: Int
        var levels: [Int]         // 仅包含已启用（非 0）的档位
    }

    static func parseDPI(_ r: [UInt8]) -> DPIConfig? {
        guard r.count >= 8 + dpiSlots * 2, r[0] == inputReportID, r[1] == Command.readDPI.rawValue else { return nil }
        func le16(_ i: Int) -> Int { Int(r[i]) | Int(r[i + 1]) << 8 }
        let levels = (0..<dpiSlots).map { le16(8 + $0 * 2) * 100 }.filter { $0 > 0 }
        return DPIConfig(current: Int(r[2]), maxLevels: Int(r[3]),
                         minDPI: le16(4) * 100, maxDPI: le16(6) * 100, levels: levels)
    }

    /// 鼠标主动推送的状态通知：A1 50 后接若干 [标签][长度(含头)][值]
    /// 标签 02 且值为 [25, 电量] 表示电量；标签 44 的值为当前 DPI 档位（1 起）
    struct Notification: Equatable {
        var battery: Int?
        var dpiLevel: Int?
    }

    static func parseNotification(_ r: [UInt8]) -> Notification? {
        guard r.count > 2, r[0] == inputReportID, r[1] == notificationEcho else { return nil }
        var n = Notification()
        var i = 2
        while i + 1 < r.count {
            let len = Int(r[i + 1])
            guard len >= 2, i + len <= r.count else { break }
            let value = Array(r[(i + 2)..<(i + len)])
            switch r[i] {
            case 0x44:
                if let level = value.first { n.dpiLevel = Int(level) }
            case 0x02:
                if value.count == 2, value[0] == 0x25 { n.battery = Int(value[1]) }
            default: break
            }
            i += len
        }
        return n
    }

    /// 写入应答：A1 DF 00 表示成功
    static func writeSucceeded(_ r: [UInt8]) -> Bool {
        r.count >= 3 && r[0] == inputReportID && r[1] == Command.container.rawValue && r[2] == 0
    }
}

/// 回报率。码值：125→0，其余按 500→2 … 8000→6（实测码表 00 02 03 04 05 06）
enum PollingRate: Int, CaseIterable, Identifiable {
    case hz125 = 125, hz500 = 500, hz1000 = 1000, hz2000 = 2000, hz4000 = 4000, hz8000 = 8000

    var id: Int { rawValue }

    var code: UInt8 {
        switch self {
        case .hz125: return 0
        case .hz500: return 2
        case .hz1000: return 3
        case .hz2000: return 4
        case .hz4000: return 5
        case .hz8000: return 6
        }
    }

    init?(code: UInt8) {
        guard let match = PollingRate.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}
