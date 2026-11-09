import SwiftUI
import Foundation

struct ProfileView: View {
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var scale: ScaleManager
    @EnvironmentObject private var healthKit: HealthKitManager
    @AppStorage(HealthKitManager.enabledKey) private var healthSyncEnabled = false
    @AppStorage(HealthKitManager.weightKey) private var syncWeight = true
    @AppStorage(HealthKitManager.bmiKey) private var syncBMI = true
    @AppStorage(HealthKitManager.bodyFatKey) private var syncBodyFat = true
    @AppStorage(HealthKitManager.leanBodyMassKey) private var syncLeanBodyMass = true
    @AppStorage(AppLanguage.storageKey, store: .standard) private var language = AppLanguage.system.rawValue
    @AppStorage(BodyAlgorithm.preferenceKey) private var algorithmKind = BodyAlgorithm.Kind.segal.rawValue
    @State private var showingAddMember = false
    @State private var editingMember: FamilyMember?
    /// 补丁版本号：每次发布新补丁时手动升版，与 README-PATCH-B1.md 的版本记录保持一致。
    private let patchVersion = "v1.15"
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
    }
    var body: some View {
        NavigationStack { Form {
            Section {
                NavigationLink("备份与导出") { BackupView() }
            }
            Section("我的设备") {
                HStack { Image(systemName: "scalemass").foregroundStyle(.teal); VStack(alignment: .leading) { Text(scale.deviceName ?? String(appLocalized: "AFU Welland 体脂秤")); Text(scale.connectionState.title).font(.caption).foregroundStyle(.secondary) }; Spacer(); Circle().fill(scale.connectionState.color).frame(width: 9, height: 9) }
                Button { scale.startScan() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { scale.forgetPairedScale() } label: { Label("更换体脂秤", systemImage: "arrow.triangle.2.circlepath") }
            }
            Section("个人资料") {
                Picker("性别", selection: $profile.sex) { Text("女").tag(Sex.female); Text("男").tag(Sex.male) }
                DatePicker("出生日期", selection: $profile.birthDate, displayedComponents: .date)
                HStack {
                    Text("身高")
                    Spacer()
                    TextField("请输入", value: $profile.height, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                    Text("cm").foregroundStyle(.secondary)
                }
                .onChange(of: profile.height) { newValue in
                    if !(100...230).contains(newValue) { profile.height = min(230, max(100, newValue)) }
                }
                HStack {
                    Text("体重")
                    Spacer()
                    TextField("请输入", value: $profile.referenceWeight, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                    Text("kg").foregroundStyle(.secondary)
                }
                .onChange(of: profile.referenceWeight) { newValue in
                    if !(20...200).contains(newValue) { profile.referenceWeight = min(200, max(20, newValue)) }
                }
                if let latest = scale.history.first(where: { $0.memberID == profile.primaryMember.id }) {
                    Button {
                        profile.referenceWeight = latest.weight
                    } label: {
                        HStack {
                            Text("用最近一次测量更新")
                            Spacer()
                            Text("\(latest.weight, specifier: "%.2f") kg").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // B1: single-impedance scale — no impedance-source picker exists
            // (see docs/PROTOCOL-B1.md).
#if targetEnvironment(macCatalyst)
            MacUpdateSection()
            Section {
                Label("测量历史保存在这台 Mac", systemImage: "internaldrive")
                LabeledContent("已保存记录", value: "\(scale.history.count)")
            } header: {
                Text("本地数据")
            } footer: {
                Text("Mac 版不访问 Apple 健康。个人资料和测量历史保存在当前 Mac；可通过 JSON 备份迁移，删除数据容器前请先导出备份。")
            }
#else
            Section {
                Toggle("自动写入 Apple 健康", isOn: $healthSyncEnabled)
                    .onChange(of: healthSyncEnabled) { enabled in
                        if enabled {
                            healthKit.requestAuthorization()
                        } else {
                            healthKit.refreshStatus()
                        }
                    }
                Toggle("体重（秤直接测量）", isOn: $syncWeight)
                    .disabled(!healthSyncEnabled)
                Toggle("BMI（计算值）", isOn: $syncBMI)
                    .disabled(!healthSyncEnabled)
                Toggle("体脂率（BIA 估算）", isOn: $syncBodyFat)
                    .disabled(!healthSyncEnabled)
                Toggle("去脂体重（由体脂计算）", isOn: $syncLeanBodyMass)
                    .disabled(!healthSyncEnabled)
                Button("检查或重新申请权限") {
                    healthKit.requestAuthorization()
                }
                .disabled(!healthSyncEnabled)
                Button {
                    healthKit.requestMeasurementRecovery()
                } label: {
                    if healthKit.isRecoveringMeasurements {
                        HStack {
                            ProgressView()
                            Text("正在恢复本地记录…")
                        }
                    } else {
                        Label("从 Apple 健康恢复本地记录", systemImage: "arrow.down.doc")
                    }
                }
                .disabled(healthKit.isRecoveringMeasurements)
                Label(healthKit.statusText, systemImage: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastSyncText = healthKit.lastSyncText {
                    Text(lastSyncText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let recoveryStatusText = healthKit.recoveryStatusText {
                    Text(recoveryStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple 健康")
            } footer: {
                Text("只自动同步归属于“本人”的实时测量。新写入的健康样本会携带本 App 的完整测量档案；重装后使用相同 Bundle ID 并重新授权，可恢复本地历史。历史包和家庭成员不会自动写入。")
            }
            .onChange(of: syncWeight) { _ in refreshHealthAuthorization() }
            .onChange(of: syncBMI) { _ in refreshHealthAuthorization() }
            .onChange(of: syncBodyFat) { _ in refreshHealthAuthorization() }
            .onChange(of: syncLeanBodyMass) { _ in refreshHealthAuthorization() }
            Section {
                NavigationLink {
                    HealthDataSourcesView()
                } label: {
                    HStack {
                        Label("查看健康数据来源", systemImage: "point.3.connected.trianglepath.dotted")
                        Spacer()
                        if !healthKit.sourceSummaries.isEmpty {
                            Text("\(healthKit.sourceSummaries.count)")
                                .foregroundStyle(.secondary)
                        }
                        if !healthKit.duplicateWeightGroups.isEmpty {
                            Text("\(healthKit.duplicateWeightGroups.count) 组重复")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("跨体重秤数据")
            } footer: {
                Text("识别 Apple 健康中的体重和体脂数据来自哪些 App，为后续去重、跨秤对比和异常提示打基础。")
            }
#endif
            Section {
                ForEach(profile.members) { member in
                    Button { editingMember = member } label: {
                        HStack { Image(systemName: "person.crop.circle").foregroundStyle(.teal); Text(member.name).foregroundStyle(.primary); Spacer(); Text(member.sex == .female ? String(appLocalized: "女") : String(appLocalized: "男")).font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .onDelete { profile.removeMembers(at: $0) }
                Button { showingAddMember = true } label: { Label("添加家庭成员", systemImage: "person.badge.plus") }
            } header: {
                Text("家庭成员")
            } footer: {
                Text("测量完成后会按成员近期体重和参考体重自动归属记录。")
            }
            Section {
                Picker("体脂算法", selection: $algorithmKind) {
                    Text("Segal（经典）").tag(BodyAlgorithm.Kind.segal.rawValue)
                    Text("Holtek（小米口径）").tag(BodyAlgorithm.Kind.holtek.rawValue)
                }
            } header: {
                Text("体成分算法")
            } footer: {
                Text("只影响之后的新测量，已保存记录保持各自的算法口径。Holtek 是单频体脂秤的厂商校准公式，并额外给出内脏脂肪与基础代谢。")
            }
            Section("说明") {
#if targetEnvironment(macCatalyst)
                Text("体脂率和其他身体成分是本地估算值，不替代医疗诊断。")
#else
                Text("本地历史保存在 App 容器内，卸载 App 会清除；开启 Apple 健康同步后，新测量可从健康样本中的本 App 档案恢复。体脂率为健康参考数据，不替代医疗诊断。")
#endif
            }
            Section("调试日志") {
                Button("清空日志", role: .destructive) { scale.clearDebugLogs() }
                if scale.debugLogs.isEmpty {
                    Text("暂无日志").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(scale.debugLogs, id: \.self) { log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                Picker("语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
            } header: {
                Text("显示")
            }
            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("B1 补丁 \(patchVersion) · \(appVersionText)")
                        .foregroundStyle(.secondary)
                }
            }
        }
            .navigationTitle("我的资料")
            .sheet(isPresented: $showingAddMember) { AddFamilyMemberView { profile.addMember($0) } }
            .sheet(item: $editingMember) { member in
                EditFamilyMemberView(member: member) { profile.updateMember($0) }
            }
            .onAppear {
#if !targetEnvironment(macCatalyst)
                healthKit.refreshStatus()
#endif
            }
        }
    }

    private func refreshHealthAuthorization() {
        guard healthSyncEnabled else { return }
        healthKit.requestAuthorization()
    }
}

struct AddFamilyMemberView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (FamilyMember) -> Void
    @State private var name = ""
    @State private var sex: Sex = .female
    @State private var height = 165.0
    private let referenceWeight: Double
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -28, to: .now) ?? .now
    init(referenceWeight: Double? = nil, onSave: @escaping (FamilyMember) -> Void) {
        self.onSave = onSave
        self.referenceWeight = referenceWeight ?? 0
    }
    var body: some View {
        NavigationStack { Form {
            TextField("称呼", text: $name)
            Picker("性别", selection: $sex) { Text("女").tag(Sex.female); Text("男").tag(Sex.male) }
            DatePicker("出生日期", selection: $birthDate, displayedComponents: .date)
            HStack {
                Text("身高")
                Spacer()
                TextField("请输入", value: $height, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                Text("cm").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("添加成员")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(FamilyMember(name: name.isEmpty ? String(appLocalized: "家庭成员") : name, sex: sex, height: min(230, max(100, height)), birthDate: birthDate, referenceWeight: referenceWeight)); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) } }
        }
    }
}

struct EditFamilyMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scale: ScaleManager
    let onSave: (FamilyMember) -> Void
    private let id: UUID
    @State private var name: String
    @State private var sex: Sex
    @State private var height: Double
    @State private var birthDate: Date
    @State private var referenceWeight: Double
    init(member: FamilyMember, onSave: @escaping (FamilyMember) -> Void) {
        self.onSave = onSave
        self.id = member.id
        _name = State(initialValue: member.name)
        _sex = State(initialValue: member.sex)
        _height = State(initialValue: member.height)
        _birthDate = State(initialValue: member.birthDate)
        _referenceWeight = State(initialValue: member.referenceWeight)
    }
    var body: some View {
        NavigationStack { Form {
            TextField("称呼", text: $name)
            Picker("性别", selection: $sex) { Text("女").tag(Sex.female); Text("男").tag(Sex.male) }
            DatePicker("出生日期", selection: $birthDate, displayedComponents: .date)
            HStack {
                Text("身高")
                Spacer()
                TextField("请输入", value: $height, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                Text("cm").foregroundStyle(.secondary)
            }
            HStack {
                Text("参考体重")
                Spacer()
                TextField("请输入", value: $referenceWeight, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                Text("kg").foregroundStyle(.secondary)
            }
            if let latest = scale.history.first(where: { $0.memberID == id }) {
                Button {
                    referenceWeight = latest.weight
                } label: {
                    HStack {
                        Text("用最近一次测量更新")
                        Spacer()
                        Text("\(latest.weight, specifier: "%.2f") kg").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("编辑成员")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(FamilyMember(id: id, name: name.isEmpty ? String(appLocalized: "家庭成员") : name, sex: sex, height: min(230, max(100, height)), birthDate: birthDate, referenceWeight: min(200, max(20, referenceWeight)))); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) } }
        }
    }
}
