import SwiftUI
import Foundation
@preconcurrency import CoreBluetooth
import Combine

struct DiscoveredScale: Identifiable { let peripheral: CBPeripheral; let name: String; let identifier: String; let rssi: Int; var id: UUID { peripheral.identifier } }

enum ConnectionState: Equatable { case bluetoothOff, idle, scanning, connecting, connected, measuring
    var title: String { switch self { case .bluetoothOff: String(appLocalized: "蓝牙未开启"); case .idle: String(appLocalized: "等待连接"); case .scanning: String(appLocalized: "正在搜索体脂秤"); case .connecting: String(appLocalized: "正在连接"); case .connected: String(appLocalized: "已连接，等待上秤"); case .measuring: String(appLocalized: "正在测量") } }
    var icon: String { self == .bluetoothOff ? "bluetooth.slash" : "dot.radiowaves.left.and.right" }
    var color: Color { self == .bluetoothOff ? .red : (self == .connected || self == .measuring ? .green : .orange) }
}

@MainActor final class ScaleManager: NSObject, ObservableObject {
    private let defaults: UserDefaults
    private static let pairedPeripheralIDKey = "afu.pairedPeripheralID"
    private let serviceUUID = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
    /// B1 (AFU-BH-TZ-B1) measurement service — see docs/PROTOCOL-B1.md.
    private let bhServiceUUID = CBUUID(string: "FC50")
    private let bhMeasurementUUID = CBUUID(string: "AF000003-9F2D-4C8A-8D6F-6A7B45F90000")
    /// B1 command channel (App → scale); writes start with v1.13 — see AFUCommand.
    private let bhWriteUUID = CBUUID(string: "AF000002-9F2D-4C8A-8D6F-6A7B45F90000")
    private var bhWriteCharacteristic: CBCharacteristic?
    private var bhWriteQueue: [Data] = []
    private var bhWriteInFlight = false
    /// Handshake + history dump run once per B1 connection.
    private var bhHandshakeDone = false
    private var bhStoredReceived = false
    /// The FINAL profile frame closes the scale-side measurement cycle; it is
    /// sent at most once per stand, after the impedance frame is acknowledged.
    private var bhFinalSentForStand = false
    /// Standard BLE Battery Service — the B1 exposes it (180F / 2A19).
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private var bhMeasurementCharacteristic: CBCharacteristic?
    private var central: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    weak var profile: UserProfile?
    weak var healthKit: HealthKitManager?
    @Published var connectionState: ConnectionState = .idle
    @Published var discoveredDevices: [DiscoveredScale] = []
    @Published var liveWeight = 0.0
    @Published var impedance = 0.0
    @Published var selectedADCIndex: Int?
    @Published private(set) var rawADCs: [Double] = []
    @Published private(set) var normalizedImpedances: [Double] = []
    @Published var currentMeasurement: BodyMeasurement?
    @Published var reviewMeasurement: BodyMeasurement?
    @Published var history: [BodyMeasurement] = []
    @Published var deviceName: String?
    /// Scale battery percentage (0–100) from the BLE Battery Service; nil while unknown/disconnected.
    @Published var batteryLevel: Int?
    @Published var isScanning = false
    @Published var isMeasuring = false
    @Published var isStable = false
    @Published var unrecognizedWeight: Double?
    @Published var debugLogs: [String] = []
    private var hasSavedMeasurement = false
    /// B1 only: latest stable weight of the current stand, awaiting its impedance.
    private var pendingBHWeight = 0.0
    func updateAnnotation(id: UUID, tags: [String], note: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].tags = Array(Set(tags)).sorted()
        history[index].note = String(note.prefix(500))
        if currentMeasurement?.id == id { currentMeasurement = history[index] }
        if reviewMeasurement?.id == id { reviewMeasurement = history[index] }
        saveHistory()
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        debugLogs.insert("[\(timestamp)] \(message)", at: 0)
        if debugLogs.count > 100 {
            debugLogs.removeLast()
        }
        print("[ScaleManager] \(message)")
    }
    
    func clearDebugLogs() {
        debugLogs = []
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        loadHistory()
        log("ScaleManager initialized")
    }
    func startScan() {
        if activePeripheral?.state == .connected {
            isScanning = false
            connectionState = isMeasuring ? .measuring : .connected
            return
        }
        if activePeripheral?.state == .connecting { return }
        discoveredDevices = []
        isScanning = true
        guard central.state == .poweredOn else {
            if central.state == .unknown {
                connectionState = .scanning
            } else {
                connectionState = .bluetoothOff
            }
            return
        }
        connectionState = .scanning
        // 与 CLI/Bleak 一致：先接收全部广播，再在 didDiscover 中解析并筛选。
        // 这台秤的 0xAC 协议数据可能放在 0x27AC Service Data 中；
        // 若只按 FFB0 服务扫描，部分 iOS/iPadOS 设备可能收不到完整广播。
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }
    func connect(_ device: DiscoveredScale) {
        guard connectionState != .connecting, activePeripheral == nil else { return }
        central.stopScan()
        isScanning = false
        connectionState = .connecting
        activePeripheral = device.peripheral
        deviceName = device.name
        central.connect(device.peripheral)
    }
    func forgetPairedScale() {
        defaults.set(false, forKey: "afu.hasPairedScale")
        defaults.removeObject(forKey: Self.pairedPeripheralIDKey)
        if let activePeripheral {
            central.cancelPeripheralConnection(activePeripheral)
        } else {
            connectionState = .idle
        }
        deviceName = nil
        discoveredDevices = []
    }
    private func finishMeasurement() {
        guard liveWeight > 0, let profile, profile.isComplete else { return }
        guard !hasSavedMeasurement else { return }
        hasSavedMeasurement = true
        // Consume the pending stand: the delayed weight-only fallback tasks armed
        // by this stand's stable frames must never fire afterwards with the
        // previous weight (they would re-save and re-present this measurement
        // on the next stand).
        pendingBHWeight = 0
        let isNewMember = profile.shouldSuggestNewMember(for: liveWeight, history: history)
        let member = profile.matchedMember(for: liveWeight, history: history)
        // The connect-time history dump may already have imported this very
        // stand from the scale's memory; adopt that record instead of saving
        // a duplicate of the same weighing.
        if let existing = history.first(where: {
            abs($0.date.timeIntervalSinceNow) < 120 && abs($0.weight - liveWeight) < 0.05 && $0.memberID == member.id
        }) {
            currentMeasurement = existing
            reviewMeasurement = existing
            if isNewMember && unrecognizedWeight == nil { unrecognizedWeight = liveWeight }
            log("[BLE] Live measurement matches an imported stored record; reusing it")
            return
        }
        let measurement = BodyAlgorithm.measure(
            weight: liveWeight,
            impedance: impedance,
            member: member,
            adcIndex: selectedADCIndex,
            rawADCs: rawADCs,
            normalizedImpedances: normalizedImpedances
        )
        currentMeasurement = measurement
        reviewMeasurement = measurement
        history.insert(measurement, at: 0)
        if isNewMember && unrecognizedWeight == nil { unrecognizedWeight = liveWeight }
        saveHistory()
        let isPrimaryMember = member.id == profile.primaryMember.id
        if isPrimaryMember && (!isNewMember || profile.members.isEmpty) {
            healthKit?.save(measurement)
        }
        log("[BLE] Stored stable measurement: weight=\(liveWeight) kg, impedance=\(impedance) Ohm")
    }
    func dismissReview(for measurementID: UUID) {
        if reviewMeasurement?.id == measurementID {
            reviewMeasurement = nil
        }
    }
    func deleteMeasurement(_ measurement: BodyMeasurement) async -> String? {
        do {
            _ = try await healthKit?.delete(measurement)
        } catch {
            log("[HealthKit] Failed to delete measurement \(measurement.id): \(error.localizedDescription)")
            return String(appLocalized: "Apple 健康删除失败：\(error.localizedDescription)。本地记录仍保留，避免留下无法追踪的健康数据。")
        }

        history.removeAll { $0.id == measurement.id }
        if currentMeasurement?.id == measurement.id {
            currentMeasurement = nil
        }
        if reviewMeasurement?.id == measurement.id {
            reviewMeasurement = nil
        }
        saveHistory()
        log("[History] Deleted local measurement and linked HealthKit samples: \(measurement.id)")
        return nil
    }
    @discardableResult
    func mergeRestoredHistory(_ measurements: [BodyMeasurement]) -> Int {
        let existingIDs = Set(history.map(\.id))
        let additions = measurements.filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return 0 }
        history.append(contentsOf: additions)
        history.sort { $0.date > $1.date }
        saveHistory()
        log("[History] Restored \(additions.count) measurements from HealthKit archive")
        return additions.count
    }
    func clearUnrecognizedWeight() { unrecognizedWeight = nil }
    // File restores are local only: never call HealthKit.save or open a measurement review.
    func restoreBackup(_ records: [BodyMeasurement]) {
        history = records.sorted { $0.date > $1.date }
        if let currentMeasurement, let restored = history.first(where: { $0.id == currentMeasurement.id }) {
            self.currentMeasurement = restored
        }
        saveHistory()
    }
    func assignUnrecognizedMeasurement(to member: FamilyMember) {
        guard let measurement = currentMeasurement, let index = history.firstIndex(where: { $0.id == measurement.id }) else { return }
        var updated = BodyAlgorithm.measure(
            id: measurement.id,
            date: measurement.date,
            weight: measurement.weight,
            impedance: measurement.impedance,
            member: member,
            adcIndex: measurement.adcIndex,
            rawADCs: measurement.rawADCs,
            normalizedImpedances: measurement.normalizedImpedances,
            algorithm: BodyAlgorithm.Kind.from(version: measurement.algorithmVersion)
        )
        updated.tags = measurement.tags; updated.note = measurement.note
        currentMeasurement = updated; history[index] = updated; saveHistory()
    }
    /// Manual override for the automatic weight-based member matching: moves a
    /// saved measurement to another member and recomputes its body composition
    /// from that member's profile (same weight and impedance). Apple Health
    /// follows the primary member only — samples are removed when a record
    /// leaves them and written when it becomes theirs.
    func reassignMeasurement(_ measurement: BodyMeasurement, to member: FamilyMember) {
        guard let index = history.firstIndex(where: { $0.id == measurement.id }) else { return }
        let old = history[index]
        guard old.memberID != member.id else { return }
        var updated = BodyAlgorithm.measure(
            id: old.id, date: old.date, weight: old.weight, impedance: old.impedance,
            member: member, adcIndex: old.adcIndex, rawADCs: old.rawADCs,
            normalizedImpedances: old.normalizedImpedances,
            algorithm: BodyAlgorithm.Kind.from(version: old.algorithmVersion)
        )
        updated.tags = old.tags; updated.note = old.note
        history[index] = updated
        if currentMeasurement?.id == old.id { currentMeasurement = updated }
        if reviewMeasurement?.id == old.id { reviewMeasurement = updated }
        saveHistory()
        log("[History] Reassigned measurement \(old.id) to member \(member.name)")
        guard let primaryID = profile?.primaryMember.id else { return }
        if old.memberID == primaryID && member.id != primaryID {
            Task { _ = try? await healthKit?.delete(old) }
        } else if old.memberID != primaryID && member.id == primaryID {
            healthKit?.save(updated)
        }
    }
    private func saveHistory() { if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "afu.scale.history") } }
    private func loadHistory() { if let data = defaults.data(forKey: "afu.scale.history"), let saved = try? JSONDecoder().decode([BodyMeasurement].self, from: data) { history = saved } }
}

