import SwiftUI

struct PhoneInfoView: View {
    var info: PhoneInfoModel

    var body: some View {
        PageLayout(title: L("Info_Title"), subtitle: L("Info_Lead")) {
            if info.isLoading { ProgressView().controlSize(.small) }
            if !info.status.isEmpty { Note(text: info.status, kind: info.statusIsError ? .error : .success) }

            if info.info != nil {
                ForEach(info.tips) { tip in
                    Note(text: tip.text, kind: tip.kind == .ok ? .success : tip.kind == .warn ? .warning : .info)
                }

                Card(title: L("Info_SoftwareTitle"), systemImage: "iphone") {
                    facts(info.software)
                    Button(L("Info_OpenUpdate")) { Task { await info.openUpdate() } }
                }

                Card(title: L("Info_BetaTitle"), systemImage: "testtube.2") {
                    Text(info.betaText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Info_BetaOpen")) { info.openBeta() }
                }

                Card(title: L("Info_BootTitle"), systemImage: "lock.shield") {
                    facts(info.boot)
                    Text(L("Info_BootText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Card(title: L("Info_RestartTitle"), systemImage: "arrow.clockwise.circle") {
                    if !info.pendingRestart.isEmpty {
                        HStack {
                            Label(info.confirmText, systemImage: "exclamationmark.triangle.fill")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(L("Common_Cancel")) { info.pendingRestart = "" }
                            Button(L("Info_ConfirmYes")) { Task { await info.restart() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    restartRow("normal", L("Info_RestartNormal"), L("Info_RestartNormalText"))
                    restartRow("recovery", L("Info_RestartRecovery"), L("Info_RestartRecoveryText"))
                    restartRow("bootloader", L("Info_RestartBootloader"), L("Info_RestartBootloaderText"))
                }

                Card(title: L("Info_ResetTitle"), systemImage: "arrow.counterclockwise.circle", tint: .orange) {
                    Text(L("Info_ResetText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Info_ResetOpen")) { Task { await info.openSystem() } }
                }
            }
        }
        .toolbar {
            Button { Task { await info.refresh() } } label: { Label(L("Health_Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Health_Refresh"))
                .disabled(info.isLoading)
        }
    }

    private func facts(_ rows: [InfoRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows) { r in
                GridRow {
                    Text(r.label).foregroundStyle(.secondary)
                    Text(r.value).fontWeight(.semibold).textSelection(.enabled)
                }
            }
        }
    }

    private func restartRow(_ mode: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(title) { info.pendingRestart = mode }
        }
    }
}

struct PrivacyView: View {
    var privacy: PrivacyModel

    var body: some View {
        PageLayout(title: L("Privacy_Title"), subtitle: L("Privacy_Lead")) {
            Note(text: L("Privacy_Note"))
            if privacy.isLoading { ProgressView().controlSize(.small) }
            if !privacy.status.isEmpty { Note(text: privacy.status, kind: .error) }
            if !privacy.isLoading && privacy.groups.isEmpty { Note(text: L("Privacy_None"), kind: .success) }

            ForEach(privacy.groups) { g in
                Card(title: L("Privacy_Kind_" + g.kind.key), systemImage: Self.icon(g.kind.key)) {
                    HStack {
                        Text(L("Privacy_KindText_" + g.kind.key)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(L("Privacy_Count", g.rows.count)).font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(g.rows) { row in
                        Divider()
                        AccessRowView(row: row) { Task { await privacy.remove(row) } }
                    }
                }
            }
        }
        .toolbar {
            Button { Task { await privacy.refresh() } } label: { Label(L("Health_Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Health_Refresh"))
                .disabled(privacy.isLoading)
        }
    }

    private static func icon(_ key: String) -> String {
        switch key {
        case "BgLocation": "location.fill"
        case "Location": "location"
        case "Microphone": "mic"
        case "Camera": "camera"
        case "Contacts": "person.crop.circle"
        case "Sms": "message"
        case "CallLog": "phone"
        default: "calendar"
        }
    }
}

private struct AccessRowView: View {
    var row: AccessRow
    var remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if row.name != row.package {
                    Text(row.package).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(L(row.access.isThirdParty ? "Privacy_Yours" : "Privacy_Preinstalled")).font(.caption).foregroundStyle(.tertiary)
            if row.isRemoved {
                Label(L("Privacy_Removed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("Privacy_Remove"), action: remove).disabled(row.isWorking)
            }
        }
    }
}
