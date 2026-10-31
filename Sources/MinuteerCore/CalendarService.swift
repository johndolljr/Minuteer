import Foundation
#if canImport(EventKit)
@preconcurrency import EventKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct CalendarEventInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var calendarTitle: String
    public var calendarColorHex: String?
    public var location: String?
    public var notes: String?
    public var attendees: [String]
    public var isAllDay: Bool

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarTitle: String = "Calendar",
        calendarColorHex: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        attendees: [String] = [],
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.isAllDay = isAllDay
    }

    public var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)
        return "\(startStr) – \(endStr)"
    }

    public var cleanLocation: (displayText: String, url: URL?)? {
        guard let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else {
            return nil
        }
        if let url = URL(string: loc), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            let host = url.host?.lowercased() ?? ""
            if host.contains("zoom.us") {
                return ("Zoom Meeting", url)
            } else if host.contains("teams.microsoft.com") {
                return ("Microsoft Teams Meeting", url)
            } else if host.contains("meet.google.com") {
                return ("Google Meet", url)
            } else if host.contains("webex.com") {
                return ("Webex Meeting", url)
            } else {
                return (host.isEmpty ? "Video Call" : host, url)
            }
        }
        return (loc, nil)
    }

    public var cleanNotes: String? {
        guard let raw = notes, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Self.sanitizeCalendarNotes(raw)
    }

    public static func sanitizeCalendarNotes(_ raw: String) -> String? {
        // 1. Convert HTML line breaks to real newlines
        var text = raw
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</div>", with: "\n", options: .regularExpression)

        // 2. Strip HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // 3. Decode common HTML entities
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // 4. Split into lines and filter out email headers, dial-in info, and invite boilerplates
        let rawLines = text.components(separatedBy: "\n")
        var usefulLines: [String] = []

        let headerPatterns = [
            "^--+original appointment",
            "^--+forwarded message",
            "^from:",
            "^sent:",
            "^to:",
            "^cc:",
            "^subject:",
            "^when:",
            "^where:"
        ]

        let boilerplatePatterns = [
            "join zoom meeting",
            "microsoft teams meeting",
            "join microsoft teams",
            "meeting id:",
            "passcode:",
            "one tap mobile",
            "dial by your location",
            "find your local number",
            "join with a video conferencing device",
            "is inviting you to a scheduled zoom meeting",
            "is inviting you to a scheduled meeting",
            "https?://.*zoom\\.us",
            "https?://.*teams\\.microsoft\\.com",
            "https?://meet\\.google\\.com"
        ]

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()

            let isHeader = headerPatterns.contains { pattern in
                lower.range(of: pattern, options: .regularExpression) != nil
            }
            if isHeader { continue }

            let isBoilerplate = boilerplatePatterns.contains { pattern in
                lower.range(of: pattern, options: .regularExpression) != nil
            }
            if isBoilerplate { continue }

            if lower.range(of: "^[\\+0-9\\s\\-\\(\\)\\,\\#]+$", options: .regularExpression) != nil {
                continue
            }

            usefulLines.append(trimmed)
        }

        let result = usefulLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

public enum CalendarAuthorizationStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct DiscoveredCalendarInfo: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var colorHex: String
    public var sourceTitle: String

    public init(id: String, title: String, colorHex: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.sourceTitle = sourceTitle
    }
}

public protocol CalendarService: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    func requestAccess() async -> Bool
    func fetchEvents(around date: Date, duration: TimeInterval) async throws -> [CalendarEventInfo]
    func searchEvents(query: String, start: Date, end: Date) async throws -> [CalendarEventInfo]
    func listCalendars() -> [DiscoveredCalendarInfo]
}

public final class MockCalendarService: CalendarService, @unchecked Sendable {
    public var mockEvents: [CalendarEventInfo]
    public var mockStatus: CalendarAuthorizationStatus
    public var requestAccessResult: Bool
    public var mockCalendars: [DiscoveredCalendarInfo]

