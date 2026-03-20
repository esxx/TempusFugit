import SwiftUI
import Observation
import UserNotifications
import AVFoundation
import UniformTypeIdentifiers
import Combine

// MARK: - Models

struct CustomSound: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let fileName: String
}

// MARK: - Sound Store

@Observable
final class SoundStore {

    static let shared = SoundStore()
    static let builtIn = ["beeper", "callbell", "chimes", "cuckoo", "oldclock", "shipsbell"]

    var custom: [CustomSound] = []
    private let customSoundsKey = "customSounds_v3"

    var customSoundsDir: URL {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomSounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var libSoundsDir: URL? {
        guard let lib = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        let url = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() { load() }

    func previewURL(for soundID: String) -> URL? {
        if let c = custom.first(where: { $0.id == soundID }) {
            return customSoundsDir.appendingPathComponent(c.fileName)
        }
        return Bundle.main.url(forResource: soundID, withExtension: "caf")
    }

    func notificationSoundName(for soundID: String) -> String {
        if let c = custom.first(where: { $0.id == soundID }) { return c.fileName }
        return "\(soundID).caf"
    }

    func stageForNotifications(soundID: String) {
        guard let libSounds = libSoundsDir else { return }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: libSounds.path) {
            for file in files {
                try? FileManager.default.removeItem(at: libSounds.appendingPathComponent(file))
            }
        }
        let name = notificationSoundName(for: soundID)
        let destURL = libSounds.appendingPathComponent(name)
        if let src = previewURL(for: soundID) {
            try? FileManager.default.copyItem(at: src, to: destURL)
        }
    }

    func importSound(from securedURL: URL) throws -> CustomSound {
        let accessed = securedURL.startAccessingSecurityScopedResource()
        defer { if accessed { securedURL.stopAccessingSecurityScopedResource() } }

        let fileName = securedURL.lastPathComponent
        let destination = customSoundsDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: securedURL, to: destination)

        let sound = CustomSound(
            id: "custom_\(UUID().uuidString)",
            name: securedURL.deletingPathExtension().lastPathComponent,
            fileName: fileName
        )
        DispatchQueue.main.async {
            self.custom.append(sound)
            self.save()
        }
        return sound
    }

    func delete(_ sound: CustomSound) {
        try? FileManager.default.removeItem(at: customSoundsDir.appendingPathComponent(sound.fileName))
        if let lib = libSoundsDir {
            try? FileManager.default.removeItem(at: lib.appendingPathComponent(sound.fileName))
        }
        custom.removeAll { $0.id == sound.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: customSoundsKey)
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: customSoundsKey),
            let sounds = try? JSONDecoder().decode([CustomSound].self, from: data)
        else { return }
        custom = sounds
    }
}

// MARK: - Notification Manager

enum NotificationManager {

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
    }

    private static let allLegacyIDs: [String] =
        (0..<24).map { "chime_\($0)" } +
        (0..<24).map { "hourly_\($0)" } +
        (0..<24).map { "chime_hour_\($0)" }

    static func schedule(hours: Set<Int>, soundID: String, store: SoundStore) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allLegacyIDs)
        center.removeAllPendingNotificationRequests()
        guard !hours.isEmpty else { return }

        store.stageForNotifications(soundID: soundID)

        let soundName = UNNotificationSoundName(rawValue: store.notificationSoundName(for: soundID))
        let sound = UNNotificationSound(named: soundName)

        for hour in hours {
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("notification_title", comment: "Title for notification")
            content.body = String(
                format: NSLocalizedString("notification_body_format", comment: "e.g. 'It's 15:00'"),
                hour
            )
            content.sound = sound

            var dc = DateComponents()
            dc.hour = hour
            dc.minute = 0
            dc.second = 0

            center.add(UNNotificationRequest(
                identifier: "chime_\(hour)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            ))
        }
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allLegacyIDs)
        center.removeAllPendingNotificationRequests()
    }
}

// MARK: - Content View

struct ContentView: View {

    // Persisted
    @AppStorage("chimeEnabled") private var chimeEnabled = false
    @AppStorage("selectedSound") private var selectedSound = "beeper"
    @AppStorage("selectedHoursData") private var selectedHoursData = Data()

    @State private var store = SoundStore.shared

    // Transient UI state
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewingID: String?
    @State private var showFilePicker = false
    @State private var importError: String?

    // For foreground timer
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshFlag = false
    @State private var timer: Timer?          // <-- now a @State property

    // Derived
    var selectedHours: Set<Int> {
        (try? JSONDecoder().decode(Set<Int>.self, from: selectedHoursData)) ?? Set(9...17)
    }

    func setHours(_ hours: Set<Int>) {
        selectedHoursData = (try? JSONEncoder().encode(hours)) ?? Data()
        rescheduleIfActive()
    }

    var nextChime: String {
        let now = Calendar.current.component(.hour, from: Date())
        let hrs = selectedHours.sorted()
        let next = hrs.first(where: { $0 > now }) ?? hrs.first
        guard let n = next else {
            return NSLocalizedString("no_hours_selected", comment: "Displayed when no hours are active")
        }
        return String(format: NSLocalizedString("next_chime_format", comment: "e.g. 'Next chime at 15:00'"), n)
    }

    let presets: [(String, String, Set<Int>)] = [
        ("Work",   "9 – 5",      Set(9...17)),
        ("Waking", "7 – 9 pm",   Set(7...21)),
        ("All day","0 – 23",     Set(0...23)),
        ("Clear",  "none",       Set())
    ]

