import Foundation

@main
struct TrendsBackupChecks {
    @MainActor static func main() throws {
        let realProfileBefore = UserDefaults.standard.data(forKey: "afu.primary.profile")
        let suiteName = "afu.tests.demo.\(UUID().uuidString)"
        let demoDefaults = UserDefaults(suiteName: suiteName)!
        defer { demoDefaults.removePersistentDomain(forName: suiteName) }
        let demoProfile = UserProfile(defaults: demoDefaults)
        assert(!demoProfile.isComplete)
        assert(demoDefaults.data(forKey: "afu.primary.profile") == nil)
        demoProfile.height = 182
        assert(!UserProfile(defaults: demoDefaults).isComplete, "partial edits must not complete onboarding")
        let birthday = Date(timeIntervalSince1970: 946684800)
        assert(!demoProfile.completeProfile(sex: .male, height: .nan, birthDate: birthday))
        assert(!demoProfile.completeProfile(sex: .male, height: 182, birthDate: Date().addingTimeInterval(86400)))
        assert(demoDefaults.data(forKey: "afu.primary.profile") == nil)
        assert(demoProfile.completeProfile(sex: .male, height: 182, birthDate: birthday))
        let reloadedProfile = UserProfile(defaults: demoDefaults)
        assert(reloadedProfile.isComplete && reloadedProfile.height == 182 && reloadedProfile.sex == .male)
        assert(reloadedProfile.birthDate == birthday)
        assert(UserDefaults.standard.data(forKey: "afu.primary.profile") == realProfileBefore)
        assert(AppLanguage(rawValue: "en") == .english)
        assert(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans")
        let primary = FamilyMember(id: MeasurementBackup.primaryID, name: "本人", sex: .male,
                                   height: 170, birthDate: Date(timeIntervalSince1970: 946684800), referenceWeight: 60)
        // The original profile schema had these same fields, but no completion flag.
        demoDefaults.set(try JSONEncoder().encode(primary), forKey: "afu.primary.profile")
        assert(UserProfile(defaults: demoDefaults).isComplete, "valid existing profiles skip onboarding")
        let restored = UserProfile(defaults: UserDefaults(suiteName: suiteName + ".restore")!)
        defer { UserDefaults(suiteName: suiteName + ".restore")!.removePersistentDomain(forName: suiteName + ".restore") }
        assert(!restored.isComplete)
        restored.restoreBackup(primary: primary, family: [])
        assert(restored.isComplete && restored.height == primary.height)
        print("PASS: blank onboarding, partial/invalid rejection, completion persistence, legacy profile and backup restoration")
        let start = Date(timeIntervalSince1970: 1_760_000_000.123456)
        func measurement(_ day: Int, _ weight: Double, id: UUID = UUID()) -> BodyMeasurement {
            BodyAlgorithm.measure(id: id, date: start.addingTimeInterval(Double(day) * 86400), weight: weight,
                                  impedance: 500, member: primary, adcIndex: 0,
                                  rawADCs: [500], normalizedImpedances: [500])
        }
        let a = measurement(0, 60)
        let b = measurement(0, 64)
        let c = measurement(1, 63)
        print("PASS: injected demo profile stores do not modify real defaults; language choices")
        let backup = MeasurementBackup(primary: primary, members: [], measurements: [a, b, c])
        let decoded = try MeasurementBackup.decode(backup.encoded())
        assert(decoded.measurements == backup.measurements, "dates, snapshots and impedances round-trip exactly")
        let repeatImport = backup.merged(with: decoded, replaceConflicts: false)
        assert(repeatImport.measurements.count == 3)
        assert(decoded.preview(against: backup).allSatisfy { $0.added == 0 && $0.conflicts == 0 })
        let changed = measurement(0, 65, id: a.id)
        let incoming = MeasurementBackup(primary: primary, members: [], measurements: [changed])
        assert(incoming.preview(against: backup).first { $0.title == String(localized: "测量记录") }?.conflicts == 1)
        assert(backup.merged(with: incoming, replaceConflicts: false).measurements.first { $0.id == a.id } == a)
        assert(backup.merged(with: incoming, replaceConflicts: true).measurements.first { $0.id == a.id } == changed)
        let daily = MeasurementTrends.dailyWeights([a, b, c])
        assert(daily.count == 2 && daily[0].value == 62 && daily[0].sampleCount == 2)
        let rolling = MeasurementTrends.rollingWeights(daily)
        assert(rolling.last?.value == 62.5, "equal weight per day, not per measurement")
        let gap = DailyWeightPoint(date: daily[0].date.addingTimeInterval(10 * 86400), value: 70, sampleCount: 1)
        assert(MeasurementTrends.rollingWeights([daily[0], gap]).last?.value == 70, "missing days aren't fabricated")
        assert(MeasurementTrends.median([1, 3, 2]) == 2)
        var invalid = backup
        invalid.schemaVersion = 999
        do { _ = try MeasurementBackup.decode(invalid.encoded()); assertionFailure("newer schema rejected") } catch {}
        let duplicates = MeasurementBackup(primary: primary, members: [], measurements: [a, a])
        do { try duplicates.validate(); assertionFailure("duplicate UUID rejected") } catch {}
        var tagged = a
        tagged.tags = [MeasurementTag.morning.rawValue]
        tagged.note = "comma, quote\"\nline"
        let annotatedBackup = MeasurementBackup(primary: primary, members: [], measurements: [tagged])
        let restoredAnnotation = try MeasurementBackup.decode(annotatedBackup.encoded())
        assert(restoredAnnotation.measurements.first?.note == "comma, quote\"\nline")
        assert(annotatedBackup.csv().contains("\"comma, quote\"\"\nline\""))
        var dangerousName = primary
        dangerousName.name = "=SUM(1,2)"
        let dangerousRecord = BodyMeasurement(id: UUID(), date: start, weight: 60, impedance: 0, bmi: 20,
            bodyFat: 15, muscle: 40, water: 60, protein: 20, boneMass: 2,
            memberID: primary.id, memberName: dangerousName.name)
        let escaped = MeasurementBackup(primary: primary, members: [], measurements: [dangerousRecord]).csv()
        assert(escaped.contains("\"'=SUM(1,2)\""))
        print("PASS: JSON round-trip, merge/conflict import, schema and UUID validation, CSV escaping, daily median, seven-day trend and annotations")
        assert(MeasurementPlayback.index(progress: 0, count: 0) == nil)
        assert(MeasurementPlayback.index(progress: 1, count: 1) == 0)
        assert(MeasurementPlayback.index(progress: 0.5, count: 5) == 2)
        assert(MeasurementPlayback.index(progress: -1, count: 5) == 0)
        assert(MeasurementPlayback.index(progress: 10, count: 5) == 4)
        assert(MeasurementPlayback.index(progress: .nan, count: 5) == 0)
        print("PASS: playback boundaries")
    }
}
