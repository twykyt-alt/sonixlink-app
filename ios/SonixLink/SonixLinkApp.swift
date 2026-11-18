import SwiftUI
import Combine
@preconcurrency import CoreBluetooth

@main
struct SonixLinkApp: App {
    var body: some Scene { WindowGroup { RemoteView() } }
}

private let serviceID = CBUUID(string: "D54B0001-6B7D-4D13-A2F1-91F9B5D89001")
private let stateID   = CBUUID(string: "D54B0002-6B7D-4D13-A2F1-91F9B5D89001")
private let commandID = CBUUID(string: "D54B0003-6B7D-4D13-A2F1-91F9B5D89001")

@MainActor
final class BLERemote: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Searching for SonixOS"
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var position = 0
    @Published var duration = 0
    @Published var volume = 50

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var poll: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "org.sonix.link.central"])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { status = "Bluetooth unavailable"; return }
        status = "Searching for SonixOS"
        central.scanForPeripherals(withServices: [serviceID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                       advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        status = "Connecting to \(p.name ?? "Sonix player")"
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Connected"
        p.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        poll?.invalidate(); poll = nil
        stateCharacteristic = nil; commandCharacteristic = nil
        status = "Disconnected — searching"
        central.scanForPeripherals(withServices: [serviceID])
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        restored.delegate = self
        status = "Reconnecting to \(restored.name ?? "Sonix player")"
        central.connect(restored)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connection failed — searching"
        central.scanForPeripherals(withServices: [serviceID])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == serviceID }) else { return }
        p.discoverCharacteristics([stateID, commandID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == stateID { stateCharacteristic = c; p.readValue(for: c) }
            if c.uuid == commandID { commandCharacteristic = c }
        }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak p] _ in
            guard let self, let p, let c = self.stateCharacteristic else { return }
            p.readValue(for: c)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == stateID, let data = c.value else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = obj["title"] as? String ?? ""
                artist = obj["artist"] as? String ?? ""
                playing = (obj["playing"] as? Bool) ?? false
                position = obj["position"] as? Int ?? 0
                duration = obj["duration"] as? Int ?? 0
                volume = obj["volume"] as? Int ?? volume
        }
    }

    func send(_ command: String, value: Int? = nil) {
        guard let p = peripheral, let c = commandCharacteristic else { return }
        let op: UInt8
        switch command { case "play": op = 0; case "pause": op = 1; case "toggle": op = 2
        case "next": op = 3; case "prev": op = 4; case "seek": op = 5; case "volume": op = 6
        default: return }
        var data = Data([op])
        var arg = Int32(value ?? 0).littleEndian
        withUnsafeBytes(of: &arg) { data.append(contentsOf: $0) }
        p.writeValue(data, for: c, type: .withResponse)
    }
}

struct RemoteView: View {
    @StateObject private var remote = BLERemote()
    var body: some View {
        VStack(spacing: 18) {
            Text("SonixLink").font(.largeTitle.bold())
            Text(remote.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(remote.title.isEmpty ? "Nothing playing" : remote.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(remote.artist).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(remote.position) }, set: { remote.send("seek", value: Int($0)) }), in: 0...Double(max(remote.duration, 1)))
            HStack {
                Button { remote.send("prev") } label: { Image(systemName: "backward.end.fill") }
                Button { remote.send(remote.playing ? "pause" : "play") } label: { Image(systemName: remote.playing ? "pause.fill" : "play.fill") }.font(.largeTitle)
                Button { remote.send("next") } label: { Image(systemName: "forward.end.fill") }
            }.buttonStyle(.bordered).font(.title2)
            HStack { Image(systemName: "speaker.fill"); Slider(value: Binding(get: { Double(remote.volume) }, set: { remote.volume = Int($0); remote.send("volume", value: Int($0)) }), in: 0...100) }
            Spacer()
        }.padding(24)
    }
}