extension ScaleManager: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("[BLE] Central manager state updated: \(central.state.rawValue)")
        if central.state == .poweredOn {
            if isScanning {
                connectionState = .scanning
                central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
            } else {
                connectionState = .idle
            }
        } else {
            connectionState = .bluetoothOff
            isScanning = false
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? String(appLocalized: "未知设备")
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let afuData = Self.afuAdvertisementData(
            manufacturerData: manufacturerData,
            serviceData: serviceData
        )
        let isAFU = afuData != nil
        // B1 (薄荷平台) advertises under AFU-BH with FC50 service data instead of the
        // 27AC/0xAC identity, so it is recognized by name prefix alone.
        let isBH = name.uppercased().hasPrefix("AFU-BH")
        let matchesPrefix = name.uppercased().hasPrefix("AFU-WL") || isBH

        guard matchesPrefix, isAFU || isBH else { return }

        log("[BLE] Discovered supported scale: \(name) (\(peripheral.identifier.uuidString)), RSSI: \(RSSI), serviceData: \(serviceData?.keys.map(\.uuidString) ?? [])")
        
        let discoveredMac = Self.macAddress(from: afuData)
        log("[BLE] Discovered scale MAC: \(discoveredMac ?? "nil")")
        
        // QR Scanner auto-connection removed
        
        let pairedID = defaults.string(forKey: Self.pairedPeripheralIDKey)
        let isLegacyPairing = defaults.bool(forKey: "afu.hasPairedScale") && pairedID == nil
        let isKnownPeripheral = pairedID == peripheral.identifier.uuidString
        if isLegacyPairing || isKnownPeripheral {
            log("[BLE] Auto-connecting to paired scale: \(name)")
            connect(DiscoveredScale(peripheral: peripheral, name: name, identifier: peripheral.identifier.uuidString, rssi: RSSI.intValue))
            return
        }
        
        if !discoveredDevices.contains(where: { $0.id == peripheral.identifier }) {
            log("[BLE] Adding device to list: \(name)")
            discoveredDevices.append(DiscoveredScale(peripheral: peripheral, name: name, identifier: peripheral.identifier.uuidString, rssi: RSSI.intValue))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("[BLE] Connected to: \(peripheral.name ?? "nil") (\(peripheral.identifier.uuidString))")
        deviceName = peripheral.name ?? deviceName
        defaults.set(true, forKey: "afu.hasPairedScale")
        defaults.set(peripheral.identifier.uuidString, forKey: Self.pairedPeripheralIDKey)
        connectionState = .connected
        peripheral.delegate = self
        // targetMacAddress reset removed
        log("[BLE] Discovering services for: \(serviceUUID) + \(bhServiceUUID) + \(batteryServiceUUID)")
        peripheral.discoverServices([serviceUUID, bhServiceUUID, batteryServiceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("[BLE] Failed to connect to \(peripheral.name ?? "nil"), error: \(String(describing: error))")
        activePeripheral = nil
        connectionState = .idle
        if defaults.bool(forKey: "afu.hasPairedScale") {
            startScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("[BLE] Disconnected from: \(peripheral.name ?? "nil"), error: \(String(describing: error))")
        connectionState = .idle
        activePeripheral = nil
        liveWeight = 0.0
        batteryLevel = nil
        impedance = 0.0
        selectedADCIndex = nil
        rawADCs = []
        normalizedImpedances = []
        isStable = false
        isMeasuring = false
        hasSavedMeasurement = false
        pendingBHWeight = 0
        bhWriteCharacteristic = nil
        bhWriteQueue = []
        bhWriteInFlight = false
        bhHandshakeDone = false
        bhStoredReceived = false
        bhFinalSentForStand = false
        if defaults.bool(forKey: "afu.hasPairedScale") {
            log("[BLE] Restarting scan after disconnection...")
            startScan()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("[BLE] Service discovery error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("[BLE] No services discovered")
            return
        }
        log("[BLE] Discovered \(services.count) services: \(services.map { $0.uuid.uuidString })")
        services.forEach { service in
            log("[BLE] Discovering characteristics for service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("[BLE] Characteristics discovery error: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else {
            log("[BLE] No characteristics discovered for service: \(service.uuid)")
            return
        }
        log("[BLE] Discovered \(characteristics.count) characteristics for service \(service.uuid): \(characteristics.map { "\($0.uuid.uuidString) (prop: \($0.properties.rawValue))" })")
        
        characteristics.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }.forEach { characteristic in
            log("[BLE] Subscribing to notifications for characteristic: \(characteristic.uuid)")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if service.uuid == bhServiceUUID, let measurement = characteristics.first(where: { $0.uuid == bhMeasurementUUID }) {
            bhMeasurementCharacteristic = measurement
        }
        if service.uuid == bhServiceUUID {
            if let write = characteristics.first(where: { $0.uuid == bhWriteUUID }) {
                bhWriteCharacteristic = write
                log("[BLE] B1 write characteristic ready (properties: \(write.properties.rawValue))")
            }
            startBHHandshakeIfNeeded()
        }
        if service.uuid == batteryServiceUUID, let level = characteristics.first(where: { $0.uuid == batteryLevelUUID }),
           level.properties.contains(.read) {
            peripheral.readValue(for: level)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("[BLE] Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else {
            log("[BLE] Characteristic \(characteristic.uuid) value is empty")
            return
        }
        let hexString = data.map { String(format: "%02hhX", $0) }.joined(separator: " ")
        log("[BLE] Received raw data on \(characteristic.uuid): [\(hexString)] (\(data.count) bytes)")

        if characteristic.uuid == batteryLevelUUID {
            if let byte = data.first { batteryLevel = Int(byte) }
            return
        }

        receive(data)
    }
    
    private static func afuAdvertisementData(
        manufacturerData: Data?,
        serviceData: [CBUUID: Data]?
    ) -> Data? {
        var candidates: [Data] = []

        if let manufacturerData {
            candidates.append(manufacturerData)
        }

        for (uuid, payload) in serviceData ?? [:] {
            guard let uuid16 = uuid16(from: uuid), String(format: "%04X", uuid16).contains("AC") else {
                continue
            }
            var reconstructed = Data([
                UInt8(uuid16 & 0x00FF),
                UInt8((uuid16 >> 8) & 0x00FF)
            ])
            reconstructed.append(payload)
            candidates.append(reconstructed)
        }

        // 与 CLI 相同：0x27 的 flags 表示连接型、体脂秤 category=2、subtype=7。
        return candidates.first { data in
            guard data.count >= 2, data[0] == 0xAC else { return false }
            let flags = data[1]
            let category = (flags & 0x70) >> 4
            let subtype = flags & 0x0F
            return category == 2 && subtype == 7
        }
    }

    private static func uuid16(from uuid: CBUUID) -> UInt16? {
        let value = uuid.uuidString.uppercased()
        let shortValue: String
        if value.count == 4 {
            shortValue = value
        } else if value.hasPrefix("0000"), value.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            shortValue = String(value.dropFirst(4).prefix(4))
        } else {
            return nil
        }
        return UInt16(shortValue, radix: 16)
    }
    
    private static func macAddress(from advertisementData: Data?) -> String? {
        guard let advertisementData, advertisementData.count >= 8, advertisementData[0] == 0xAC else { return nil }
        let macBytes = advertisementData[2..<8].reversed()
        return macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    // MARK: - B1 write side (v1.13): handshake, history dump, acknowledgements

    /// Serialized writes to AF000002: CoreBluetooth allows one outstanding
    /// with-response write, so frames queue and drain on completion.
    private func enqueueBHWrite(_ data: Data, label: String) {
        guard bhWriteCharacteristic != nil else { return }
        bhWriteQueue.append(data)
        log("[BLE] B1 TX queued: \(label)")
        drainBHWriteQueue()
    }

    private func drainBHWriteQueue() {
        guard !bhWriteInFlight, let characteristic = bhWriteCharacteristic,
              let peripheral = activePeripheral, !bhWriteQueue.isEmpty else { return }
        let data = bhWriteQueue.removeFirst()
        if characteristic.properties.contains(.write) {
            bhWriteInFlight = true
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            // No completion callback exists for write-without-response; pace
            // the queue so the scale is not flooded.
            bhWriteInFlight = true
            Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                bhWriteInFlight = false
                drainBHWriteQueue()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("[BLE] B1 write failed: \(error.localizedDescription)")
        }
        if characteristic.uuid == bhWriteUUID {
            bhWriteInFlight = false
            drainBHWriteQueue()
        }
    }

    /// Once per connection: clock sync, the two fixed sync frames, then the
    /// primary member's profile — first the INITIAL variant, then the
    /// HISTORY_DUMP variant that asks the scale to replay its stored records
    /// as 0x54 frames. Without a completed profile the dump is skipped (the
    /// live measurement path does not depend on any of this).
    private func startBHHandshakeIfNeeded() {
        guard !bhHandshakeDone, bhWriteCharacteristic != nil else { return }
        bhHandshakeDone = true
        let epoch = UInt32(Date().timeIntervalSince1970)
        enqueueBHWrite(AFUCommand.timeSync(epochSeconds: epoch), label: "time-sync")
        enqueueBHWrite(AFUCommand.syncFirst(), label: "sync-first")
        enqueueBHWrite(AFUCommand.syncSecond(), label: "sync-second")
        guard let profile, profile.isComplete else {
            log("[BLE] B1 sync sent; profile incomplete, history dump skipped")
            return
        }
        let member = profile.primaryMember
        enqueueBHWrite(
            AFUCommand.profile(variant: .initial, epochSeconds: epoch, userSlot: 0, age: member.age, male: member.sex == .male, targetKg: member.referenceWeight),
            label: "profile-initial"
        )
        enqueueBHWrite(
            AFUCommand.profile(variant: .historyDump, epochSeconds: epoch, userSlot: 0, age: member.age, male: member.sex == .male, targetKg: member.referenceWeight),
            label: "profile-history-dump"
        )
        // One retry if no stored record shows up, mirroring the reference flow.
        Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !bhStoredReceived, bhHandshakeDone, bhWriteCharacteristic != nil else { return }
            enqueueBHWrite(
                AFUCommand.profile(variant: .historyDump, epochSeconds: UInt32(Date().timeIntervalSince1970), userSlot: 0, age: member.age, male: member.sex == .male, targetKg: member.referenceWeight),
                label: "profile-history-dump-retry"
            )
        }
    }

    /// The FINAL profile variant closes the scale-side measurement cycle once
    /// the impedance of the current stand has been acknowledged.
    private func sendBHFinalProfile() {
        guard let profile, profile.isComplete else { return }
        let member = profile.primaryMember
        enqueueBHWrite(
            AFUCommand.profile(variant: .final, epochSeconds: UInt32(Date().timeIntervalSince1970), userSlot: 0, age: member.age, male: member.sex == .male, targetKg: member.referenceWeight),
            label: "profile-final"
        )
    }

    /// Imports one stored weighing replayed by the scale. Records are matched
    /// to a member by weight like live measurements and synced to HealthKit
    /// (at the record's own timestamp, through the same save path as live
    /// measurements), but never presented as a fresh result — they are history.
    private func importStoredRecord(_ record: AFUStoredRecord) {
        guard record.weight > 0, let profile, profile.isComplete else {
            log("[BLE] Stored record skipped (weight: \(record.weight), profile ready: \(profile?.isComplete ?? false))")
            return
        }
        // The scale replays its memory on every dump request, so the same
        // weighing can arrive repeatedly; the two clocks can also drift.
        // Match on a two-minute window and a 50 g weight tolerance.
        let duplicate = history.contains { existing in
            abs(existing.date.timeIntervalSince(record.date)) < 120 && abs(existing.weight - record.weight) < 0.05
        }
        guard !duplicate else {
            log("[BLE] Stored record already in history (\(record.date), \(record.weight) kg); skipped")
            return
        }
        let member = profile.matchedMember(for: record.weight, history: history)
        let measurement = BodyAlgorithm.measure(
            date: record.date,
            weight: record.weight,
            impedance: record.impedance,
            member: member
        )
        history.append(measurement)
        history.sort { $0.date > $1.date }
        saveHistory()
        healthKit?.save(measurement)
        log("[BLE] Stored record imported: \(record.date), weight=\(record.weight) kg, impedance=\(record.impedance) Ohm, member=\(member.name)")
    }

    private func receive(_ data: Data) {
        guard let packet = AFUPacket(data: data) else {
            let hexString = data.map { String(format: "%02hhX", $0) }.joined(separator: " ")
            log("[BLE] Failed to parse raw data packet: [\(hexString)]")
            return
        }
        if data.first == 0xAF, !packet.checksumValid {
            log("[BLE] B1 frame checksum mismatch (type: \(packet.type)); processing anyway")
        }
        log("[BLE] Successfully parsed packet of type: \(packet.type)")
        switch packet.type {
        case .weight:
            // B1: stepping off ends the stand. If a stable weight was seen but the
            // measurement has not been saved yet (the impedance frame may still be
            // pending), settle it now with whatever impedance has been latched,
            // before the generic handling below processes the zero frame.
            if packet.isBHMeasurement && packet.weight < 1.0 && pendingBHWeight > 0 && !hasSavedMeasurement {
                liveWeight = pendingBHWeight
                finishMeasurement()
                pendingBHWeight = 0
            }
            let wasMeasuring = isMeasuring
            liveWeight = packet.weight
            isStable = packet.stable
            isMeasuring = !packet.stable
            connectionState = packet.stable ? .connected : .measuring
            log("[BLE] Weight packet - liveWeight: \(liveWeight), stable: \(isStable)")
            
            // B1 frames interleave freely (an impedance frame may precede the stable
            // weight frame of the same stand), so a BH packet must not trigger the
            // new-measurement impedance reset mid-stand; the < 1 kg condition in
            // this same check still resets everything on step-off.
            if liveWeight < 1.0 || (!wasMeasuring && isMeasuring && !hasSavedMeasurement && !packet.isBHMeasurement) {
                impedance = 0
                selectedADCIndex = nil
                rawADCs = []
                normalizedImpedances = []
            }
            // 稳定包之后的短暂波动仍属于同一次上秤；只有离秤才解锁下一条记录。
            if liveWeight < 1.0 {
                hasSavedMeasurement = false
                // Step-off ends the stand; disarm any fallback still pending for it.
                pendingBHWeight = 0
                bhFinalSentForStand = false
            }
            if isMeasuring && liveWeight > 3.0 {
                currentMeasurement = nil
            }
            
            if packet.stable && impedance > 0 { finishMeasurement() }

            // B1: the impedance value arrives separately in a status frame (subtype
            // 0x52, see docs/PROTOCOL-B1.md) that the scale presents in the same
            // characteristic slot a few seconds after the weight locks — the official
            // app keeps the user standing for the same reason. The .impedance branch
            // (or the gate above) saves as soon as both halves are present, in either
            // order. Meanwhile, actively poll the slot in case the new value is not
            // pushed, and give the whole stand a long window before the weight-only
            // fallback (e.g. socks on, where no impedance ever arrives) settles at
            // the 20 s mark or on step-off, whichever comes first.
            if packet.isBHMeasurement && packet.stable {
                pendingBHWeight = liveWeight
                let weightAtFrame = liveWeight
                if let characteristic = bhMeasurementCharacteristic {
                    for delay in [2.0, 5.0, 9.0, 14.0] {
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            if !hasSavedMeasurement, characteristic.properties.contains(.read) { activePeripheral?.readValue(for: characteristic) }
                        }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if !hasSavedMeasurement, pendingBHWeight == weightAtFrame, pendingBHWeight > 0 {
                        liveWeight = pendingBHWeight
                        finishMeasurement()
                    }
                }
            }
        case .impedance:
            let packetWeight = packet.adcWeight > 0 ? packet.adcWeight : liveWeight
            let normalized = AFUPacket.normalizeImpedances(packet.adcs, weight: packetWeight)
            rawADCs = packet.adcs
            normalizedImpedances = normalized
            // Single-impedance pipeline: adopt the first in-range value.
            if let fallback = normalized.enumerated().first(where: { (100.0...1500.0).contains($0.element) }) {
                impedance = fallback.element
                selectedADCIndex = fallback.offset
            } else {
                impedance = 0
                selectedADCIndex = nil
            }
            let selectedLabel = selectedADCIndex.map { "index \($0)" } ?? "none"
            log("[BLE] Impedance packet - raw ADCs: \(packet.adcs), normalized: \(normalized), selected: \(selectedLabel) = \(impedance)")
            if isStable { finishMeasurement() }
            // B1: acknowledge the impedance frame and close the scale-side
            // cycle with the FINAL profile, as the reference flow does. Only
            // frames flagged valid (byte 2 == 0x01) are acknowledged.
            if packet.raw.first == 0xAF, packet.impedanceValid {
                enqueueBHWrite(AFUCommand.ack(replyType: 0x52), label: "ack-impedance")
                if !bhFinalSentForStand {
                    bhFinalSentForStand = true
                    sendBHFinalProfile()
                }
            }
        case .history:
            if let item = packet.historyMeasurement(profile: profile, history: history) {
                history.insert(item, at: 0)
                saveHistory()
                log("[BLE] History packet - added measurement: \(item)")
            } else {
                log("[BLE] History packet - failed to build history measurement")
            }
        case .stored:
            guard let record = packet.storedRecord else {
                log("[BLE] Stored frame failed checksum/parse; ignored")
                return
            }
            bhStoredReceived = true
            enqueueBHWrite(AFUCommand.ack(replyType: 0x54, correlation: record.sequence), label: "ack-stored-\(record.sequence)")
            importStoredRecord(record)
        case .control:
            if packet.isReportChunk {
                enqueueBHWrite(AFUCommand.ack(replyType: 0x14), label: "ack-report-chunk")
                log("[BLE] Report chunk acknowledged")
            } else {
                log("[BLE] Control frame received (no action)")
            }
        case .settings:
            log("[BLE] Settings packet - ignored")
            break
        }
    }
}
