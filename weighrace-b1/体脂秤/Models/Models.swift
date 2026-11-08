import Foundation

enum Sex: String, CaseIterable, Codable { case female, male }

struct MeasurementProfileSnapshot: Codable, Equatable {
    let sex: Sex
    let height: Double
    let birthDate: Date

    init(member: FamilyMember) {
        sex = member.sex
        height = member.height
        birthDate = member.birthDate
    }

    func member(id: UUID?, name: String?, referenceWeight: Double) -> FamilyMember {
        FamilyMember(
            id: id ?? UUID(),
            name: name ?? String(appLocalized: "本人"),
            sex: sex,
            height: height,
            birthDate: birthDate,
            referenceWeight: referenceWeight
        )
    }
}

struct FamilyMember: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sex: Sex
    var height: Double
    var birthDate: Date
    var referenceWeight: Double
    init(id: UUID = UUID(), name: String, sex: Sex, height: Double, birthDate: Date, referenceWeight: Double) { self.id = id; self.name = name; self.sex = sex; self.height = height; self.birthDate = birthDate; self.referenceWeight = referenceWeight }
    var age: Int { Calendar.current.dateComponents([.year], from: birthDate, to: .now).year ?? 28 }
}

struct BodyMeasurement: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let weight: Double
    let impedance: Double
    let bmi: Double
    let bodyFat: Double
    let muscle: Double
    let water: Double
    let protein: Double
    let boneMass: Double
    /// Extended metrics, populated only by algorithms that compute them
    /// (holtek_v1). Optional so records written by earlier versions and by
    /// the Segal algorithm decode and behave exactly as before.
    var visceralFat: Double? = nil
    var bmr: Double? = nil
    var subcutaneousFat: Double? = nil
    let memberID: UUID?
    let memberName: String?
    var adcIndex: Int? = nil
    var rawADCs: [Double]? = nil
    var normalizedImpedances: [Double]? = nil
    var profileSnapshot: MeasurementProfileSnapshot? = nil
    var algorithmVersion: String? = nil
    var tags: [String]? = nil
    var note: String? = nil

    init(
        id: UUID,
        date: Date,
        weight: Double,
        impedance: Double,
        bmi: Double,
        bodyFat: Double,
        muscle: Double,
        water: Double,
        protein: Double,
        boneMass: Double,
        memberID: UUID?,
        memberName: String?,
        adcIndex: Int? = nil,
        rawADCs: [Double]? = nil,
        normalizedImpedances: [Double]? = nil,
        profileSnapshot: MeasurementProfileSnapshot? = nil,
        algorithmVersion: String? = nil,
        visceralFat: Double? = nil,
        bmr: Double? = nil,
        subcutaneousFat: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.weight = weight
        self.impedance = impedance
        self.bmi = bmi
        self.bodyFat = bodyFat
        self.muscle = muscle
        self.water = water
        self.protein = protein
        self.boneMass = boneMass
        self.memberID = memberID
        self.memberName = memberName
        self.adcIndex = adcIndex
        self.rawADCs = rawADCs
        self.normalizedImpedances = normalizedImpedances
        self.profileSnapshot = profileSnapshot
        self.algorithmVersion = algorithmVersion
        self.visceralFat = visceralFat
        self.bmr = bmr
        self.subcutaneousFat = subcutaneousFat
    }
    
    // Computed Properties for UI to show all required metrics (both percentage and mass)
    var bodyFatMass: Double { weight * (bodyFat / 100.0) }
    var musclePercent: Double { weight > 0 ? (muscle / weight) * 100.0 : 0.0 }
    var skeletalMusclePercent: Double { musclePercent * 0.527 }
    var skeletalMuscleMass: Double { muscle * 0.527 }
    var waterMass: Double { weight * (water / 100.0) }
    var proteinMass: Double { weight * (protein / 100.0) }
    var boneMassPercent: Double { weight > 0 ? (boneMass / weight) * 100.0 : 0.0 }
    /// Prefers the algorithm-stored value (holtek_v1 stores body fat × 0.85)
    /// and falls back to this app's long-standing rough estimate otherwise.
    var subcutaneousFatPercent: Double { subcutaneousFat ?? bodyFat * 0.72 }
    var subcutaneousFatMass: Double { weight * (subcutaneousFatPercent / 100.0) }
}

enum MeasurementTag: String, CaseIterable, Identifiable {
    case morning, afterMeal, afterExercise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .morning: String(appLocalized: "晨起")
        case .afterMeal: String(appLocalized: "饭后")
        case .afterExercise: String(appLocalized: "运动后")
        }
    }
}

enum DashboardMetric: String, CaseIterable, Identifiable {
    case bodyFat, bmi, water, muscle, bone, protein
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bodyFat: String(appLocalized: "体脂率")
        case .bmi: "BMI"
        case .water: String(appLocalized: "体水分率")
        case .muscle: String(appLocalized: "肌肉率")
        case .bone: String(appLocalized: "骨量")
        case .protein: String(appLocalized: "蛋白质率")
        }
    }
    func value(_ m: BodyMeasurement) -> String {
        switch self {
        case .bodyFat: String(format: "%.1f%%", m.bodyFat)
        case .bmi: String(format: "%.2f", m.bmi)
        case .water: String(format: "%.1f%%", m.water)
        case .muscle: String(format: "%.1f%%", m.musclePercent)
        case .bone: String(format: "%.1f kg", m.boneMass)
        case .protein: String(format: "%.1f%%", m.protein)
        }
    }
    var source: String {
        self == .bodyFat ? String(appLocalized: "BIA 公式估算") :
        (self == .bmi ? String(appLocalized: "身高与体重计算") : String(appLocalized: "比例粗略推算"))
    }
}
