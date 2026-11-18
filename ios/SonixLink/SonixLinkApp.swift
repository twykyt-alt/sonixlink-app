import SwiftUI
import Combine
@preconcurrency import CoreBluetooth
import SQLite3

private let bleService = CBUUID(string: "D54B0001-6B7D-4D13-A2F1-91F9B5D89001")
private let bleState = CBUUID(string: "D54B0002-6B7D-4D13-A2F1-91F9B5D89001")
private let bleCommand = CBUUID(string: "D54B0003-6B7D-4D13-A2F1-91F9B5D89001")

struct Track: Identifiable, Hashable {
    var id: String { path }
    var title: String
    var artist: String
    var album: String = ""
    var path: String
    var filter: String = ""
    var kind: String = "track"
}

@MainActor final class Sonix: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var host = UserDefaults.standard.string(forKey: "sonix.host") ?? ""
    @Published var port = 7800
    @Published var status = "Enter the R1 address, or connect over BLE"
    @Published var tab = "Tracks"
    @Published var rows: [Track] = []
    @Published var queue: [Track] = []
    @Published var history: [Track] = []
    @Published var queueFirst = 0
    @Published var queueRevision: Int64 = -1
    @Published var queuePosition = -1
    @Published var queueCount = 0
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var position = 0
    @Published var duration = 0
    @Published var volume = 50
    @Published var mode = "normal"
    @Published var favourite = false
    @Published var nowPlayingPath = ""
    @Published var search = ""
    @Published var folderPath = ""
    @Published var busy = false
    @Published var error = ""
    private var db: OpaquePointer?
    private var base = ""
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var stateChar: CBCharacteristic?
    private var timer: Timer?
    private let browser = NetServiceBrowser()
    private var listKind = "all"
    private var listValue = ""

    override init() {
        super.init(); central = CBCentralManager(delegate: self, queue: .main)
        browser.delegate = self; browser.searchForServices(ofType: "_sonixlink._tcp.", inDomain: "local.")
    }
    deinit { if let db { sqlite3_close(db) } }

    func connect() {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { error = "Enter the player's IP address"; return }
        host = h; UserDefaults.standard.set(h, forKey: "sonix.host"); base = "http://\(h):\(port)"
        Task { await syncLibrary() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let name=sender.hostName, !name.isEmpty, base.isEmpty else { return }
        host = name.trimmingCharacters(in: CharacterSet(charactersIn:".")); port = sender.port
        connect()
    }

    private func request(_ route: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: base + route) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30); req.httpMethod = method; req.httpBody = body
        if body != nil { req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SonixLink", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Player request failed"])
        }
        return data
    }

    private func download(_ route: String, to destination: URL) async throws {
        guard let url=URL(string:base+route) else { throw URLError(.badURL) }
        var req=URLRequest(url:url,timeoutInterval:180); req.httpMethod="GET"
        let (temporary,response)=try await URLSession.shared.download(for:req)
        guard let http=response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain:"SonixLink",code:(response as? HTTPURLResponse)?.statusCode ?? -1,userInfo:[NSLocalizedDescriptionKey:"Could not download the library index"])
        }
        try? FileManager.default.removeItem(at:destination)
        try FileManager.default.moveItem(at:temporary,to:destination)
    }

    func syncLibrary() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            _ = try await request("/api/info")
            let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("library.db")
            try await download("/api/db",to:file)
            if let db { sqlite3_close(db); self.db = nil }
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "SonixLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open the player's library"]) }
            status = "Connected to \(host)"; tab = "Tracks"; loadRows(); await refreshState(); await refreshQueue()
            timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { await self?.refreshState() } }
        } catch { self.error = error.localizedDescription; status = "Could not connect" }
    }

    private func query(_ sql: String, _ args: [String] = []) -> [Track] {
        guard let db else { return [] }; var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), (value as NSString).utf8String, -1, nil) }
        var out: [Track] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ n: Int32) -> String {
                guard let text=sqlite3_column_text(stmt,n) else { return "" }
                return String(cString:UnsafeRawPointer(text).assumingMemoryBound(to:CChar.self))
            }
            out.append(Track(title: col(0), artist: col(1), album: col(2), path: col(3), filter: col(4), kind: col(5)))
        }
        return out
    }

    func loadRows() {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab == "Folders" { Task { await loadFolder(folderPath) }; return }
        if !q.isEmpty {
            listKind="all"; listValue=""
            let like = "%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            rows = query("SELECT * FROM (SELECT name AS t,artist AS a,album AS b,path AS p,'' AS f,'track' AS k FROM MEDIA_TABLE WHERE path<>'' AND (name LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\') UNION ALL SELECT album,'',album,album,'album','album' FROM ALBUM_TABLE WHERE album LIKE ? ESCAPE '\\' UNION ALL SELECT artist,'','',artist,'artist','artist' FROM ARTIST_TABLE WHERE artist LIKE ? ESCAPE '\\') ORDER BY t LIMIT 500", [like,like,like,like,like]); return
        }
        switch tab {
        case "Albums": rows = query("SELECT album,'',album,album,'album','album' FROM ALBUM_TABLE WHERE album<>'' ORDER BY sortkey,album")
        case "Artists": rows = query("SELECT artist,'','',artist,'artist','artist' FROM ARTIST_TABLE WHERE artist<>'' ORDER BY sortkey,artist")
        case "Album Artists": rows = query("SELECT album_artist,'','',album_artist,'album_artist','album_artist' FROM ALBUM_ARTIST_TABLE WHERE album_artist<>'' ORDER BY sortkey,album_artist")
        case "Favourites": rows = query("SELECT name,artist,'',path,'','track' FROM FAVOURITES ORDER BY added_at")
        case "Playlists": rows = query("SELECT substr(name,5),'','',substr(name,5),'playlist','playlist' FROM sqlite_master WHERE type='table' AND name LIKE 'M3U_%' ORDER BY name")
        case "Genres": rows = query("SELECT genre,'','',genre,'genre','genre' FROM GENRE_TABLE WHERE genre<>'' ORDER BY sortkey,genre")
        default: rows = query("SELECT name,artist,album,path,'','track' FROM MEDIA_TABLE WHERE path<>'' ORDER BY sortkey,rowid LIMIT 10000")
        }
    }

    func selectTab(_ name: String) {
        tab=name; search=""; listValue=""
        switch name { case "Albums": listKind="albums"; case "Artists": listKind="artist"; case "Album Artists": listKind="album_artist"; case "Genres": listKind="genre"; case "Playlists": listKind="playlist"; case "Favourites": listKind="favourites"; case "Folders": listKind="folder"; default: listKind="all" }
        loadRows()
        if name == "Playlists" || name == "Favourites" { Task { await loadLiveRows(for: name) } }
    }
    var playlistNames: [String] { rowsForPlaylists.map(\.title) }
    private var rowsForPlaylists: [Track] {
        if tab == "Playlists" { return rows }
        return query("SELECT substr(name,5),'','',substr(name,5),'playlist','playlist' FROM sqlite_master WHERE type='table' AND name LIKE 'M3U_%' ORDER BY name")
    }

    private func loadLiveRows(for name: String) async {
        guard !base.isEmpty else { return }
        do {
            let route = name == "Favourites" ? "/api/favourites" : "/api/playlists"
            let data = try await request(route)
            let key = name == "Favourites" ? "favourites" : "playlists"
            let items = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?[key] as? [[String: Any]] ?? []
            let result = items.compactMap { item -> Track? in
                if name == "Favourites" {
                    guard let path = item["path"] as? String, !path.isEmpty else { return nil }
                    return Track(title: item["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent,
                                 artist: item["artist"] as? String ?? "", path: path)
                }
                guard let title = item["name"] as? String, !title.isEmpty else { return nil }
                return Track(title: title, artist: "", path: title, kind: "playlist")
            }
            guard tab == name else { return }
            rows = result
        } catch { self.error = error.localizedDescription }
    }

    func loadFolder(_ path: String) async {
        guard !base.isEmpty else { return }
        do {
            var c=URLComponents(string:base+"/api/browse")!; c.queryItems=path.isEmpty ? nil : [URLQueryItem(name:"path",value:path)]
            let data=try await request(c.url!.absoluteString.replacingOccurrences(of:base,with:""))
            let j=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            folderPath=j["path"] as? String ?? path; listKind="folder"; listValue=folderPath
            rows=(j["entries"] as? [[String:Any]] ?? []).compactMap { e in
                guard let p=e["path"] as? String else{return nil}; let isDir=e["dir"] as? Bool ?? false
                return Track(title:e["name"] as? String ?? URL(fileURLWithPath:p).lastPathComponent,artist:"",path:p,kind:isDir ? "folder" : "track")
            }
        } catch { self.error=error.localizedDescription }
    }

    func open(_ row: Track) {
        if row.kind == "track" { Task { await play(row) }; return }
        switch row.kind {
        case "folder": Task { await loadFolder(row.path) }
        case "album": listKind="album"; listValue=row.title; rows = query("SELECT name,artist,album,path,'','track' FROM MEDIA_TABLE WHERE album=? AND path<>'' ORDER BY COALESCE(disc,1),dis_id,sortkey", [row.path])
        case "artist": listKind="artist"; listValue=row.title; rows = query("SELECT name,album,album,path,'','track' FROM MEDIA_TABLE WHERE artist=? AND path<>'' ORDER BY sortkey", [row.path])
        case "album_artist": listKind="album_artist"; listValue=row.title; rows = query("SELECT name,album,album,path,'','track' FROM MEDIA_TABLE WHERE album_artist=? AND path<>'' ORDER BY sortkey", [row.path])
        case "genre": listKind="genre"; listValue=row.title; rows = query("SELECT name,artist,album,path,'','track' FROM MEDIA_TABLE WHERE genre=? AND path<>'' ORDER BY sortkey", [row.path])
        case "playlist":
            listKind="playlist"; listValue=row.title
            Task { do { var c=URLComponents(string:base+"/api/playlist")!; c.queryItems=[URLQueryItem(name:"name",value:row.title)]; let d=try await request(c.url!.absoluteString.replacingOccurrences(of:base,with:"")); let j=try JSONSerialization.jsonObject(with:d) as? [String:Any] ?? [:]; rows=(j["tracks"] as? [[String:Any]] ?? []).compactMap { x in guard let p=x["path"] as? String else{return nil}; return Track(title:x["title"] as? String ?? URL(fileURLWithPath:p).lastPathComponent,artist:x["artist"] as? String ?? "",path:p) } } catch { self.error=error.localizedDescription } }
        default: break
        }
        if row.kind != "folder" { tab = row.title }
    }

    func play(_ row: Track) async {
        await command("play_path", ["path":row.path,"list":listKind,"value":listValue])
    }
    func playAll(_ how: String) async { await command("play_all",["list":listKind,"value":listValue,"how":how]) }

    func command(_ action: String, _ args: [String: String] = [:]) async {
        if !base.isEmpty {
            var c = URLComponents(string: base + "/api/command")!; c.queryItems = [URLQueryItem(name: "do", value: action)] + args.map { URLQueryItem(name: $0.key, value: $0.value) }
            do { var r = URLRequest(url: c.url!); r.httpMethod = "POST"; _ = try await URLSession.shared.data(for: r); await refreshState(); if action == "favourite", tab == "Favourites" { await loadLiveRows(for: "Favourites") }; return }
            catch { self.error = error.localizedDescription }
        }
        let op: UInt8? = ["play":0,"pause":1,"toggle":2,"next":3,"prev":4,"seek":5,"volume":6][action]
        if let op, let p = peripheral, let ch = commandChar {
            var n = Int32(Int(args["value"] ?? "0") ?? 0).littleEndian
            var d = Data([op]); withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }; p.writeValue(d, for: ch, type: .withResponse)
        }
    }

    func selection(_ action: String, paths: [String], value: String = "") async {
        guard !base.isEmpty, !paths.isEmpty else { return }
        do { var c=URLComponents(string:base+"/api/command")!; c.queryItems=[URLQueryItem(name:"do",value:action)]; if !value.isEmpty { c.queryItems?.append(URLQueryItem(name:"value",value:value)) }; var r=URLRequest(url:c.url!); r.httpMethod="POST"; r.httpBody=Data(paths.joined(separator:"\n").utf8); r.setValue("text/plain; charset=utf-8",forHTTPHeaderField:"Content-Type"); _=try await URLSession.shared.data(for:r); await refreshQueue() } catch { self.error = error.localizedDescription }
    }

    private func refreshState() async {
        guard !base.isEmpty else { return }
        do { let data = try await request("/api/state"); let j = try JSONSerialization.jsonObject(with: data) as? [String:Any] ?? [:]
            title = j["title"] as? String ?? ""; artist = j["artist"] as? String ?? ""; playing = (j["state"] as? Int) == 1
            position = j["position"] as? Int ?? 0; duration = j["duration"] as? Int ?? 0; volume = j["volume"] as? Int ?? volume
            mode=j["mode"] as? String ?? mode; favourite=j["favourite"] as? Bool ?? false; nowPlayingPath=j["path"] as? String ?? ""
        } catch { }
    }
    func refreshQueue() async {
        guard !base.isEmpty else { return }
        do { let data = try await request("/api/queue"); let j = try JSONSerialization.jsonObject(with: data) as? [String:Any] ?? [:]
            queueFirst = j["first"] as? Int ?? 0
            queueRevision = (j["revision"] as? NSNumber)?.int64Value ?? -1
            queuePosition = j["position"] as? Int ?? -1
            queueCount = j["count"] as? Int ?? 0
            let paths = j["paths"] as? [String] ?? []; queue = paths.map { p in query("SELECT name,artist,album,path,'','track' FROM MEDIA_TABLE WHERE path=? LIMIT 1", [p]).first ?? Track(title: URL(fileURLWithPath:p).lastPathComponent, artist:"", path:p) }
            if let h=try? await request("/api/history?limit=100"), let hj=try? JSONSerialization.jsonObject(with:h) as? [String:Any] {
                history=(hj["items"] as? [[String:Any]] ?? []).compactMap { x in guard let p=x["path"] as? String else{return nil}; return Track(title:x["title"] as? String ?? URL(fileURLWithPath:p).lastPathComponent,artist:x["artist"] as? String ?? "",path:p,filter:String(x["id"] as? Int ?? 0),kind:"history") }
            }
        } catch { self.error = error.localizedDescription }
    }
    func removeQueueRows(_ offsets: IndexSet) async {
        let indices = offsets.map { queueFirst + $0 }.filter { queuePosition < 0 || $0 > queuePosition }
        guard !indices.isEmpty, queueRevision >= 0, !base.isEmpty else { return }
        do { var c=URLComponents(string:base+"/api/command")!; c.queryItems=[URLQueryItem(name:"do",value:"queue_remove"),URLQueryItem(name:"rev",value:"\(queueRevision)")]; var r=URLRequest(url:c.url!); r.httpMethod="POST"; r.httpBody=Data(indices.map { String($0) }.joined(separator:"\n").utf8); r.setValue("text/plain; charset=utf-8",forHTTPHeaderField:"Content-Type"); _=try await URLSession.shared.data(for:r); await refreshQueue() } catch { self.error=error.localizedDescription }
    }
    func moveQueueRow(from source: IndexSet, to destination: Int) async {
        guard let local=source.first, queueRevision >= 0 else { return }
        let from=queueFirst+local; var to=queueFirst+destination
        if local < destination { to -= 1 }
        guard from > queuePosition, to > queuePosition, from != to else { return }
        await command("queue_move",["from":"\(from)","to":"\(to)","rev":"\(queueRevision)"])
        await refreshQueue()
    }
    func insertHistory(_ item: Track) async {
        let slot=max(queuePosition+1,0)
        await command("history_insert",["id":item.filter,"at":"\(slot)","rev":"\(queueRevision)"])
        await refreshQueue()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { status = "BLE ready — scan for SonixOS"; central.scanForPeripherals(withServices: [bleService]) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String:Any], rssi: NSNumber) {
        central.stopScan(); peripheral = p; p.delegate = self; central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { status = "BLE connected"; p.discoverServices([bleService]) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { p.services?.first(where: {$0.uuid == bleService}).map { p.discoverCharacteristics([bleState,bleCommand], for: $0) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandChar = service.characteristics?.first(where: {$0.uuid == bleCommand})
        stateChar = service.characteristics?.first(where: {$0.uuid == bleState})
        if let stateChar {
            p.readValue(for: stateChar); timer?.invalidate()
            timer=Timer.scheduledTimer(withTimeInterval:1.5,repeats:true) { [weak p,weak self] _ in
                guard let self, let p, let c=self.stateChar else{return}; p.readValue(for:c)
            }
        }
        status = "BLE remote connected"
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == bleState, let data=characteristic.value,
              let j=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        title=j["title"] as? String ?? ""; artist=j["artist"] as? String ?? ""; playing=j["playing"] as? Bool ?? false
        position=j["position"] as? Int ?? 0; duration=j["duration"] as? Int ?? 0; volume=j["volume"] as? Int ?? volume
    }
}

@main struct SonixLinkApp: App {
    var body: some Scene { WindowGroup { SonixRoot().environmentObject(Sonix()) } }
}

struct SonixRoot: View {
    @EnvironmentObject var app: Sonix
    private let tabs = ["Tracks","Albums","Artists","Album Artists","Genres","Playlists","Favourites","Folders"]
    var body: some View {
        TabView {
            NavigationStack { browse }.tabItem { Label("Library", systemImage:"music.note.list") }
            NavigationStack { searchView }.tabItem { Label("Search", systemImage:"magnifyingglass") }
            NavigationStack { queueView }.tabItem { Label("Queue", systemImage:"text.line.first.and.arrowtriangle.forward") }
            NavigationStack { playerView }.tabItem { Label("Playing", systemImage:"play.circle") }
        }.alert("SonixLink", isPresented: Binding(get:{!app.error.isEmpty},set:{if !$0 {app.error=""}})) { Button("OK") { app.error="" } } message: { Text(app.error) }
    }
    var connectBar: some View { HStack { TextField("R1 IP address",text:$app.host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("Connect") { app.connect() }.disabled(app.busy) }.padding(.horizontal) }
    var browse: some View {
        VStack(spacing:0) { connectBar; Text(app.status).font(.caption).foregroundStyle(.secondary); ScrollView(.horizontal) { HStack { ForEach(tabs,id:\.self) { t in Button(t) { app.selectTab(t) }.buttonStyle(.borderedProminent).tint(app.tab == t ? .accentColor : .gray) } }.padding(8) }
            List(app.rows) { row in Button { app.open(row) } label: { HStack { if row.kind == "track" { AsyncImage(url:URL(string:"http://\(app.host):7800/api/art?path=\(row.path.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? "")&max=96")) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName:"music.note") }.frame(width:48,height:48).clipShape(RoundedRectangle(cornerRadius:5)) }; VStack(alignment:.leading) { Text(row.title); Text(row.artist.isEmpty ? row.album : row.artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); if row.kind != "track" { Text(row.filter.isEmpty ? "" : row.kind).font(.caption).foregroundStyle(.secondary) } } }.contextMenu { if row.kind == "track" { Button("Play") { Task { await app.play(row) } }; Button("Add to queue") { Task { await app.selection("queue_next",paths:[row.path]) } }; Button("Favourite") { Task { await app.command("favourite",["path":row.path]) } }; if !app.playlistNames.isEmpty { Menu("Add to playlist") { ForEach(app.playlistNames,id:\.self) { name in Button(name) { Task { await app.selection("playlist_add",paths:[row.path],value:name) } } } } } } } }
        }.navigationTitle(app.tab == "Folders" && !app.folderPath.isEmpty ? URL(fileURLWithPath:app.folderPath).lastPathComponent : app.tab).toolbar { if app.tab == "Folders" && !app.folderPath.isEmpty { Button("Up") { let parent=URL(fileURLWithPath:app.folderPath).deletingLastPathComponent().path; Task { await app.loadFolder(parent == "/" ? "" : parent) } } }; Menu("Play list") { Button("In order") { Task { await app.playAll("sequence") } }; Button("Shuffle") { Task { await app.playAll("shuffle") } }; Button("Play a random track next") { Task { await app.playAll("random") } } }; Button("Sync") { Task { await app.syncLibrary() } } }
    }
    var searchView: some View { VStack { connectBar; TextField("Search tracks, artists, albums",text:$app.search).textFieldStyle(.roundedBorder).padding().onChange(of:app.search) { _ in app.loadRows() }; List(app.rows) { row in Button { app.open(row) } label: { VStack(alignment:.leading){Text(row.title);Text(row.artist).font(.caption).foregroundStyle(.secondary)} } } }.navigationTitle("Search") }
    var queueView: some View { List { Section("Queue") { ForEach(Array(app.queue.enumerated()),id:\.offset) { i,row in Button { Task { await app.command("queue_index",["value":"\(app.queueFirst+i)"]) } } label: { HStack { Text("\(app.queueFirst+i+1)").foregroundStyle(.secondary); VStack(alignment:.leading){Text(row.title);Text(row.artist).font(.caption).foregroundStyle(.secondary)} } } }.onDelete { offsets in Task { await app.removeQueueRows(offsets) } }.onMove { source,destination in Task { await app.moveQueueRow(from:source,to:destination) } } }; Section("Recently played") { ForEach(app.history) { item in Button { Task { await app.command("history_play",["id":item.filter]) } } label: { VStack(alignment:.leading) { Text(item.title); Text(item.artist).font(.caption).foregroundStyle(.secondary) } }.contextMenu { Button("Play next") { Task { await app.command("history_play",["id":item.filter]) } }; Button("Insert after current") { Task { await app.insertHistory(item) } } } } } }.navigationTitle("Queue · \(app.queueCount)").toolbar { EditButton(); Button("Refresh") { Task { await app.refreshQueue() } } } }
    var playerView: some View { VStack(spacing:20) { connectBar; Spacer(); if !app.nowPlayingPath.isEmpty { AsyncImage(url:URL(string:"http://\(app.host):7800/api/art?path=\(app.nowPlayingPath.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? "")&max=640")) { $0.resizable().scaledToFit() } placeholder: { RoundedRectangle(cornerRadius:12).fill(.quaternary).overlay(Image(systemName:"music.note").font(.largeTitle)) }.frame(maxHeight:300).clipShape(RoundedRectangle(cornerRadius:12)) }; Text(app.title.isEmpty ? "Nothing playing" : app.title).font(.title2.bold()).multilineTextAlignment(.center); Text(app.artist).foregroundStyle(.secondary); Slider(value:Binding(get:{Double(app.position)},set:{app.position=Int($0);Task{await app.command("seek",["value":"\(Int($0))"])}}),in:0...Double(max(app.duration,1))); HStack { Button { Task{await app.command("prev")} } label:{Image(systemName:"backward.end.fill")}; Button { Task{await app.command(app.playing ? "pause":"play")} } label:{Image(systemName:app.playing ? "pause.fill":"play.fill")}.font(.largeTitle); Button { Task{await app.command("next")} } label:{Image(systemName:"forward.end.fill")} }.buttonStyle(.bordered); HStack { Image(systemName:"speaker.fill"); Slider(value:Binding(get:{Double(app.volume)},set:{app.volume=Int($0);Task{await app.command("volume",["value":"\(Int($0))"])}}),in:0...100) }; HStack { Button(app.favourite ? "★ In favourites":"☆ Favourite") { Task{await app.command("favourite",["path":app.nowPlayingPath])} }; Menu("Mode: \(app.mode)") { ForEach(["normal","repeat_all","repeat_one","shuffle","shuffle_repeat"],id:\.self) { m in Button(m.replacingOccurrences(of:"_",with:" ")) { Task{await app.command("mode",["value":m])} } } } }; Spacer() }.padding().navigationTitle("Now Playing") }
}