    // MARK: Timer Management
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            refreshFlag.toggle()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        scheduleSection
                        soundSection
                        tipSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geometry.safeAreaInsets.top)
                    .padding(.bottom, 40)
                }
                .background(Color(.systemBackground))
                .ignoresSafeArea(edges: .top)

                Color.clear
                    .frame(height: geometry.safeAreaInsets.top)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshFlag.toggle()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startTimer()
            } else {
                stopTimer()
            }
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { handleImport($0) }
        .alert(
            NSLocalizedString("import_failed_title", comment: "Alert title for import error"),
            isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button(NSLocalizedString("ok", comment: "OK button")) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Header

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("app_name")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            HStack(spacing: 12) {
                ZStack {
                    Capsule()
                        .fill(chimeEnabled ? Color.green : Color(.systemFill))
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(.white)
                        .frame(width: 22)
                        .offset(x: chimeEnabled ? 10 : -10)
                        .shadow(radius: 1)
                }
                .animation(.smooth(duration: 0.2), value: chimeEnabled)
                .onTapGesture { toggleChime() }

                Text(chimeEnabled
                     ? (selectedHours.isEmpty
                        ? LocalizedStringKey("on_no_hours")
                        : LocalizedStringKey(nextChime))
                     : LocalizedStringKey("off"))
                    .font(.subheadline)
                    .foregroundStyle(chimeEnabled ? .primary : .secondary)
                    .animation(.smooth, value: chimeEnabled)
            }
        }
    }

    // MARK: - Schedule

    var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("schedule")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { name, sub, hours in
                    Button {
                        withAnimation(.smooth(duration: 0.15)) { setHours(hours) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(LocalizedStringKey(name))
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                            Text(LocalizedStringKey(sub))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(0..<24, id: \.self) { hour in
                    let on = selectedHours.contains(hour)
                    Button {
                        withAnimation(.smooth(duration: 0.1)) {
                            var hrs = selectedHours
                            if on { hrs.remove(hour) } else { hrs.insert(hour) }
                            setHours(hrs)
                        }
                    } label: {
                        Text("\(hour)")
                            .font(.system(.caption2, design: .rounded, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(on ? Color.accentColor : Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(String(format: NSLocalizedString("hours_active_format", comment: "e.g. '12 of 24 hours active'"), selectedHours.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sound

    var soundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sound")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            let all: [(id: String, name: String)] =
                (SoundStore.builtIn.map { ($0, $0) } +
                 store.custom.map { ($0.id, $0.name) })
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            VStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.element.id) { i, item in
                    let isSelected = selectedSound == item.id
                    let isCustom = store.custom.contains { $0.id == item.id }

                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)

                        Text(LocalizedStringKey(item.name))
                            .font(.system(.subheadline, design: .rounded,
                                          weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        Spacer()

                        if previewingID == item.id {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor.iterative)
                        }

                        if isCustom {
                            Button(role: .destructive) {
                                deleteCustom(id: item.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSound = item.id
                        rescheduleIfActive()
                        playPreview(id: item.id)
                    }

                    if i < all.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                showFilePicker = true
            } label: {
                Label("import_sound", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }

            Text("supported_formats")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tip

    var tipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("for_sound_only")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 6) {
                Text("tip_instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach([
                    ("lock.fill",                       "lock_screen"),
                    ("list.bullet.rectangle.fill",      "notification_centre"),
                    ("rectangle.topthird.inset.filled", "banners"),
                ], id: \.1) { icon, key in
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.caption2)
                            .frame(width: 14)
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(key + "_off"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("open_settings")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Actions

    func toggleChime() {
        if chimeEnabled {
            chimeEnabled = false
            NotificationManager.cancelAll()
        } else {
            NotificationManager.requestPermission { granted in
                if granted {
                    chimeEnabled = true
                    NotificationManager.schedule(
                        hours: selectedHours, soundID: selectedSound, store: store)
                }
            }
        }
    }

    func rescheduleIfActive() {
        guard chimeEnabled else { return }
        NotificationManager.schedule(hours: selectedHours, soundID: selectedSound, store: store)
    }

    // MARK: - Audio preview

    func playPreview(id: String) {
        guard let url = store.previewURL(for: id) else { return }

        let oldPlayer = previewPlayer
        previewPlayer = nil
        previewingID = id
        selectedSound = id

        DispatchQueue.global(qos: .userInitiated).async {
            oldPlayer?.stop()

            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.play()

                let duration = player.duration

                DispatchQueue.main.async {
                    if previewingID == id {
                        previewPlayer = player
                    } else {
                        player.stop()
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) {
                    if previewingID == id { previewingID = nil }
                }
            } catch {
                DispatchQueue.main.async { previewingID = nil }
            }
        }
    }

    func stopPreview() {
        let player = previewPlayer
        previewPlayer = nil
        previewingID = nil
        DispatchQueue.global(qos: .userInitiated).async {
            player?.stop()
        }
    }

    // MARK: - Import

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            importError = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let sound = try store.importSound(from: url)
                    DispatchQueue.main.async {
                        selectedSound = sound.id
                        rescheduleIfActive()
                    }
                } catch {
                    DispatchQueue.main.async { importError = error.localizedDescription }
                }
            }
        }
    }

    func deleteCustom(id: String) {
        guard let sound = store.custom.first(where: { $0.id == id }) else { return }
        if selectedSound == id { selectedSound = "beeper" }
        store.delete(sound)
        rescheduleIfActive()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
