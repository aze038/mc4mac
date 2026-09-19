import SwiftUI
import AppKit
import FalconCore

struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    @State private var events: [CalendarEvent] = []
    @State private var loading = false
    @State private var status = ""
    @State private var showNew = false
    @State private var accountID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Account", selection: $accountID) {
                    ForEach(model.accounts) { a in Text(a.email).tag(Optional(a.id)) }
                }.frame(maxWidth: 260)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                Button { showNew = true } label: { Label("New Meeting", systemImage: "plus") }
            }
            .padding(8)
            Divider()
            if loading { ProgressView().padding() }
            List {
                ForEach(groupedDays) { group in
                    Section(group.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(group.events) { e in EventRow(event: e) }
                    }
                }
            }
            .overlay { if events.isEmpty && !loading { ContentUnavailableView("No events in the next two weeks", systemImage: "calendar") } }
            if !status.isEmpty { Divider(); Text(status).font(.caption).foregroundStyle(.secondary).padding(6) }
        }
        .sheet(isPresented: $showNew) {
            if let id = accountID { NewMeetingSheet(accountID: id) { Task { await load() } }.environmentObject(model) }
        }
        .onAppear { accountID = model.accounts.first?.id }
        .task(id: accountID) { await load() }
    }

    private var groupedDays: [DayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: events) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted().map { DayGroup(day: $0, events: groups[$0]!.sorted { $0.start < $1.start }) }
    }

    private func load() async {
        guard let id = accountID else { return }
        loading = true
        defer { loading = false }
        let client = GoogleCalendarClient(tokens: model.tokens, accountID: id)
        do {
            events = try await client.events(from: Calendar.current.startOfDay(for: Date()), to: Date().addingTimeInterval(14 * 86400))
            status = ""
        } catch { status = error.localizedDescription }
    }
}

struct DayGroup: Identifiable {
    var day: Date
    var events: [CalendarEvent]
    var id: Date { day }
}

struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing) {
                if event.isAllDay {
                    Text("All day").font(.caption)
                } else {
                    Text(event.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
                    Text(event.end.formatted(date: .omitted, time: .shortened)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .medium))
                if !event.location.isEmpty { Text(event.location).font(.caption).foregroundStyle(.secondary) }
                if !event.attendees.isEmpty { Text(event.attendees.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let link = event.meetLink, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Join Meet", systemImage: "video") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else if let link = event.htmlLink, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NewMeetingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    let onCreated: () -> Void
    @State private var title = ""
    @State private var start = Calendar.current.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
    @State private var duration = 30
    @State private var attendees = ""
    @State private var description = ""
    @State private var meet = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New meeting").font(.title2.bold())
            Form {
                TextField("Title", text: $title)
                DatePicker("Starts", selection: $start)
                Picker("Duration", selection: $duration) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                RecipientField(label: "Guests", text: $attendees)
                TextField("Description", text: $description, axis: .vertical).lineLimit(3...6)
                Toggle("Add Google Meet video link", isOn: $meet)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Creating…" : "Create and Invite") { create() }
                    .keyboardShortcut(.defaultAction).disabled(title.trimmed.isEmpty || saving)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func create() {
        saving = true
        let event = NewCalendarEvent(title: title, start: start, end: start.addingTimeInterval(TimeInterval(duration * 60)),
                                     attendees: AddressParser.parse(attendees).map { $0.address }, description: description, createMeetLink: meet)
        Task {
            do {
                _ = try await GoogleCalendarClient(tokens: model.tokens, accountID: accountID).create(event)
                onCreated()
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
