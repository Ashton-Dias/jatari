import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SoundPreviewer {
    private var player: AVAudioPlayer?
    private(set) var playingID: String?

    func toggle(id: String, url: URL?) {
        if playingID == id { stop(); return }
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play(); player = p; playingID = id
    }

    func stop() { player?.stop(); player = nil; playingID = nil }
}

struct SoundPickerView: View {
    @Binding var selection: String
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomSound.name) private var sounds: [CustomSound]
    @State private var previewer = SoundPreviewer()
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var renaming: CustomSound?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(SoundLibrary.builtIns) { sound in
                    row(id: sound.id, name: sound.name, url: SoundLibrary.url(for: sound.id, customSounds: sounds))
                }
            } header: {
                Text("Built-in").legibleOverArt()
            }
            .listRowBackground(RowFill())
            Section {
                ForEach(sounds) { sound in
                    row(id: sound.soundID, name: sound.name, url: SoundLibrary.url(for: sound.soundID, customSounds: sounds))
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(sound) }
                            Button("Rename") { newName = sound.name; renaming = sound }.tint(.blue)
                        }
                }
                Button { importing = true } label: { Label("Add from Files…", systemImage: "square.and.arrow.down") }
            } header: {
                Text("Your sounds").legibleOverArt()
            } footer: {
                Text("Sounds longer than \(Int(SoundLibrary.maxDuration)) seconds are trimmed, because iOS limits alarm sounds to 30 seconds.")
                    .legibleOverArt()
            }
            .listRowBackground(RowFill())
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .font(.app(.body))
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewer.stop() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importSound(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn't add sound", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Name your sound", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $newName)
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if let s = renaming, !trimmed.isEmpty { s.name = trimmed; try? context.save() }
                renaming = nil
            }
        } message: { Text(infoMessage ?? "") }
    }

    private func row(id: String, name: String, url: URL?) -> some View {
        HStack {
            Button { selection = id } label: {
                HStack {
                    Image(systemName: "checkmark").opacity(selection == id ? 1 : 0).foregroundStyle(.orange)
                    Text(name)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { previewer.toggle(id: id, url: url) } label: {
                Image(systemName: previewer.playingID == id ? "stop.circle.fill" : "play.circle")
                    .font(.app(.title3))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(previewer.playingID == id ? "Stop preview" : "Preview \(name)")
        }
    }

    private func importSound(_ url: URL) {
        let baseName = url.deletingPathExtension().lastPathComponent
        do {
            let sound = try SoundLibrary.importSound(from: url, name: baseName)
            context.insert(sound)
            try context.save()
            selection = sound.soundID
            infoMessage = sound.wasTrimmed ? "This file was longer than 30 seconds, so it was trimmed." : "Give it a name you'll recognise."
            newName = baseName
            renaming = sound
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ sound: CustomSound) {
        previewer.stop()
        if selection == sound.soundID { selection = SoundLibrary.defaultSoundID }
        // Alarms using it fall back to the default sound.
        for alarm in (try? context.fetch(FetchDescriptor<AlarmItem>())) ?? [] where alarm.soundID == sound.soundID {
            alarm.soundID = SoundLibrary.defaultSoundID
        }
        SoundLibrary.delete(sound)
        context.delete(sound)
        try? context.save()
    }
}
