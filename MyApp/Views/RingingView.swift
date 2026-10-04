import SwiftUI
import UIKit

/// Full-screen phrase challenge. There is intentionally no close, dismiss, or snooze control.
struct RingingView: View {
    private let coordinator = RingCoordinator.shared
    @State private var typed = ""
    @State private var succeeded = false

    private var alarm: AlarmItem? { coordinator.ringingAlarm }
    /// Empty only if the alarm is gone or isn't a phrase alarm; in that case the screen ends itself (see `.task`).
    private var phrase: String { alarm?.phraseToType ?? "" }
    private var strict: Bool { alarm?.strictMatch ?? false }

    var body: some View {
        ZStack {
            AppBackground(dim: 0.45)
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 44)).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.2))
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.appSize(72, weight: .light, relativeTo: .largeTitle))
                        .minimumScaleFactor(0.5)
                }
                Text(alarm?.label.isEmpty == false ? alarm!.label : "Alarm")
                    .font(.app(.title2, weight: .semibold))

                VStack(spacing: 12) {
                    Text("Type this phrase to turn off the alarm")
                        .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                    phraseText
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Phrase to type: \(phrase)")
                    PhraseField(text: $typed, onChange: check)
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Type the phrase here")
                    Text(strict ? "Capitalization and punctuation must match." : "Capitalization doesn't matter.")
                        .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                }
                .padding(20)
                .background { Card(radius: 20, opacity: 0.55, blurred: true) }
                .padding(.horizontal)
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .interactiveDismissDisabled()
        .task {
            // Nothing to type means nothing to solve (for example the alarm was deleted): never trap the user here.
            if phrase.isEmpty { coordinator.dismiss() }
        }
    }

    private var phraseText: Text {
        var out = AttributedString()
        for (ch, state) in PhraseMatcher.feedback(typed: typed, phrase: phrase, strict: strict) {
            var piece = AttributedString(String(ch))
            piece.foregroundColor = switch state { case .correct: .green; case .wrong: .red; case .pending: .white.opacity(0.85) }
            out.append(piece)
        }
        return Text(out)
    }

    private func check(_ value: String) {
        guard !succeeded, PhraseMatcher.matches(typed: value, phrase: phrase, strict: strict) else { return }
        succeeded = true
        coordinator.dismiss()
    }
}

/// A text field that cannot be pasted into and has no autocorrect/prediction/smart punctuation,
/// so the phrase has to be typed by hand, character for character.
private struct PhraseField: UIViewRepresentable {
    @Binding var text: String
    let onChange: (String) -> Void

    final class NoPasteField: UITextField {
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(UIResponderStandardEditActions.paste(_:)) { return false }
            return super.canPerformAction(action, withSender: sender)
        }
        /// Take focus as soon as the field is actually on screen (the full-screen cover may still be animating in
        /// when the field is created), and again whenever the app returns to the foreground.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refocus), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        @objc private func refocus() { if window != nil, !isFirstResponder { _ = becomeFirstResponder() } }
        deinit { NotificationCenter.default.removeObserver(self) }
    }

    func makeUIView(context: Context) -> NoPasteField {
        let f = NoPasteField()
        f.delegate = context.coordinator
        f.placeholder = "Type here"
        f.textColor = .white
        f.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.smartInsertDeleteType = .no
        f.returnKeyType = .done
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.async { f.becomeFirstResponder() }
        return f
    }

    func updateUIView(_ uiView: NoPasteField, context: Context) {
        if uiView.text != text { uiView.text = text }
        if !uiView.isFirstResponder { DispatchQueue.main.async { uiView.becomeFirstResponder() } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: PhraseField
        init(_ parent: PhraseField) { self.parent = parent }
        @objc func changed(_ f: UITextField) {
            parent.text = f.text ?? ""
            parent.onChange(f.text ?? "")
        }
        // Keep the keyboard up: the return key does nothing.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { false }
        func textFieldShouldEndEditing(_ textField: UITextField) -> Bool { false }
    }
}
