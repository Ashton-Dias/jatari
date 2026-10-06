import SwiftUI
import SwiftData

struct AlarmEditorView: View {
    let alarm: AlarmItem?
    let onSave: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var sounds: [CustomSound]

    @State private var time = Date()
    @State private var weekdays: Set<Int> = []
    @State private var label = "Alarm"
    @State private var soundID = SoundLibrary.defaultSoundID
    @State private var requiresPhrase = false
    @State private var phrase = ""
    @State private var strict = false
    @State private var loaded = false
    @State private var confirmingDelete = ProcessInfo.processInfo.arguments.contains("-previewDeleteConfirm")

    private var phraseOK: Bool { !requiresPhrase || PhraseMatcher.isValidPhrase(phrase) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(RowFill())
                Section {
                    HStack(spacing: 6) {
                        ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { i, symbol in
                            let day = i + 1
                            Button { toggle(day) } label: {
                                Text(symbol).font(.app(.subheadline, weight: .bold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(weekdays.contains(day) ? Color.orange : Color.white.opacity(0.12), in: Circle())
                                    .foregroundStyle(weekdays.contains(day) ? .black : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[i])
                            .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                        }
                    }
                    Text(ScheduleLogic.repeatSummary(weekdays)).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                } header: {
                    Text("Repeat").legibleOverArt()
                }
                .listRowBackground(RowFill())
                Section {
                    TextField("Label", text: $label)
                    NavigationLink {
                        SoundPickerView(selection: $soundID)
                    } label: {
                        LabeledContent("Sound", value: SoundLibrary.displayName(for: soundID, customSounds: sounds))
                    }
                }
                .listRowBackground(RowFill())
                Section {
                    Toggle("Require phrase to stop", isOn: $requiresPhrase).tint(.orange)
                    if requiresPhrase {
                        TextField("Phrase to type", text: $phrase, axis: .vertical)
                            .accessibilityIdentifier("phraseField")
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: phrase) { _, new in
                                // Smart Punctuation would store curly quotes and long dashes that the ringing keyboard can't type.
                                let plain = PhraseMatcher.foldPunctuation(new)
                                if plain != new { phrase = plain }
                            }
                        Toggle("Match capitalization & punctuation", isOn: $strict).tint(.orange)
                        if !phraseOK {
                            Text("Use at least \(PhraseMatcher.minimumLength) characters.").font(.app(.footnote)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                        }
                    }
                }
                .listRowBackground(RowFill())

                if let alarm {
                    Section {
                        Button("Delete Alarm", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity)
                            .id("deleteButton")
                            .disabled(RingCoordinator.shared.ringingAlarmID == alarm.id)
                    }
                    .listRowBackground(RowFill())
                }
            }
            .scrollContentBackground(.hidden)
            .appBackground()
            .font(.app(.body))
            .task {
                if ProcessInfo.processInfo.arguments.contains("-previewEditorBottom") {
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation { proxy.scrollTo("deleteButton", anchor: .bottom) }
                }
            }
            .confirmationDialog("Delete \"\(alarm.map { $0.label.isEmpty ? $0.timeString : $0.label } ?? "")\"?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Alarm", role: .destructive) {
                    if let alarm, AlarmStore.delete(alarm, in: context) { dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle(alarm == nil ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!phraseOK) }
            }
            .onAppear(perform: load)
            }
        }
    }

    private func toggle(_ day: Int) {
        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let a = alarm else {
            time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
            return
        }
        time = Calendar.current.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: .now) ?? .now
        weekdays = Set(a.weekdays); label = a.label; soundID = a.soundID
        requiresPhrase = a.requiresPhrase; phrase = a.phrase; strict = a.strictMatch
    }

    private func save() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let target = alarm ?? AlarmItem(hour: 0, minute: 0)
        target.hour = c.hour ?? 7; target.minute = c.minute ?? 0
        target.weekdays = weekdays.sorted(); target.label = label; target.soundID = soundID
        target.requiresPhrase = requiresPhrase; target.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        target.strictMatch = strict; target.isEnabled = true
        if alarm == nil { context.insert(target) }
        onSave()
        dismiss()
    }
}
