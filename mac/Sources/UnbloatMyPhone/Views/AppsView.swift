import SwiftUI

struct AppsView: View {
    @Bindable var apps: AppsModel

    var body: some View {
        PageLayout(title: L("Apps_Title"), subtitle: L("Apps_Lead")) {
            Note(text: L("Apps_Note"))
            if !apps.outsideText.isEmpty { Note(text: apps.outsideText, kind: .warning) }
            let lines = apps.nameLines
            if !lines.named.isEmpty || !lines.unnamed.isEmpty {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "questionmark.app").font(.title2).foregroundStyle(.tint).frame(width: 40)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Apps_HelpTitle")).font(.headline)
                            Text(apps.nameHelpText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                Button(L("Apps_Share")) { apps.shareNames() }
                                Button(L("Apps_Copy")) { apps.copyNames() }.buttonStyle(.link)
                                Button(apps.showNames ? L("Apps_HelpHide") : L("Apps_HelpShow", lines.named.count + lines.unnamed.count)) {
                                    apps.showNames.toggle()
                                }
                                .buttonStyle(.link)
                            }
                            if apps.showNames {
                                Text(apps.nameList)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if apps.isLoading { ProgressView().controlSize(.small) }
            if !apps.status.isEmpty { Note(text: apps.status, kind: apps.statusIsError ? .error : .success) }

            if !apps.isLoading && apps.rows.isEmpty {
                Note(text: L("Apps_None"), kind: .success)
            } else if !apps.rows.isEmpty {
                HStack {
                    TextField(L("Apps_Search"), text: $apps.search).textFieldStyle(.roundedBorder)
                    Picker("", selection: $apps.sort) {
                        Text(L("Apps_SortName")).tag(AppsModel.Sort.name)
                        Text(L("Apps_SortSize")).tag(AppsModel.Sort.size)
                        Text(L("Apps_SortNewest")).tag(AppsModel.Sort.newest)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(apps.summary).font(.caption).foregroundStyle(.secondary)

                let visible = apps.visible
                if visible.isEmpty {
                    Text(L("Apps_NoMatch")).foregroundStyle(.secondary)
                } else {
                    Card {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Divider() }
                            AppRowView(row: row, apps: apps)
                        }
                    }
                }
            }
        }
        .toolbar {
            Button { Task { await apps.refresh() } } label: { Label(L("Health_Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Health_Refresh"))
                .disabled(apps.isLoading)
        }
    }
}

private struct AppRowView: View {
    var row: AppRow
    var apps: AppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let icon = row.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.hasFriendlyName {
                        Text(row.package).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    Text(row.details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                if row.isProtected { pill(L("Apps_Needed"), .accentColor) }
                if row.isOff { pill(L("Apps_Off"), .secondary) }
                if row.isGone {
                    Label(L(row.goneKey), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    menu
                }
            }
            if row.pending == "name" {
                @Bindable var row = row
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Apps_NameText")).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(L("Apps_NameWatermark"), text: $row.nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { apps.saveName(row) }
                        Button(L("Common_Cancel")) { row.pending = "" }
                        Button(L("Apps_NameSave")) { apps.saveName(row) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            if row.isConfirming {
                HStack {
                    Label(row.confirmText, systemImage: "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Common_Cancel")) { row.pending = "" }
                    Button(L(row.pending == "archive" ? "Apps_Archive" : "Apps_Uninstall")) { Task { await apps.confirm(row) } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var menu: some View {
        Menu(L("Apps_Actions")) {
            Button(L("Apps_Open")) { Task { await apps.run(row, "Apps_Opened", UserApps.open) } }.disabled(!row.canOpen)
            Button(L("Apps_ShowInfo")) { Task { await apps.run(row, "Apps_InfoOpened", UserApps.showInfo) } }
            Button(L("Apps_Stop")) { Task { await apps.run(row, "Apps_Stopped", UserApps.stop) } }.disabled(!row.canStop)
            if row.canName { Button(L("Apps_NameMenu")) { apps.askName(row) } }
            Divider()
            if row.app.isEnabled {
                Button(L("Apps_TurnOff")) { Task { await apps.setEnabled(row, on: false) } }.disabled(!row.canTurnOff)
            } else {
                Button(L("Apps_TurnOn")) { Task { await apps.setEnabled(row, on: true) } }.disabled(!row.canTurnOn)
            }
            if apps.canArchive(row) { Button(L("Apps_ArchiveMenu")) { row.pending = "archive" } }
            Button(L("Apps_UninstallMenu")) { row.pending = "uninstall" }.disabled(!row.canRemove)
        }
        .fixedSize()
        .disabled(row.isWorking)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}
