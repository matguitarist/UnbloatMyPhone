import SwiftUI

struct FlashView: View {
    @Bindable var flash: FlashModel

    var body: some View {
        PageLayout(title: L("Flash_Title"), subtitle: L("Flash_Lead")) {
            Note(text: L("Flash_Warning"), kind: .warning)
            if flash.wifiOnly { Note(text: L("Flash_WifiOnly")) }
            if flash.notPixel { Note(text: L("Flash_NotPixel"), kind: .error) }

            if !flash.status.isEmpty { statusCard }

            Card(title: flash.name, systemImage: "iphone") {
                fact(L("Flash_Mode"), flash.modeText)
                if flash.found {
                    if !flash.codename.isEmpty { fact(L("Flash_Codename"), flash.codename) }
                    if !flash.build.isEmpty { fact(L("Flash_Software"), flash.build) }
                    fact(L("Flash_Bootloader"), flash.lockText)
                    if flash.isLocked { fact(L("Flash_OemUnlock"), flash.oemText) }
                    fact(L("Flash_Battery"), L(flash.batteryOk ? "Flash_BatteryOk" : "Flash_BatteryLow"))
                    HStack {
                        if !flash.inBootloader { Button(L("Flash_ToBootloader")) { flash.toBootloader() } }
                        if !flash.inAndroid { Button(L("Flash_ToAndroid")) { flash.toAndroid() } }
                    }
                    .disabled(flash.isRunning)
                }
            }

            if !flash.termsAccepted {
                Card(title: L("Flash_TermsTitle"), systemImage: "doc.text") {
                    Text(L("Flash_TermsText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("Flash_TermsAccept")) { flash.acceptTerms() }.buttonStyle(.borderedProminent)
                        Button(L("Flash_TermsRead")) { flash.readTerms() }.buttonStyle(.link)
                    }
                }
            } else {
                if flash.loadingImages { Text(L("Flash_Loading")).foregroundStyle(.secondary) }
                if flash.imagesFailed { Note(text: L("Flash_NoImages")) }
                Toggle(L("Flash_ShowOlder"), isOn: $flash.showOlder)
            }

            Card(title: L("Flash_OtaTitle"), systemImage: "arrow.down.circle") {
                Text(L("Flash_OtaText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("", selection: $flash.selectedOta) {
                        ForEach(flash.otaChoices) { Text($0.label).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    Button(L("Flash_OtaInstall")) { flash.pending = "ota" }
                        .buttonStyle(.borderedProminent)
                        .disabled(!flash.canOta)
                }
                Button(L("Flash_UseFile")) { flash.pickOta() }.buttonStyle(.link)
                if flash.pending == "ota" { confirmRow }
            }

            Card(title: L("Flash_FactoryTitle"), systemImage: "wrench.and.screwdriver") {
                Text(L("Flash_FactoryText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !flash.isUnlocked { Note(text: L("Flash_NeedsUnlock")) }
                HStack {
                    Picker("", selection: $flash.selectedFactory) {
                        ForEach(flash.factoryChoices) { Text($0.label).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    Button(L("Flash_FactoryFlash")) { flash.pending = "factory" }
                        .buttonStyle(.borderedProminent)
                        .disabled(!flash.canFactory)
                }
                Button(L("Flash_UseFile")) { flash.pickFactory() }.buttonStyle(.link)
                option(L("Flash_Wipe"), L("Flash_WipeNote"), $flash.wipe)
                option(L("Flash_LockAfter"), L("Flash_LockAfterNote"), $flash.lockAfter)
                if flash.pending == "factory" { confirmRow }
            }

            Card(title: L("Flash_LockTitle"), systemImage: "lock.open") {
                if flash.isUnlocked {
                    Text(L("Flash_LockText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !Flasher.canLock(flash.serialNo) { Note(text: L("Flash_LockBlocked")) }
                    Button(L("Flash_Lock")) { flash.pending = "lock" }.disabled(!flash.canLock)
                } else {
                    Text(L("Flash_UnlockText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if flash.oemOff { Note(text: L("Flash_OemOffText")) }
                    Button(L("Flash_Unlock")) { flash.pending = "unlock" }.disabled(!flash.canUnlock)
                }
                if flash.pending == "unlock" || flash.pending == "lock" { confirmRow }
            }

            Card(title: L("Flash_CustomTitle"), systemImage: "cpu") {
                Text(L("Flash_CustomText")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    Picker(L("Flash_Partition"), selection: $flash.partition) {
                        ForEach(Flasher.partitions, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    HStack {
                        Button(L("Flash_PickImage")) { flash.pickImage() }
                        if let f = flash.customFile { Text(L("Flash_FileChosen", f.lastPathComponent)).foregroundStyle(.secondary) }
                    }
                    Toggle(L("Flash_BothSlots"), isOn: $flash.bothSlots)
                    if flash.partition == "vbmeta" { Toggle(L("Flash_DisableVerity"), isOn: $flash.disableVerity) }
                    HStack {
                        Button(L("Flash_FlashImage", flash.partition)) { flash.pending = "image" }
                        Button(L("Flash_BootOnce")) { flash.pending = "boot" }
                    }
                    .disabled(flash.customFile == nil)
                    Divider()
                    HStack {
                        Button(L("Flash_PickZip")) { flash.pickZip() }
                        if let f = flash.zipFile { Text(L("Flash_FileChosen", f.lastPathComponent)).foregroundStyle(.secondary) }
                        Button(L("Flash_SideloadZip")) { flash.pending = "zip" }.disabled(flash.zipFile == nil)
                    }
                }
                .disabled(!flash.canCustom)
                if ["image", "boot", "zip"].contains(flash.pending) { confirmRow }
            }
        }
        .toolbar {
            Button { Task { await flash.readState() } } label: { Label(L("Flash_Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Flash_Refresh"))
                .disabled(flash.isRunning)
        }
        .onAppear { flash.startWatching() }
        .onDisappear { flash.stopWatching() }
    }

    private var statusCard: some View {
        Card {
            Text(flash.status)
                .fontWeight(.semibold)
                .foregroundStyle(flash.statusIsError ? .red : flash.statusIsDone ? .green : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if flash.isRunning {
                if let p = flash.progressValue { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
            }
            if flash.canStop { Button(L("Flash_StopDownload")) { flash.stop() } }
            if !flash.log.isEmpty {
                DisclosureGroup(L("Flash_Log")) {
                    ScrollView {
                        Text(flash.log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
    }

    private var confirmRow: some View {
        HStack {
            Label(flash.confirmText, systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("Common_Cancel")) { flash.pending = "" }
            Button(L("Flash_Confirm")) { flash.confirm() }.buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
            Text(value).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ title: String, _ note: String, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
        }
    }
}
