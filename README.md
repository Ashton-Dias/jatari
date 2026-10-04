# Jatari ("Gratitude")

An iOS alarm clock with two kinds of alarm:

| | Normal alarm | Phrase alarm |
| --- | --- | --- |
| Turned on by | "Require phrase to stop" **off** | "Require phrase to stop" **on**, with a phrase of 8+ characters |
| Alert buttons | **Stop** (turns it off) and **Snooze** (rings again after 3 minutes) | **Stop** only, which opens the app to the phrase screen. **No snooze** |
| Ends when | You press Stop | You type the phrase correctly |

There is no default phrase: an alarm only has a phrase challenge if you turn it on and choose the phrase.

- 7 built-in tones (`SOUNDS.md`) and 3 sample alarms on first launch (one phrase alarm, two normal)
- Import your own sound from Files (converted to CAF, trimmed to 30 s, previewable, renameable, deletable)
- Optional strict (case/punctuation) phrase matching; paste is disabled in the phrase field
- Delete alarms with swipe, the Edit button, press-and-hold, or the Delete button in the editor

## How ringing works
1. Alarms are scheduled with **AlarmKit** (rings through silent mode and Focus, shows on the lock screen).
2. **Normal alarms** use AlarmKit's countdown behavior for Snooze (`AlarmTiming.snoozeSeconds` = 180 s). The system handles
   Stop and Snooze; the app isn't involved. The **PhraseAlarmWidgets** extension draws the snooze countdown Live Activity.
3. **Phrase alarms** have no secondary button. Stop runs `StopAlarmIntent` (`openAppWhenRun`), which opens the app to the
   phrase screen, **keeps ringing from inside the app**, and arms a backup AlarmKit alarm 60 s out. Stopping again re-arms it.
   Only the correct phrase cancels everything.
4. If AlarmKit access is denied, the app falls back to local notifications: normal alarms get one notification with a
   Snooze action (3 min); phrase alarms get a chain of notifications every 60 s until the phrase is typed.
5. If a ringing alarm's record no longer exists (for example it was deleted), the app ends it cleanly rather than leaving you
   on a screen with nothing to type.

## Limits (iOS)
- Nothing can stop you **force-quitting the app, switching the phone off, or muting/lowering volume** where the system
  allows it. If you swipe the app away mid-way through a phrase alarm, the backup alarm / notification chain still fires
  and reopens the flow, but it can't be made unkillable.
- Alarm and notification sounds are limited to 30 s.
- The notification fallback is only as loud as the user's notification settings.

## Project layout
- `MyApp/`: the app. `Shared/`: code compiled into both the app and the widget extension (`PhraseAlarmMetadata`, `AlarmTiming`).
- `PhraseAlarmWidgets/`: Widget Extension for AlarmKit's Live Activity. `PhraseAlarmTests/`: unit tests.

## Build & test
```
xcodebuild -project "Untitled Project.xcodeproj" -scheme MyApp -destination 'id=<iOS 27 simulator id>' test
```
Launch flags for screenshots: `-previewList`, `-previewEditMode`, `-previewEditor` (phrase alarm), `-previewEditorNormal`,
`-previewEditorBottom`, `-previewDeleteConfirm`, `-previewRinging`.
