import Foundation

public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var description: String
    public var meetLink: String?
    public var htmlLink: String?
    public var attendees: [String]
    public var organizer: String

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, location: String = "", description: String = "",
                meetLink: String? = nil, htmlLink: String? = nil, attendees: [String] = [], organizer: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.description = description
        self.meetLink = meetLink
        self.htmlLink = htmlLink
        self.attendees = attendees
        self.organizer = organizer
    }
}

public struct NewCalendarEvent: Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [String]
    public var description: String
    public var location: String
    public var createMeetLink: Bool

    public init(title: String, start: Date, end: Date, attendees: [String], description: String = "", location: String = "", createMeetLink: Bool = true) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.description = description
        self.location = location
        self.createMeetLink = createMeetLink
    }
}

public struct GoogleCalendarClient: Sendable {
    let api: GoogleAPI
    static let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    public init(tokens: TokenStore, accountID: UUID) {
        api = GoogleAPI(tokens: tokens, accountID: accountID)
    }

    struct EventTime: Codable {
        var dateTime: String?
        var date: String?
        var timeZone: String?
    }

    struct Attendee: Codable {
        var email: String
        var responseStatus: String?
    }

    struct Organizer: Codable { var email: String? }

    struct ConferenceKey: Codable { var type: String }
    struct CreateRequest: Codable { var requestId: String; var conferenceSolutionKey: ConferenceKey }
    struct ConferenceData: Codable { var createRequest: CreateRequest? }

    struct GEvent: Codable {
        var id: String?
        var summary: String?
        var description: String?
        var location: String?
        var start: EventTime?
        var end: EventTime?
        var hangoutLink: String?
        var htmlLink: String?
        var attendees: [Attendee]?
        var organizer: Organizer?
        var conferenceData: ConferenceData?
    }

    struct EventList: Decodable {
        var items: [GEvent]?
        var nextPageToken: String?
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        var token: String?
        repeat {
            var q = ["timeMin": ISO8601DateFormatter.archive.string(from: from), "timeMax": ISO8601DateFormatter.archive.string(from: to),
                     "singleEvents": "true", "orderBy": "startTime", "maxResults": "250"]
            if let token { q["pageToken"] = token }
            let page: EventList = try await api.json(EventList.self, "GET", URL(string: GoogleCalendarClient.base)!, query: q)
            out.append(contentsOf: (page.items ?? []).compactMap(GoogleCalendarClient.convert))
            token = page.nextPageToken
        } while token != nil
        return out
    }

    public func create(_ e: NewCalendarEvent) async throws -> CalendarEvent {
        let tz = TimeZone.current.identifier
        let body = GEvent(
            id: nil, summary: e.title, description: e.description.isEmpty ? nil : e.description, location: e.location.isEmpty ? nil : e.location,
            start: EventTime(dateTime: ISO8601DateFormatter.archive.string(from: e.start), date: nil, timeZone: tz),
            end: EventTime(dateTime: ISO8601DateFormatter.archive.string(from: e.end), date: nil, timeZone: tz),
            hangoutLink: nil, htmlLink: nil, attendees: e.attendees.map { Attendee(email: $0, responseStatus: nil) }, organizer: nil,
            conferenceData: e.createMeetLink ? ConferenceData(createRequest: CreateRequest(requestId: UUID().uuidString, conferenceSolutionKey: ConferenceKey(type: "hangoutsMeet"))) : nil)
        let created: GEvent = try await api.json(GEvent.self, "POST", URL(string: GoogleCalendarClient.base)!, body: body,
                                                 query: ["conferenceDataVersion": "1", "sendUpdates": "all"])
        guard let ev = GoogleCalendarClient.convert(created) else { throw FalconError.protocolError("calendar returned an invalid event") }
        return ev
    }

    public func delete(eventID: String) async throws {
        _ = try await api.request("DELETE", URL(string: "\(GoogleCalendarClient.base)/\(eventID)?sendUpdates=all")!)
    }

    static func convert(_ g: GEvent) -> CalendarEvent? {
        guard let id = g.id else { return nil }
        func date(_ t: EventTime?) -> (Date, Bool)? {
            if let dt = t?.dateTime, let d = ISO8601DateFormatter.archive.date(from: dt) ?? ISO8601DateFormatter.fractional.date(from: dt) { return (d, false) }
            if let day = t?.date, let d = ISO8601DateFormatter.dateOnly.date(from: day) { return (d, true) }
            return nil
        }
        guard let startInfo = date(g.start), let endInfo = date(g.end) else { return nil }
        return CalendarEvent(id: id, title: g.summary ?? "(No title)", start: startInfo.0, end: endInfo.0, isAllDay: startInfo.1,
                             location: g.location ?? "", description: g.description ?? "", meetLink: g.hangoutLink, htmlLink: g.htmlLink,
                             attendees: (g.attendees ?? []).map { $0.email }, organizer: g.organizer?.email ?? "")
    }
}
