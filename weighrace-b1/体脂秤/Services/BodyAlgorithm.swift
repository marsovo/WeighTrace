import Foundation

@MainActor enum BodyAlgorithm {
    /// Selectable body-composition algorithms. The active kind is a user
    /// preference (see `currentKind`); every measurement records the kind it
    /// was computed with in `BodyMeasurement.algorithmVersion`, and member
    /// reassignment recomputes with the record's own kind so a stored
    /// history never silently changes caliber.
    enum Kind: String, CaseIterable {
        case segal, holtek

        var version: String {
            switch self {
            case .segal: return "segal_1988_v1"
            case .holtek: return "holtek_v1"
            }
        }

        static func from(version: String?) -> Kind {
            version?.hasPrefix("holtek") == true ? .holtek : .segal
        }
    }

    static let version = Kind.segal.version
    static let preferenceKey = "afu.algorithm.kind"

    /// The algorithm applied to new measurements. Defaults to Segal — the
    /// long-standing caliber of this patch (the user's 2026-10-26 decision
    /// was to keep Segal unmodified rather than fudge it toward the official
    /// app); Holtek is an opt-in alternative, not a replacement.
    static var currentKind: Kind {
        Kind(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .segal
    }

    private struct Composition {
        var bodyFat: Double
        var muscle: Double
        var water: Double
        var protein: Double
        var boneMass: Double
        var visceralFat: Double? = nil
        var bmr: Double? = nil
        var subcutaneousFat: Double? = nil
    }

    static func measure(
        id: UUID = UUID(),
        date: Date = .now,
        weight: Double,
        impedance: Double,
        member: FamilyMember,
        adcIndex: Int? = nil,
        rawADCs: [Double]? = nil,
        normalizedImpedances: [Double]? = nil,
        algorithm: Kind? = nil
    ) -> BodyMeasurement {
        let heightM = member.height / 100
        let bmi = weight / (heightM * heightM)
        let age = Double(max(0, Calendar.current.dateComponents([.year], from: member.birthDate, to: date).year ?? member.age))
        let validResistance = (100.0...1500.0).contains(impedance) ? impedance : nil
        let kind = algorithm ?? currentKind
        let male = member.sex == .male

        let composition: Composition
        if let resistance = validResistance {
            switch kind {
            case .segal:
                composition = segalComposition(weight: weight, resistance: resistance, heightCm: member.height, age: age, male: male)
            case .holtek:
                composition = holtekComposition(weight: weight, resistance: resistance, heightCm: member.height, age: age, male: male)
            }
        } else {
            // No usable impedance (e.g. socks): both algorithms fall back to
            // the same BMI estimate the app has always used.
            composition = bmiFallbackComposition(weight: weight, bmi: bmi, age: age, male: male)
        }

        return BodyMeasurement(
            id: id,
            date: date,
            weight: weight,
            impedance: impedance,
            bmi: bmi,
            bodyFat: composition.bodyFat,
            muscle: composition.muscle,
            water: composition.water,
            protein: composition.protein,
            boneMass: composition.boneMass,
            memberID: member.id,
            memberName: member.name,
            adcIndex: adcIndex,
            rawADCs: rawADCs,
            normalizedImpedances: normalizedImpedances,
            profileSnapshot: MeasurementProfileSnapshot(member: member),
            algorithmVersion: kind.version,
            visceralFat: composition.visceralFat,
            bmr: composition.bmr,
            subcutaneousFat: composition.subcutaneousFat
        )
    }

    // MARK: - Segal 1988 (unchanged numerics)

    private static func segalComposition(weight: Double, resistance: Double, heightCm: Double, age: Double, male: Bool) -> Composition {
        let heightSquared = heightCm * heightCm
        var fatFreeMass: Double

        if male {
            fatFreeMass = 9.33285
                + 0.00066360 * heightSquared
                - 0.02117 * resistance
                + 0.62854 * weight
                - 0.12380 * age
            let initialBodyFat = 100 * (weight - fatFreeMass) / weight
            if initialBodyFat >= 20 {
                fatFreeMass = 14.52435
                    + 0.00088580 * heightSquared
                    - 0.02999 * resistance
                    + 0.42688 * weight
                    - 0.07002 * age
            }
        } else {
            fatFreeMass = 10.43485
                + 0.00064602 * heightSquared
                - 0.01397 * resistance
                + 0.42087 * weight
            let initialBodyFat = 100 * (weight - fatFreeMass) / weight
            if initialBodyFat >= 30 {
                fatFreeMass = 9.37938
                    + 0.00091186 * heightSquared
                    - 0.01466 * resistance
                    + 0.29990 * weight
                    - 0.07012 * age
            }
        }

        fatFreeMass = clamp(fatFreeMass, weight * 0.35, weight * 0.97)
        let baseBodyFat = 100 * (weight - fatFreeMass) / weight
        let fat = clamp(baseBodyFat, male ? 3.0 : 8.0, 60.0)
        return derivedComposition(weight: weight, bodyFat: fat, male: male)
    }

    private static func bmiFallbackComposition(weight: Double, bmi: Double, age: Double, male: Bool) -> Composition {
        let sexValue = male ? 1.0 : 0.0
        let baseBodyFat = 1.20 * bmi + 0.23 * age - 10.8 * sexValue - 5.4
        let fat = clamp(baseBodyFat, male ? 3.0 : 8.0, 60.0)
        return derivedComposition(weight: weight, bodyFat: fat, male: male)
    }

    /// The derived-metrics block shared by the Segal and BMI-fallback paths:
    /// bone is a fixed share of weight, muscle is the remainder.
    private static func derivedComposition(weight: Double, bodyFat fat: Double, male: Bool) -> Composition {
        let bonePercent = male ? 4.5 : 4.0
        let musclePercent = clamp(100.0 - fat - bonePercent, 20.0, 95.0)
        return Composition(
            bodyFat: fat,
            muscle: weight * musclePercent / 100.0,
            water: clamp((100.0 - fat) * 0.70, 25.0, 80.0),
            protein: clamp((100.0 - fat) * 0.238, 5.0, 35.0),
            boneMass: weight * bonePercent / 100.0
        )
    }

    // MARK: - Holtek (Xiaomi / Zepp Life single-frequency formulas)

    /// Faithful port of the Xiaomi/Zepp Life (Holtek) JNI formulas, as
    /// reverse-engineered in the OHealthBridge project's BodyFatMeasureHook.
    /// These are a single-frequency scale vendor's own calibration; on this
    /// project's same-session captures they land closer to the Boohee
    /// official app than Segal does (see docs/PROTOCOL-B1.md, v1.13 note).
    /// Documented deviations from the source: the result is clamped to this
    /// app's sane storage ranges (body fat to [3/8, 75], water to [25, 80],
    /// bone to [0.5, 8] kg, muscle to [0, weight], visceral index to
    /// [0, 30]); the source's unreachable 120 kg muscle caps are subsumed by
    /// the muscle clamp. Protein is the source's fixed 16% placeholder.
    private static func holtekComposition(weight w: Double, resistance impedance: Double, heightCm height: Double, age: Double, male: Bool) -> Composition {
        // Lean body mass.
        let lbm = (height * 9.058 / 100.0) * (height / 100.0)
            + w * 0.32 + 12.226 - impedance * 0.0068 - age * 0.0542
        // Body fat %.
        let lbmSub: Double
        if !male && age <= 49 { lbmSub = 9.25 }
        else if male && age > 49 { lbmSub = 7.25 }
        else { lbmSub = 0.8 }
        var coeff = 1.0
        if male && w < 61.0 { coeff = 0.98 }
        else if !male && w > 60.0 { coeff = 0.96; if height > 160 { coeff *= 1.03 } }
        else if !male && w < 50.0 { coeff = 1.02; if height > 160 { coeff *= 1.03 } }
        var bodyFat = (1.0 - ((lbm - lbmSub) * coeff / w)) * 100.0
        if bodyFat > 63.0 { bodyFat = 75.0 }
        bodyFat = clamp(bodyFat, male ? 3.0 : 8.0, 75.0)
        // Bone mass (kg).
        let boneBase = male ? 0.18016894 : 0.245691014
        var bone = (boneBase - lbm * 0.05158) * -1.0
        if bone > 2.2 { bone += 0.1 } else { bone -= 0.1 }
        if !male && bone > 5.1 { bone = 8.0 }
        else if male && bone > 5.2 { bone = 8.0 }
        bone = clamp(bone, 0.5, 8.0)
        // Muscle mass (kg).
        let muscle = clamp(w - (bodyFat * 0.01 * w) - bone, 0, w)
        // Water %.
        let waterRaw = (100.0 - bodyFat) * 0.7
        let water = clamp((waterRaw < 50.0 ? 1.02 : 0.98) * waterRaw, 25.0, 80.0)
        // Visceral fat index.
        let visfat: Double
        if male {
            if height < w * 1.6 {
                let sub = ((height * 0.4) - (height * (height * 0.0826))) * -1.0
                visfat = (w * 305.0 / (sub + 48.0)) - 2.9 + age * 0.15
            } else {
                let sub = 0.765 + height * -0.0015
                visfat = ((height * 0.143) - (w * sub)) * -1.0 + age * 0.15 - 5.0
            }
        } else {
            if w > (13.0 - (height * 0.5)) * -1.0 {
                let subsub = ((height * 1.45) + (height * 0.1158) * height) - 120.0
                let sub = w * 500.0 / subsub
                visfat = (sub - 6.0) + age * 0.07
            } else {
                let sub = 0.691 + height * -0.0024 + height * -0.0024
                visfat = ((height * 0.027) - (sub * w)) * -1.0 + age * 0.07 - age
            }
        }
        // BMR, Mifflin-St Jeor (kcal/day).
        let bmr = Int(10.0 * w + 6.25 * height - 5.0 * age + (male ? 5.0 : -161.0))
        return Composition(
            bodyFat: bodyFat,
            muscle: muscle,
            water: water,
            protein: 16.0,
            boneMass: bone,
            // The source's light-weight female branch yields non-positive
            // indices; treat those as "not computed" instead of storing a
            // fake zero level.
            visceralFat: visfat > 0 ? clamp(visfat, 0, 30) : nil,
            bmr: Double(bmr),
            subcutaneousFat: bodyFat * 0.85
        )
    }

    private static func clamp(_ value: Double, _ lowerBound: Double, _ upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}
