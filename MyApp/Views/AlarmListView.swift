import SwiftUI
import SwiftData

struct AlarmListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\AlarmItem.hour), SortDescriptor(\AlarmItem.minute)]) private var alarms: [AlarmItem]
    @Query private var sounds: [CustomSound]
    @State private var editing: AlarmItem?
    @State private var creating = false
    @State private var pendingDelete: AlarmItem?
    @State private var editMode: EditMode = ProcessInfo.processInfo.arguments.contains("-previewEditMode") ? .active : .inactive

    var body: some View {
        NavigationStack {
            List {
                ForEach(alarms) { alarm in
                    AlarmRow(alarm: alarm, onToggle: { AlarmStore.resync(in: context) }, onTap: { editing = alarm })
                        .listRowBackground(Card().padding(.horizontal, 12))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 28))
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = alarm }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = alarm }
                        }
                }
                .onDelete(perform: delete)
            }
            .listStyle(.plain)
            .listRowSpacing(8)
            .scrollContentBackground(.hidden)
            .appBackground()
            .environment(\.editMode, $editMode)
            .overlay {
                if alarms.isEmpty {
                    ContentUnavailableView("No Alarms", systemImage: "alarm", description: Text("Tap + to add one."))
                }
            }
            .navigationTitle("Gratitude")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().disabled(alarms.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Test normal alarm in 10 seconds", systemImage: "bell") {
                            guard let a = alarms.first(where: { !$0.isPhraseAlarm }) else { return }
                            Task { await AlarmScheduler.shared.scheduleTest(for: a, sounds: sounds) }
                        }
                        .disabled(!alarms.contains { !$0.isPhraseAlarm })
                        Button("Test phrase alarm in 10 seconds", systemImage: "bell.badge") {
                            guard let a = alarms.first(where: \.isPhraseAlarm) else { return }
                            Task { await AlarmScheduler.shared.scheduleTest(for: a, sounds: sounds) }
                        }
                        .disabled(!alarms.contains(where: \.isPhraseAlarm))
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add alarm")
                }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { alarm in
                Button("Delete Alarm", role: .destructive) { AlarmStore.delete(alarm, in: context) }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-previewEditor") || $0 == "-previewDeleteConfirm" }) {
                    try? await Task.sleep(for: .seconds(1))
                    editing = ProcessInfo.processInfo.arguments.contains("-previewEditorNormal")
                        ? alarms.first { !$0.isPhraseAlarm } : alarms.first { $0.isPhraseAlarm }
                }
            }
            .sheet(item: $editing) { alarm in
                AlarmEditorView(alarm: alarm, onSave: { AlarmStore.resync(in: context) })
                    .presentationBackground { AppBackground() }
            }
            .sheet(isPresented: $creating) {
                AlarmEditorView(alarm: nil, onSave: { AlarmStore.resync(in: context) })
                    .presentationBackground { AppBackground() }
            }
        }
    }

    private var deleteTitle: String {
        guard let a = pendingDelete else { return "Delete alarm?" }
        return "Delete \"\(a.label.isEmpty ? a.timeString : a.label)\"?"
    }

    /// Swipe and the red minus button in edit mode delete immediately, like the system Clock app.
    private func delete(at offsets: IndexSet) {
        for i in offsets { AlarmStore.delete(alarms[i], in: context) }
    }
}

private struct AlarmRow: View {
    @Bindable var alarm: AlarmItem
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.timeString)
                    .font(.appSize(52, weight: .regular, relativeTo: .largeTitle))
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(alarm.isEnabled ? Color.white : Color.white.opacity(0.8))
                HStack(spacing: 6) {
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                    Text("·")
                    Text(ScheduleLogic.repeatSummary(Set(alarm.weekdays)))
                    if alarm.isPhraseAlarm { Image(systemName: "keyboard").accessibilityLabel("Phrase required") }
                }
                .font(.app(.subheadline))
                .foregroundStyle(Theme.secondaryText)
            }
            .shadow(color: .black.opacity(0.65), radius: 3, x: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the alarm editor")

            Toggle("Enabled", isOn: $alarm.isEnabled)
                .labelsHidden()
                .tint(.orange)
                .onChange(of: alarm.isEnabled) { _, _ in onToggle() }
        }
        .padding(.vertical, 6)
    }
}
