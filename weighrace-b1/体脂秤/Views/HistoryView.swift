import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var scale: ScaleManager
    @EnvironmentObject private var profile: UserProfile
    @State private var deletionError: String?
    @State private var selectedTag = "all"
    @State private var selectedMember = "all"
    /// Filter options: the primary member, current family members, plus any
    /// member ID still present in history (e.g. a since-deleted member), named
    /// from the record snapshot.
    private var memberFilterOptions: [(id: UUID, name: String)] {
        var options: [(id: UUID, name: String)] = [(profile.primaryMember.id, profile.primaryMember.name)]
            + profile.members.map { ($0.id, $0.name) }
        for record in scale.history {
            if let id = record.memberID, !options.contains(where: { $0.id == id }) {
                options.append((id, record.memberName ?? String(appLocalized: "家庭成员")))
            }
        }
        return options
    }
    private var filteredHistory: [BodyMeasurement] {
        scale.history.filter { record in
            let tagOK = selectedTag == "all" || (record.tags ?? []).contains(selectedTag)
            let memberOK = selectedMember == "all"
                || (record.memberID ?? profile.primaryMember.id).uuidString == selectedMember
            return tagOK && memberOK
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("测量条件", selection: $selectedTag) {
                    Text("全部").tag("all")
                    ForEach(MeasurementTag.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("成员", selection: $selectedMember) {
                    Text("全部成员").tag("all")
                    ForEach(memberFilterOptions, id: \.id) { option in
                        Text(option.name).tag(option.id.uuidString)
                    }
                }
                if !scale.history.isEmpty && filteredHistory.isEmpty {
                    Text("没有符合筛选条件的记录").foregroundStyle(.secondary)
                }
                if scale.history.isEmpty { EmptyStateView(title: "还没有测量记录", icon: "calendar.badge.clock", message: "完成首次测量后，记录将保存在这里。") }
                ForEach(filteredHistory) { item in
                    NavigationLink(destination: MeasurementDetailView(measurement: item)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.memberName ?? String(appLocalized: "本人")).fontWeight(.semibold)
                                Text(item.date, format: .dateTime.year().month().day().hour().minute())
                                Text("BMI \(item.bmi, specifier: "%.2f") · 体脂 \(item.bodyFat, specifier: "%.1f")%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.weight, specifier: "%.2f") kg")
                                .fontWeight(.semibold)
                        }
                    }
                }.onDelete { offsets in
                    let measurements = offsets.compactMap { index in
                        filteredHistory.indices.contains(index) ? filteredHistory[index] : nil
                    }
                    Task {
                        for measurement in measurements {
                            if let error = await scale.deleteMeasurement(measurement) {
                                deletionError = error
                                break
                            }
                        }
                    }
                }
            }
            .navigationTitle("测量历史")
            .alert(
                "删除失败",
                isPresented: Binding(
                    get: { deletionError != nil },
                    set: { if !$0 { deletionError = nil } }
                )
            ) {
                Button("知道了", role: .cancel) {
                    deletionError = nil
                }
            } message: {
                Text(deletionError ?? "")
            }
        }
    }
}

struct MeasurementDetailView: View {
    @EnvironmentObject private var scale: ScaleManager
    @EnvironmentObject private var profile: UserProfile
    let measurement: BodyMeasurement

    /// The record as currently stored. Reassignment replaces it in history, so
    /// this view renders the stored version rather than its own stale copy.
    private var live: BodyMeasurement {
        scale.history.first(where: { $0.id == measurement.id }) ?? measurement
    }

    private var assignableMembers: [FamilyMember] {
        var result = [profile.primaryMember] + profile.members
        if let id = live.memberID, !result.contains(where: { $0.id == id }),
           let snapshot = live.profileSnapshot {
            result.insert(snapshot.member(id: id, name: live.memberName, referenceWeight: live.weight), at: 0)
        }
        return result
    }

    private var memberSelection: Binding<UUID> {
        Binding(
            get: { live.memberID ?? profile.primaryMember.id },
            set: { newID in
                guard newID != live.memberID,
                      let member = assignableMembers.first(where: { $0.id == newID }) else { return }
                scale.reassignMeasurement(live, to: member)
            }
        )
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
            MeasurementAnnotationLink(measurement: live)
            // Combined Header, Weight, BMI, and Impedance Card
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(live.memberName ?? String(appLocalized: "本人"))
                            .font(.title3)
                            .fontWeight(.bold)
                        Text(live.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if live.impedance > 0 {
                        Label(
                            // B1 patch: same as DashboardView — drop the "ADC n" prefix.
                            "\(Int(live.impedance)) Ω",
                            systemImage: "bolt.heart"
                        )
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.teal.opacity(0.12), in: Capsule())
                    }
                }
                
                Divider().padding(.vertical, 2)
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("测量体重").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.2f", live.weight))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("kg").font(.subheadline).fontWeight(.semibold)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("身体质量指数").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.2f", live.bmi))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("BMI").font(.subheadline).fontWeight(.semibold)
                        }
                    }
                }
            }
            .padding()
            .background(LinearGradient(colors: [.teal.opacity(0.15), .mint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))

            // Member assignment: records are auto-matched by weight at capture
            // time; this picker is the manual override (recomputes composition).
            HStack {
                Text("归属成员").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("归属成员", selection: memberSelection) {
                    ForEach(assignableMembers) { member in
                        Text(member.name).tag(member.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

            // Grid of metrics (compact)
            VStack(alignment: .leading, spacing: 8) {
                Text("身体指标详情").font(.headline).foregroundStyle(.secondary).padding(.leading, 4)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    MetricTile(title: "体脂率/量", valueString: String(format: "%.1f%% / %.1f kg", live.bodyFat, live.bodyFatMass), icon: "drop.fill")
                    MetricTile(title: "肌肉率/量", valueString: String(format: "%.1f%% / %.1f kg", live.musclePercent, live.muscle), icon: "figure.strengthtraining.traditional")
                    MetricTile(title: "骨骼肌率/量", valueString: String(format: "%.1f%% / %.1f kg", live.skeletalMusclePercent, live.skeletalMuscleMass), icon: "figure.core.training")
                    MetricTile(title: "体水分率/量", valueString: String(format: "%.1f%% / %.1f kg", live.water, live.waterMass), icon: "water.waves")
                    MetricTile(title: "蛋白质率/量", valueString: String(format: "%.1f%% / %.1f kg", live.protein, live.proteinMass), icon: "leaf.fill")
                    MetricTile(title: "骨量率/量", valueString: String(format: "%.1f%% / %.1f kg", live.boneMassPercent, live.boneMass), icon: "shield.fill")
                    MetricTile(title: "皮下脂肪率/量", valueString: String(format: "%.1f%% / %.1f kg", live.subcutaneousFatPercent, live.subcutaneousFatMass), icon: "drop.triangle.fill")
                    if let visceralFat = live.visceralFat {
                        MetricTile(title: "内脏脂肪", valueString: String(format: "%.1f 级", visceralFat), icon: "heart.circle.fill")
                    }
                    if let bmr = live.bmr {
                        MetricTile(title: "基础代谢", valueString: String(format: "%.0f kcal/天", bmr), icon: "flame.fill")
                    }
                }
            }
            }
        }
        .padding()
        .navigationTitle("测量详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