    public init(
        mockEvents: [CalendarEventInfo] = [],
        mockStatus: CalendarAuthorizationStatus = .authorized,
        requestAccessResult: Bool = true,
        mockCalendars: [DiscoveredCalendarInfo] = [
            DiscoveredCalendarInfo(id: "cal-1", title: "Work", colorHex: "#007AFF", sourceTitle: "iCloud"),
            DiscoveredCalendarInfo(id: "cal-2", title: "Personal", colorHex: "#34C759", sourceTitle: "iCloud")
        ]
    ) {
        self.mockEvents = mockEvents
        self.mockStatus = mockStatus
        self.requestAccessResult = requestAccessResult
        self.mockCalendars = mockCalendars
    }

    public func listCalendars() -> [DiscoveredCalendarInfo] {
        return mockStatus == .authorized ? mockCalendars : []
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        return mockStatus
    }

    public func requestAccess() async -> Bool {
        if requestAccessResult {
            mockStatus = .authorized
        } else {
            mockStatus = .denied
        }
        return requestAccessResult
    }

    public func fetchEvents(around date: Date, duration: TimeInterval) async throws -> [CalendarEventInfo] {
        guard mockStatus == .authorized else {
            return []
        }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay: Date
        if let next = cal.date(byAdding: .day, value: 1, to: startOfDay) {
            endOfDay = next
        } else {
            endOfDay = startOfDay.addingTimeInterval(86400)
        }
        return mockEvents.filter { event in
            event.endDate >= startOfDay && event.startDate <= endOfDay
        }.sorted { $0.startDate < $1.startDate }
    }

    public func searchEvents(query: String, start: Date, end: Date) async throws -> [CalendarEventInfo] {
        guard mockStatus == .authorized else {
            return []
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mockEvents.filter { event in
            let matchesRange = event.endDate >= start && event.startDate <= end
            if !cleanQuery.isEmpty {
                let matchesQuery = event.title.lowercased().contains(cleanQuery)
                    || (event.location?.lowercased().contains(cleanQuery) == true)
                    || (event.notes?.lowercased().contains(cleanQuery) == true)
                return matchesRange && matchesQuery
            }
            return matchesRange
        }.sorted { $0.startDate < $1.startDate }
    }
}

public final class SystemCalendarService: CalendarService, @unchecked Sendable {
    public static let shared = SystemCalendarService()

    #if canImport(EventKit)
    private let eventStore = EKEventStore()
    public var eventStoreRunner: ((NSPredicate) -> [EKEvent])?
    #endif

    public var customStatus: (@Sendable () -> CalendarAuthorizationStatus)?
    public var customRequestAccess: (@Sendable () async -> Bool)?
    public var customFetcher: (@Sendable (Date, TimeInterval) async throws -> [CalendarEventInfo])?
    public var customSearcher: (@Sendable (String, Date, Date) async throws -> [CalendarEventInfo])?

    public init(
        customStatus: (@Sendable () -> CalendarAuthorizationStatus)? = nil,
        customRequestAccess: (@Sendable () async -> Bool)? = nil,
        customFetcher: (@Sendable (Date, TimeInterval) async throws -> [CalendarEventInfo])? = nil,
        customSearcher: (@Sendable (String, Date, Date) async throws -> [CalendarEventInfo])? = nil
    ) {
        self.customStatus = customStatus
        self.customRequestAccess = customRequestAccess
        self.customFetcher = customFetcher
        self.customSearcher = customSearcher
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        if let custom = customStatus {
            return custom()
        }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined, .writeOnly:
            fallthrough
        @unknown default:
            return .notDetermined
        }
        #else
        return .denied
        #endif
    }

