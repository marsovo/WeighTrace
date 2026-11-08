import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var scale: ScaleManager
    @EnvironmentObject private var profile: UserProfile
    @AppStorage("afu.dashboard.metrics") private var selectedMetrics = "bodyFat,bmi,water"
    private var displayedMeasurement: BodyMeasurement? { scale.currentMeasurement ?? scale.history.first }

    var body: some View {
        NavigationStack {
            ScrollView { VStack(spacing: 12) {
                weightCard
                
                if let measurement = displayedMeasurement, !scale.isMeasuring {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(measurement.memberName ?? String(appLocalized: "本人")).font(.headline)
                        if let previous = scale.history.filter({ $0.memberID == measurement.memberID && $0.date < measurement.date }).max(by: { $0.date < $1.date }) {
                            Text(String(format: String(appLocalized: "较上次体重 %+.2f kg"), measurement.weight - previous.weight))
                                .font(.subheadline)
                        }
                        // B1 patch: single-impedance scales have no ADC choice to
                        // report — show the impedance value itself instead.
                        Text(measurement.impedance > 0 ? String(format: String(appLocalized: "本次阻抗 %lld Ω"), Int(measurement.impedance)) : String(appLocalized: "这条记录未保存阻抗"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    metricGrid(measurement)
                    NavigationLink("查看完整测量详情") { MeasurementDetailView(measurement: measurement) }
                } else {
                    measuringHint
                }
            }
            .padding()
            }
            .onAppear {
                scale.startScan()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { DashboardSettingsView() } label: { Label("自定义首页", systemImage: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { scale.startScan() } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var weightCard: some View {
        VStack(spacing: 12) {
            // Status bar inside card
            HStack {
                Label(scale.connectionState.title, systemImage: scale.connectionState.icon)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(scale.connectionState.color)
                if let level = scale.batteryLevel {
                    Label("\(level)%", systemImage: batterySymbol(level))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(level <= 20 ? .red : .secondary)
                }
                Spacer()
                if scale.isMeasuring {
                    ProgressView().tint(.teal)
                } else if scale.impedance > 0 {
                    Label(
                        // B1 patch: no "ADC n" prefix — a single-impedance scale
                        // has exactly one channel, so the label is pure noise.
                        "\(Int(scale.impedance)) Ω",
                        systemImage: "bolt.heart"
                    )
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.teal)
                }
            }
            .padding(.bottom, 2)
            
            Divider()
            
            // Weight display
            VStack(spacing: 4) {
                    Text(scale.liveWeight <= 0 && displayedMeasurement != nil ? String(appLocalized: "最近记录") : (scale.isStable ? String(appLocalized: "测量完成") : (scale.liveWeight > 0 ? String(appLocalized: "正在测量...") : String(appLocalized: "请赤脚站上体脂秤"))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", scale.liveWeight > 0 ? scale.liveWeight : (displayedMeasurement?.weight ?? 0)))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("kg").font(.title3).fontWeight(.semibold)
                }
            }
            .padding(.vertical, 4)
        }
        .padding()
        .background(LinearGradient(colors: [.teal.opacity(0.18), .mint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
    }

    private func metricGrid(_ m: BodyMeasurement) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(selectedMetrics.split(separator: ",").compactMap { DashboardMetric(rawValue: String($0)) }) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.title).font(.caption)
                    Text(metric.value(m)).font(.title2.bold())
                    Text(metric.source).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var measuringHint: some View {
        EmptyStateView(title: "等待测量数据", icon: "figure.walk", message: "连接体脂秤后，赤脚站稳即可自动计算身体指标。")
            .frame(maxHeight: .infinity)
    }
}
