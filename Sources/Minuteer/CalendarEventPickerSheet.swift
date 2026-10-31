import SwiftUI
import MinuteerCore

struct CalendarEventPickerSheet: View {
    @Bindable var model: AppModel
    let file: AudioRecordingFile
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery: String = ""
    @State private var searchResults: [CalendarEventInfo] = []
    @State private var isSearching: Bool = false
    @State private var isRequestingPermission: Bool = false
    @State private var selectedDate: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link Calendar Event")
                        .font(.headline)
                    Text("Associate this recording with a scheduled meeting to name and organize your note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if !model.isCalendarAuthorized {
                VStack(spacing: 16) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 6) {
                        Text("Calendar Access Required")
                            .font(.headline)
                        Text("Minuteer needs access to your macOS calendars to find meetings matching the recording time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }

                    Button {
                        isRequestingPermission = true
                        Task {
                            _ = await model.requestCalendarAccess()
                            model.loadCalendarEvents(for: file)
                            isRequestingPermission = false
                        }
                    } label: {
                        if isRequestingPermission {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Grant Calendar Access")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search title, calendar, location, attendees...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .onChange(of: searchQuery) { _, newQuery in
                                performSearch(query: newQuery)
                            }
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                                searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    // Day Navigation Bar
                    HStack(spacing: 8) {
                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                            model.loadCalendarEvents(for: file, date: selectedDate)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .help("Previous Day")

                        DatePicker(
                            "",
                            selection: $selectedDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .onChange(of: selectedDate) { _, newDate in
                            model.loadCalendarEvents(for: file, date: newDate)
                        }

                        Button {
                            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                            model.loadCalendarEvents(for: file, date: selectedDate)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .help("Next Day")

                        Spacer()

                        if !Calendar.current.isDateInToday(selectedDate) {
                            Button("Today") {
                                selectedDate = Date()
                                model.loadCalendarEvents(for: file, date: selectedDate)
                            }
                            .controlSize(.small)
                        }

                        if !Calendar.current.isDate(selectedDate, inSameDayAs: file.creationDate) {
                            Button("File Date") {
                                selectedDate = file.creationDate
                                model.loadCalendarEvents(for: file, date: selectedDate)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4))

                    Divider()

                    // Event list
                    let displayedEvents = searchQuery.isEmpty ? model.candidateCalendarEvents : searchResults
                    if displayedEvents.isEmpty {
                        VStack(spacing: 8) {
                            if model.isLoadingCalendarEvents || isSearching {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Loading calendar events...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "calendar")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text(searchQuery.isEmpty ? "No meetings scheduled on \(formattedDate(selectedDate))." : "No matching calendar events found.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            if searchQuery.isEmpty {
                                Section(calendarDateHeaderTitle) {
                                    ForEach(displayedEvents) { event in
                                        eventRow(event)
                                    }
                                }
                            } else {
                                Section("Search Results (\(displayedEvents.count) found)") {
                                    ForEach(displayedEvents) { event in
                                        eventRow(event)
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }

                    Divider()

                    HStack {
                        if file.calendarEvent != nil {
                            Button("Unlink Calendar Event", role: .destructive) {
                                model.associateCalendarEvent(file: file, event: nil)
                                dismiss()
                            }
                            .controlSize(.small)
                        }

                        Spacer()

                        Button("Cancel") {
                            dismiss()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .frame(width: 560, height: 490)
        .onAppear {
            if model.isCalendarAuthorized {
                let initialDate = Calendar.current.isDateInToday(file.creationDate) ? file.creationDate : Date()
                selectedDate = initialDate
                model.loadCalendarEvents(for: file, date: initialDate)
            }
        }
    }

    private var calendarDateHeaderTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let count = model.candidateCalendarEvents.count
        let countSuffix = "(\(count) \(count == 1 ? "meeting" : "meetings"))"
        if Calendar.current.isDateInToday(selectedDate) {
            return "Today's Meetings • \(countSuffix)"
        } else {
            return "\(formatter.string(from: selectedDate)) • \(countSuffix)"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func eventRow(_ event: CalendarEventInfo) -> some View {
        let isSelected = file.calendarEvent?.id == event.id
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(Color(hex: event.calendarColorHex ?? "#007AFF"))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if isSelected {
                        Text("Linked")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(event.formattedTimeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(event.calendarTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let location = event.location, !location.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !event.attendees.isEmpty {
                    Text("Attendees: \(event.attendees.prefix(3).joined(separator: ", "))\(event.attendees.count > 3 ? ", +\(event.attendees.count - 3) more" : "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Button("Unlink") {
                    model.associateCalendarEvent(file: file, event: nil)
                    dismiss()
                }
                .controlSize(.small)
            } else {
                Button("Link") {
                    model.associateCalendarEvent(file: file, event: event)
                    dismiss()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func performSearch(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        let start = selectedDate.addingTimeInterval(-86400 * 30)
        let end = selectedDate.addingTimeInterval(86400 * 30)
        Task {
            let res = await model.searchCalendarEvents(query: query, start: start, end: end)
            await MainActor.run {
                self.searchResults = res
                self.isSearching = false
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 122, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
