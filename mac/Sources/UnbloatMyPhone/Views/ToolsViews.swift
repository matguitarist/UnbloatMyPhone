import SwiftUI
import UniformTypeIdentifiers

struct HealthView: View {
    @Environment(AppModel.self) private var app
    var health: HealthModel

    var body: some View {
        PageLayout(title: L("Health_Title"), subtitle: L("Health_Lead")) {
            if health.isLoading { ProgressView().controlSize(.small) }

            if let r = health.report {
                ForEach(health.tips) { tip in
                    Note(text: tip.text, kind: tip.kind == .ok ? .success : tip.kind == .warn ? .warning : .info)
                }

                HStack(alignment: .top, spacing: 12) {
                    gauge(L("Health_Memory"), health.memoryUsed, L("Health_MemoryText", HealthModel.gb(r.memAvailableMb), HealthModel.gb(r.memTotalMb)))
                    gauge(L("Health_Storage"), health.storageUsed, L("Health_StorageText", HealthModel.gb(r.storageFreeMb), HealthModel.gb(r.storageTotalMb)))
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Health_Cpu")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(health.cpuText).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true) // the three tiles share one height

                Card(title: L("Health_TopTitle"), systemImage: "memorychip") {
                    Text(L("Health_TopText")).foregroundStyle(.secondary)
                    ForEach(r.topMemory) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                if let friendly = Catalog.name(of: p.name) {
                                    Text(friendly)
                                    Text(p.name).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                } else {
                                    Text(p.name).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Text(L("Health_Mb", p.mb)).font(.body.weight(.semibold).monospacedDigit())
                        }
                        Divider()
                    }
                }

                Button(L("Health_GoChoose")) { Task { await app.goChoose(reload: true) } }
            }
        }
        .toolbar {
            Button { Task { await health.refresh() } } label: { Label(L("Health_Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Health_Refresh"))
                .disabled(health.isLoading)
        }
    }

    private func gauge(_ title: String, _ used: Double, _ text: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ProgressView(value: used).tint(used > 0.85 ? .orange : .accentColor)
                Text(text).foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct InstallView: View {
    var install: InstallModel
    @State private var picking = false
    @State private var targeted = false

    private static let apk = UTType(filenameExtension: "apk") ?? .data

    var body: some View {
        PageLayout(title: L("Install_Title"), subtitle: L("Install_Lead")) {
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 34)).foregroundStyle(.tint)
                Text(L("Install_Drop")).font(.title3.weight(.semibold))
                Button(L("Install_Pick")) { picking = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(install.isInstalling)
            }
            .frame(maxWidth: .infinity)
            .padding(36)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await install.install(url) }
                return true
            } isTargeted: { targeted = $0 }

            if install.isInstalling { ProgressView().progressViewStyle(.linear) }
            if !install.status.isEmpty { Note(text: install.status, kind: install.statusIsError ? .error : .success) }
            Note(text: L("Install_Warning"), kind: .warning)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [Self.apk]) { result in
            if case .success(let url) = result { Task { await install.install(url) } }
        }
    }
}