    public func requestAccess() async -> Bool {
        if let custom = customRequestAccess {
            return await custom()
        }
        #if canImport(EventKit)
        if #available(macOS 14.0, *) {
            do {
                return try await eventStore.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }

    public func fetchEvents(around date: Date, duration: TimeInterval) async throws -> [CalendarEventInfo] {
        if let custom = customFetcher {
            return try await custom(date, duration)
        }
        #if canImport(EventKit)
        guard authorizationStatus() == .authorized else {
            return []
        }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay: Date
        if let next = cal.date(byAdding: .day, value: 1, to: startOfDay) {
            endOfDay = next
        } else {
            endOfDay = startOfDay.addingTimeInterval(86400)
        }
        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let ekEvents = eventStoreRunner?(predicate) ?? eventStore.events(matching: predicate)
        let converted = ekEvents.map { convertEvent($0) }
        return converted.sorted { $0.startDate < $1.startDate }
        #else
        return []
        #endif
    }

    public func searchEvents(query: String, start: Date, end: Date) async throws -> [CalendarEventInfo] {
        if let custom = customSearcher {
            return try await custom(query, start, end)
        }
        #if canImport(EventKit)
        guard authorizationStatus() == .authorized else {
            return []
        }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = eventStoreRunner?(predicate) ?? eventStore.events(matching: predicate)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let converted = ekEvents.map { convertEvent($0) }
        if cleanQuery.isEmpty {
            return converted.sorted { $0.startDate < $1.startDate }
        }
        return converted.filter { event in
            event.title.lowercased().contains(cleanQuery)
                || (event.location?.lowercased().contains(cleanQuery) == true)
                || (event.notes?.lowercased().contains(cleanQuery) == true)
        }.sorted { $0.startDate < $1.startDate }
        #else
        return []
        #endif
    }

    public func listCalendars() -> [DiscoveredCalendarInfo] {
        guard authorizationStatus() == .authorized else { return [] }
        #if canImport(EventKit)
        let cals = eventStore.calendars(for: .event)
        return cals.map { cal in
            var hex = "#007AFF"
            if let color = cal.color,
               let rgbColor = color.usingColorSpace(.sRGB) {
                let r = Int(rgbColor.redComponent * 255)
                let g = Int(rgbColor.greenComponent * 255)
                let b = Int(rgbColor.blueComponent * 255)
                hex = String(format: "#%02X%02X%02X", r, g, b)
            }
            return DiscoveredCalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                colorHex: hex,
                sourceTitle: cal.source.title
            )
        }.sorted { $0.title < $1.title }
        #else
        return []
        #endif
    }

    #if canImport(EventKit)
    func convertEvent(_ event: EKEvent) -> CalendarEventInfo {
        var colorHex: String? = nil
        #if canImport(AppKit)
        if let cgColor = event.calendar?.cgColor, let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) {
            let r = Int(nsColor.redComponent * 255)
            let g = Int(nsColor.greenComponent * 255)
            let b = Int(nsColor.blueComponent * 255)
            colorHex = String(format: "#%02X%02X%02X", r, g, b)
        }
        #endif

        var attendeeNames: [String] = []
        if let attendees = event.attendees {
            for att in attendees {
                if let name = att.name, !name.isEmpty {
                    attendeeNames.append(name)
                } else {
                    let raw = att.url.absoluteString
                    let clean = raw.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                    attendeeNames.append(clean)
                }
            }
        }
        var uniqueAttendees: [String] = []
        for name in attendeeNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !uniqueAttendees.contains(trimmed) {
                uniqueAttendees.append(trimmed)
            }
        }

        var eventID = UUID().uuidString
        if let id = event.eventIdentifier {
            eventID = id
        }
        var eventTitle = "Untitled Event"
        if let title = event.title {
            eventTitle = title
        }
        var start = Date()
        if let s = event.startDate {
            start = s
        }
        var end = Date()
        if let e = event.endDate {
            end = e
        }
        var calTitle = "Calendar"
        if let title = event.calendar?.title {
            calTitle = title
        }

        return CalendarEventInfo(
            id: eventID,
            title: eventTitle,
            startDate: start,
            endDate: end,
            calendarTitle: calTitle,
            calendarColorHex: colorHex,
            location: event.location,
            notes: event.notes,
            attendees: uniqueAttendees,
            isAllDay: event.isAllDay
        )
    }
    #endif
}
