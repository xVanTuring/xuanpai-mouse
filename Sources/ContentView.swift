import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MouseStore
    @EnvironmentObject private var device: MouseDevice

    var body: some View {
        VStack(spacing: 0) {
            Form {
                deviceSection
                if device.link != .none {
                    performanceSection
                    dpiSection
                }
            }
            .formStyle(.grouped)
            .disabled(store.isBusy)

            footer
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        Section(L("Device")) {
            LabeledContent(L("Connection"), value: connectionText)
            if let info = store.info {
                LabeledContent(L("Serial number"), value: info.serial)
                LabeledContent(L("Battery")) {
                    HStack {
                        ProgressView(value: Double(min(info.battery, 100)), total: 100)
                            .frame(width: 80)
                        Text("\(info.battery)%").monospacedDigit()
                    }
                }
            }
            if device.inputAccessDenied {
                Text(L("Input Monitoring permission is required. Allow it in System Settings → Privacy & Security → Input Monitoring, then relaunch."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var connectionText: String {
        switch device.link {
        case .none: return L("Not connected")
        case .wireless: return L("NearLink receiver")
        case .wired: return L("Wired")
        }
    }

    // MARK: - 性能

    private var performanceSection: some View {
        Section(L("Performance")) {
            Picker(L("Polling rate"), selection: Binding(
                get: { store.rate },
                set: { if let v = $0 { Task { await store.setRate(v) } } }
            )) {
                ForEach(store.availableRates) { Text("\($0.rawValue) Hz").tag(Optional($0)) }
            }
            Picker(L("Lift-off distance"), selection: Binding(
                get: { store.lod },
                set: { if let v = $0 { Task { await store.setLOD(v) } } }
            )) {
                Text("1 mm").tag(Optional(1))
                Text("2 mm").tag(Optional(2))
            }
            Picker(L("Button debounce"), selection: Binding(
                get: { store.debounce },
                set: { if let v = $0 { Task { await store.setDebounce(v) } } }
            )) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) ms").tag(Optional($0)) }
            }
        }
    }

    // MARK: - DPI

    private var dpiSection: some View {
        Section {
            ForEach(store.dpiDraft.indices, id: \.self) { i in
                HStack {
                    Button {
                        store.currentLevelDraft = i + 1
                    } label: {
                        Image(systemName: store.currentLevelDraft == i + 1 ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    .help(L("Use this level"))

                    Text(String(format: L("Level %d"), i + 1))
                    Spacer()
                    Text("\(store.dpiDraft[i]) DPI")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $store.dpiDraft[i],
                            in: MouseProtocol.dpiRange,
                            step: MouseProtocol.dpiStep)
                        .labelsHidden()
                }
            }
            HStack {
                Button(L("Add level")) {
                    store.dpiDraft.append(min(store.dpiDraft.last ?? 800, MouseProtocol.dpiRange.upperBound))
                }
                .disabled(store.dpiDraft.count >= MouseProtocol.dpiSlots)
                Button(L("Remove last")) {
                    store.dpiDraft.removeLast()
                    store.currentLevelDraft = min(store.currentLevelDraft, store.dpiDraft.count)
                }
                .disabled(store.dpiDraft.count <= 1)
                Spacer()
                Button(L("Revert")) { store.revertDPIDraft() }
                    .disabled(!store.dpiDraftChanged)
                Button(L("Apply")) { Task { await store.applyDPI() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.dpiDraftChanged)
            }
        } header: {
            Text(L("DPI levels"))
        } footer: {
            Text(L("The selected circle is the active level. Changes take effect after pressing Apply."))
        }
    }

    // MARK: - 底部状态栏

    private var footer: some View {
        HStack(spacing: 8) {
            if let text = store.busyText {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            } else if let error = store.errorText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(L("Refresh")) { Task { await store.refresh() } }
                .disabled(store.isBusy || device.link == .none)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
