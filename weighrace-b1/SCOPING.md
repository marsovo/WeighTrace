# WeighTrace — B1 Support Scoping Note

Repo: Xuan-lprk/WeighTrace @ e7a179a (cloned 2026-10-26). Almost all BLE logic lives in two
files: `体脂秤/Services/ScaleManager.swift` (589 lines) and `体脂秤/Services/AFUPacket.swift`
(128 lines). Line numbers below are from this checkout.

## 1. Advertisement acceptance / filtering (name prefix + category/subtype gate)

- `体脂秤/Services/ScaleManager.swift:334-367` — `centralManager(_:didDiscover:advertisementData:rssi:)`.
  A device is accepted only if BOTH pass (`guard matchesPrefix, isAFU else { return }`, L346):
  - Name prefix: L343 — `name.uppercased().hasPrefix("AFU-WL")` (name from
    `CBAdvertisementDataLocalNameKey` ?? `peripheral.name`).
  - Protocol identity: `isAFU = afuAdvertisementData(...) != nil` (L339-344).
- Scan itself is unfiltered (`startScan()`, L176-202; `scanForPeripherals(withServices: nil)`)
  — all filtering happens in `didDiscover`, so a B1 that fails the gate is silently dropped
  before it ever reaches the pairing list. (UI copy in `体脂秤/Views/PairingView.swift:21`
  states the same rule.)
- **Patch:** this is the primary gate to widen — accept the B1's name prefix (once known)
  and relax/replace the `afuAdvertisementData` identity check for the B1 variant; nothing
  upstream of it needs changing.

## 2. 27AC service-data parsing (connection type / category / subtype / MAC)

- `体脂秤/Services/ScaleManager.swift:463-492` — `static func afuAdvertisementData(manufacturerData:serviceData:) -> Data?`.
  - Candidates: manufacturer data as-is, plus each Service Data entry whose 16-bit UUID's
    hex string contains "AC" (in practice `0x27AC`; matched loosely, L476, helper
    `uuid16(from:)` at L495-506). The entry is reconstructed as `[UUID low byte, UUID high
    byte] + payload`, yielding `data[0] == 0xAC`, `data[1] == flags` (0x27 on the A1).
  - Gate (L487-491): `flags = data[1]`; `category = (flags & 0x70) >> 4`;
    `subtype = flags & 0x0F`; accepted iff `category == 2 && subtype == 7`. (Connection-type
    bits of the flags byte are decoded only implicitly — not checked.)
- `体脂秤/Services/ScaleManager.swift:508-512` — `static func macAddress(from:)`:
  requires `data[0] == 0xAC`, MAC = bytes `2..<8` reversed, colon-formatted.
- **Patch:** parameterize the accepted (category, subtype) set / flags byte for the B1 and
  verify the B1's Service Data UUID and payload layout match the 0xAC reconstruction; MAC
  offset (`2..<8`) must be re-validated if the B1 payload differs.

## 3. Measurement notification parsing (D5 / D6 / D8 / DF) and GATT UUIDs

- GATT service: `体脂秤/Services/ScaleManager.swift:48` —
  `serviceUUID = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")` (FFB0);
  `didConnect` discovers only this service (L369-383).
- Characteristic: **FFB2 is not hard-coded anywhere in the app** (it appears only in
  docs/PROTOCOL.md). `peripheral(_:didDiscoverCharacteristicsFor:)` (L430-445) subscribes to
  *every* characteristic with `.notify`/`.indicate` on the discovered service, and
  `peripheral(_:didUpdateValueFor:)` (L447-461) forwards all values to `receive(_:)`.
- Dispatch: `体脂秤/Services/ScaleManager.swift:514-588` — `receive(_:)` switches on
  `AFUPacket.Kind` (weight / impedance / history / settings→ignored).
- Packet decode: `体脂秤/Services/AFUPacket.swift:3-128`, `struct AFUPacket`,
  `init?(data:)` at L7-27:
  - 0xAC-wrapped form: requires `count >= 20` and `data.first == 0xAC`; opcode is
    `data[18]` — `0xD5`→weight, `0xD6`→impedance (ADC), `0xD8`→history, `0xDF`→settings.
  - Legacy fallback: first byte is the opcode directly (same D5/D6/D8/DF mapping).
  - Field decoders: `weight` (L56-69; AC form uses a 3-byte encoding at bytes 3-5),
    `stable` (L46-54; AC form = status byte 6 == 0x02), `adcs` (L72-86), `adcWeight`
    (L88-94), `historyMeasurement(profile:history:)` (L113-127).
- **Patch:** if the B1 keeps FFB0 + the same D5/D6/D8/DF framing, no change needed here;
  otherwise this is where a variant opcode map / field offsets would go — capture a real
  weighing notification from the B1 and diff it against `AFUPacket.init` first.

## 4. Device identity / binding (could it reject an unknown device?)

- Binding key: `体脂秤/Services/ScaleManager.swift:47` —
  `pairedPeripheralIDKey = "afu.pairedPeripheralID"`, plus the flag `afu.hasPairedScale`.
- Written in `didConnect` (L376-377): on *any* successful connection the app sets
  `hasPairedScale = true` and stores that peripheral's `identifier.uuidString`
  ("last connected wins" — no allow-list check in `connect(_:)`, L203-212).
- Used in `didDiscover` (L354-364): if the stored ID matches the discovered peripheral
  (or a legacy pairing flag exists), it auto-connects instead of listing the device.
  Cleared by `forgetPairedScale()` (L213-224).
- The README's "设备身份绑定" is this CoreBluetooth **peripheral UUID** binding, **not**
  MAC-based: `macAddress(from:)` is called once (L349) and only logged. There is no
  MAC/name allow-list anywhere (code comments note the old MAC-target and QR auto-connect
  were removed).
- **Patch:** no change needed for B1 support — binding cannot reject a new device;
  worst case a stale stored UUID (e.g. after an iOS restore changes peripheral IDs)
  prevents auto-connect, and the user just picks the scale manually / uses 忘记设备.
  The only real blocker for a B1 remains the discovery gate in §1–§2.

## Bottom line for a B1 patch

1. First capture the B1's advertisement (nRF Connect scan + one weighing log) to learn its
   broadcast name, Service Data UUID, and flags byte — everything hinges on §1/§2 values.
2. Widen the two checks in `ScaleManager.swift` (`hasPrefix` at L343, flags test at
   L487-491) — likely a small accepted-variants table rather than a rewrite.
3. Only if its notification framing differs, extend `AFUPacket` (§3). Binding (§4) is a
   non-issue.
