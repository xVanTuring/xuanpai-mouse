import Foundation
import IOKit
import IOKit.hid

// 玄熊猫 P1 NearLink 接收器：VID 0x369b / PID 0x00b3
// 厂商通道：Output 0xA0（63 字节），Input 0xA1（63 字节）
let kVID = 0x369b
let kPID = 0x00b3

func hexdump(_ p: UnsafeRawBufferPointer) -> String {
    p.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func hexdump(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func prop(_ d: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(d, key as CFString)
}

func describe(_ d: IOHIDDevice) -> String {
    let keys = ["Product", "VendorID", "ProductID", "PrimaryUsage", "PrimaryUsagePage",
                "Transport", "SerialNumber", "LocationID",
                "MaxInputReportSize", "MaxOutputReportSize", "MaxFeatureReportSize"]
    var out: [String] = []
    for k in keys {
        if let v = prop(d, k) { out.append("\(k)=\(v)") }
    }
    return out.joined(separator: " ")
}

// 被动上报回调：仅打印
let inputCallback: IOHIDReportCallback = { _, _, _, type, reportID, report, length in
    let p = UnsafeRawBufferPointer(start: report, count: length)
    print("INPUT type=\(type.rawValue) id=0x\(String(format: "%02x", reportID)) len=\(length) data=[\(hexdump(p))]")
    fflush(stdout)
}

func makeManager() -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: kVID, kIOHIDProductIDKey: kPID]
    IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
    return m
}

func openDevices(_ m: IOHIDManager) -> [IOHIDDevice] {
    let o = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    if o != kIOReturnSuccess {
        FileHandle.standardError.write("IOHIDManagerOpen 失败 0x\(String(format: "%08x", o))\n".data(using: .utf8)!)
    }
    guard let cf = IOHIDManagerCopyDevices(m) else { return [] }
    let all = (cf as NSSet).allObjects.map { $0 as! IOHIDDevice }
    return all.sorted { "\($0)" < "\($1)" }
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"

let manager = makeManager()
let devs = openDevices(manager)

if devs.isEmpty {
    FileHandle.standardError.write("未找到 VID=0x369b PID=0x00b3\n".data(using: .utf8)!)
    exit(2)
}

switch cmd {
case "list":
    for (i, d) in devs.enumerated() {
        print("[\(i)] \(describe(d))")
        if let rd = prop(d, "ReportDescriptor") as? Data {
            print("     ReportDescriptor \(rd.count) bytes")
        }
    }

case "read":
    let secs = args.count > 1 ? (Double(args[1]) ?? 3.0) : 3.0
    guard let d = devs.first else { exit(2) }
    let o = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if o != kIOReturnSuccess { print("open 失败 0x" + String(format: "%08x", o)); exit(1) }
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    IOHIDDeviceRegisterInputReportCallback(d, scratch, 256, inputCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    print("监听 \(secs)s 内的上报报文（Ctrl-C 退出）……")
    _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, secs, true)
    IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))

case "get":
    // get <input|feature> <hexid> <len>
    guard args.count >= 4, let id = Int(args[2], radix: 16), let len = Int(args[3]) else {
        print("用法: get <input|feature> <hexid> <len>"); exit(1)
    }
    let type: IOHIDReportType = args[1] == "feature" ? kIOHIDReportTypeFeature : kIOHIDReportTypeInput
    guard let d = devs.first else { exit(2) }
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    var buf = [UInt8](repeating: 0, count: len)
    var n = len
    let o = buf.withUnsafeMutableBufferPointer { bp in
        IOHIDDeviceGetReport(d, type, CFIndex(id), bp.baseAddress!, &n)
    }
    if o == kIOReturnSuccess {
        print("id=0x\(String(format: "%02x", id)) 返回 \(n) 字节: \(hexdump(Array(buf.prefix(n))))")
    } else {
        print("失败 0x" + String(format: "%08x", o))
    }
    IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))

case "send":
    // send <hexid> <hex bytes...>  —— 显式写 Output report，会改变设备状态
    guard args.count >= 3, let id = Int(args[1], radix: 16) else {
        print("用法: send <hexid> <hexbytes...>"); exit(1)
    }
    let bytes = args.dropFirst(2).compactMap { UInt8($0, radix: 16) }
    guard !bytes.isEmpty else { print("没有数据字节"); exit(1) }
    guard let d = devs.first else { exit(2) }
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    let o = bytes.withUnsafeBufferPointer { bp in
        IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(id), bp.baseAddress!, bp.count)
    }
    print("send id=0x\(String(format: "%02x", id)) \(bytes.count) bytes -> 0x" + String(format: "%08x", o))
    IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))

case "xfer":
    // xfer <hex bytes...> —— 发 A0 报文（自动补 0xA0 报告号并填充到 64 字节），监听应答
    let payload = args.dropFirst().compactMap { UInt8($0, radix: 16) }
    guard let d = devs.first, !payload.isEmpty else { print("用法: xfer <hexbytes...>"); exit(1) }
    if IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess { print("open 失败"); exit(1) }
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    IOHIDDeviceRegisterInputReportCallback(d, scratch, 256, inputCallback, nil)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    var frame = [UInt8](repeating: 0, count: 64)
    frame[0] = 0xA0
    for (i, b) in payload.enumerated() where i + 1 < 64 { frame[i + 1] = b }
    let o = frame.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0xA0, $0.baseAddress!, 64) }
    print("OUT  [\(hexdump(Array(frame.prefix(1 + payload.count))))] -> 0x" + String(format: "%08x", o))
    _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 3.0, false)
    IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))

default:
    print("命令: list | read [秒] | get <input|feature> <hexid> <len> | send <hexid> <hexbytes...>")
}
