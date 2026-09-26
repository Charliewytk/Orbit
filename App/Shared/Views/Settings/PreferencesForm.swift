import SwiftUI
import OrbitCore

/// The scheduling and study preferences, used by both Settings and onboarding.
struct PreferencesSections: View {
    @Binding var prefs: UserPrefs

    /// Mon…Sun with `UserPrefs.restDays` numbering (1 = Sunday … 7 = Saturday).
    private static let weekdays: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        Section {
            MinutePicker(title: "Day starts", minutes: $prefs.dayStart)
            MinutePicker(title: "Day ends", minutes: $prefs.dayEnd)
            MinutePicker(title: "No uni work after", minutes: $prefs.workCutoff)
            Stepper("Max focus a day: \(Fmt.duration(prefs.maxFocusMinutesPerDay))",
                    value: $prefs.maxFocusMinutesPerDay, in: 60...720, step: 30)
            Stepper("Buffer between things: \(prefs.bufferMinutes) min", value: $prefs.bufferMinutes, in: 0...45, step: 5)
        } header: {
            Text("Your day")
        } footer: {
            Text("Orbit only plans work inside these hours.")
        }

        Section("Meals") {
            mealRow("Lunch", range: $prefs.lunch, defaultRange: (12 * 60 + 30)...(13 * 60 + 15))
            mealRow("Dinner", range: $prefs.dinner, defaultRange: (18 * 60 + 30)...(19 * 60 + 15))
        }

        Section {
            ForEach(prefs.energyWindows.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Energy", selection: $prefs.energyWindows[i].energy) {
                        Text("High (deep work)").tag(Energy.high)
                        Text("Medium").tag(Energy.medium)
                        Text("Low (admin, reading)").tag(Energy.low)
                    }
                    HStack {
                        MinutePicker(title: "From", minutes: $prefs.energyWindows[i].start)
                        MinutePicker(title: "to", minutes: $prefs.energyWindows[i].end)
                    }
                }
            }
            .onDelete { prefs.energyWindows.remove(atOffsets: $0) }
            Button {
                prefs.energyWindows.append(EnergyWindow(start: 19 * 60, end: 21 * 60, energy: .low))
            } label: {
                Label("Add energy window", systemImage: "plus")
            }
        } header: {
            Text("Energy")
        } footer: {
            Text("Hard tasks go in your high-energy hours.")
        }

        Section("Rest days") {
            HStack(spacing: 4) {
                ForEach(Self.weekdays.indices, id: \.self) { index in
                    let day = Self.weekdays[index]
                    let on = prefs.restDays.contains(day.0)
                    Button {
                        if on { prefs.restDays.remove(day.0) } else { prefs.restDays.insert(day.0) }
                    } label: {
                        Text(day.1)
                            .font(Theme.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                            .background(on ? Theme.selection : Theme.hover,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section {
            Stepper("Target: \(Int(prefs.targetGrade))%", value: $prefs.targetGrade, in: 40...90, step: 1)
            MinutePicker(title: "Morning brief", minutes: $prefs.morningBriefTime)
            MinutePicker(title: "Evening review", minutes: $prefs.eveningReviewTime)
        } header: {
            Text("Goals & briefs")
        } footer: {
            Text("70% is a First. The weekly “on track?” review arrives on Sunday evening.")
        }
    }

    @ViewBuilder
    private func mealRow(_ title: String, range: Binding<ClosedRange<MinuteOfDay>?>,
                         defaultRange: ClosedRange<MinuteOfDay>) -> some View {
        Toggle(title, isOn: Binding(get: { range.wrappedValue != nil },
                                    set: { range.wrappedValue = $0 ? defaultRange : nil }))
        if let r = range.wrappedValue {
            HStack {
                MinutePicker(title: "From", minutes: Binding(get: { r.lowerBound }, set: { new in
                    range.wrappedValue = min(new, r.upperBound)...max(new, r.upperBound)
                }))
                MinutePicker(title: "to", minutes: Binding(get: { r.upperBound }, set: { new in
                    range.wrappedValue = min(r.lowerBound, new)...max(r.lowerBound, new)
                }))
            }
        }
    }
}

/// Important senders (lecturers, landlord, employer): always notified.
struct ImportantSendersSection: View {
    @Binding var prefs: UserPrefs
    @State private var newSender = ""

    var body: some View {
        Section {
            ForEach(prefs.importantSenders, id: \.self) { s in
                Text(s)
            }
            .onDelete { prefs.importantSenders.remove(atOffsets: $0) }
            HStack {
                TextField("name@exeter.ac.uk or @domain.com", text: $newSender)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newSender.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Important senders")
        } footer: {
            Text("Mail from these always notifies you and is sorted to the top.")
        }
    }

    private func add() {
        let s = newSender.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, !prefs.importantSenders.contains(s) else { return }
        prefs.importantSenders.append(s)
        newSender = ""
    }
}
