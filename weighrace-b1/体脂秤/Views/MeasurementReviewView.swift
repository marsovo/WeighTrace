import SwiftUI

struct MeasurementReviewView: View {
    @EnvironmentObject private var scale: ScaleManager
    @AppStorage(HealthKitManager.enabledKey) private var healthSyncEnabled = false

    let measurement: BodyMeasurement

    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    MeasurementAnnotationLink(measurement: measurement)
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.green)
                        Text("测量成功")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(measurement.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(measurement.weight, format: .number.precision(.fractionLength(2)))
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                            Text("kg")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        Text("BMI \(measurement.bmi, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.teal.opacity(0.18), .mint.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 22)
                    )

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        MetricTile(
                            title: "体脂率",
                            valueString: String(format: "%.1f%%", measurement.bodyFat),
                            icon: "drop.fill"
                        )
                        MetricTile(
                            title: "阻抗",
                            valueString: String(format: "%.0f Ω", measurement.impedance),
                            icon: "bolt.heart"
                        )
                        MetricTile(
                            title: "肌肉率",
                            valueString: String(format: "%.1f%%", measurement.musclePercent),
                            icon: "figure.strengthtraining.traditional"
                        )
                        MetricTile(
                            title: "体水分率",
                            valueString: String(format: "%.1f%%", measurement.water),
                            icon: "water.waves"
                        )
                        if let visceralFat = measurement.visceralFat {
                            MetricTile(
                                title: "内脏脂肪",
                                valueString: String(format: "%.1f 级", visceralFat),
                                icon: "heart.circle.fill"
                            )
                        }
                        if let bmr = measurement.bmr {
                            MetricTile(
                                title: "基础代谢",
                                valueString: String(format: "%.0f kcal/天", bmr),
                                icon: "flame.fill"
                            )
                        }
                    }

                    VStack(spacing: 10) {
                        Group {
#if targetEnvironment(macCatalyst)
                            Label(
                                String(appLocalized: "本次已保存到这台 Mac"),
                                systemImage: "internaldrive"
                            )
#else
                            Label(
                                healthSyncEnabled
                                    ? String(appLocalized: "本地记录已保存；Apple 健康同步按当前权限执行")
                                    : String(appLocalized: "本次已保存为 App 本地记录"),
                                systemImage: healthSyncEnabled ? "heart.text.square" : "internaldrive"
                            )
#endif
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        Button {
                            scale.dismissReview(for: measurement.id)
                        } label: {
                            Text("保留本次测量")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            if isDeleting {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("删除本次测量", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDeleting)
                    }
                }
                .padding()
            }
            .navigationTitle("本次结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        scale.dismissReview(for: measurement.id)
                    }
                    .disabled(isDeleting)
                }
            }
            .confirmationDialog(
                "确定删除这次测量？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
#if targetEnvironment(macCatalyst)
                Button("删除本地记录", role: .destructive) {
                    Task { await deleteMeasurement() }
                }
#else
                Button("同时删除本地与 Apple 健康数据", role: .destructive) {
                    Task { await deleteMeasurement() }
                }
#endif
                Button("取消", role: .cancel) {}
            } message: {
#if targetEnvironment(macCatalyst)
                Text("会删除这台 Mac 上的测量记录。")
#else
                Text("会删除本地记录，以及本 App 为这次测量写入 Apple 健康的关联样本。")
#endif
            }
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
            .interactiveDismissDisabled(isDeleting)
        }
    }

    private func deleteMeasurement() async {
        isDeleting = true
        deletionError = await scale.deleteMeasurement(measurement)
        isDeleting = false
    }
}

