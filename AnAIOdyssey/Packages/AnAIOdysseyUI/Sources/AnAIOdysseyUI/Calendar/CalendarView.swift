// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Calendar {
    /// The first instant of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

/// The Calendar workspace: a proper month grid (weekday headers + day cells with
/// event indicators) over the selected day's event list.
///
/// Named `AppCalendarView` to avoid colliding with `Foundation.Calendar`. Loading
/// prefers the live service but falls back to the local cache on error so the UI
/// degrades gracefully offline.
struct AppCalendarView: View {
    /// Event source/sink: lists, caches, creates, and deletes events.
    @Environment(\.calendarService) private var calendarService
    /// Active theme, used to pick a legible color for today's day number.
    @EnvironmentObject private var themeSettings: ThemeSettings

    /// Events for the visible month window, grouped for the grid + day list.
    @State private var events: [CalendarEventItem] = []
    /// First day of the month currently displayed in the grid.
    @State private var visibleMonth: Date = Calendar.current.startOfMonth(for: .now)
    /// The day the user has tapped in the grid (drives the day list).
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    /// The event chosen for the detail sheet.
    @State private var selectedEvent: CalendarEventItem?
    /// Presents the new-event composer sheet.
    @State private var showingNewEvent = false
    /// Surfaces load/create/delete errors.
    @State private var errorMessage: String?
    /// True while an async calendar operation is in flight.
    @State private var isLoading = false
    /// Changing this token re-triggers the `.task(id:)` that reloads events.
    @State private var reloadToken = UUID()

    private let calendar = Calendar.current
    #if os(iOS)
    /// Compact (iPhone) Calendar is hosted by the Library tab's navigation
    /// stack, so it must not start a second one.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// On iPad and Mac the calendar owns its `NavigationStack` (the tablet shell
    /// provides none). On iPhone the Library stack in `PhoneRootView` is the one
    /// navigation stack for the flow, so the content renders bare — a nested
    /// stack would add a second bar and a confusing Back path.
    var body: some View {
        Group {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                calendarContent
            } else {
                NavigationStack {
                    calendarContent
                }
            }
            #else
            NavigationStack {
                calendarContent
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            monthHeader
            Divider()
            weekdayHeader
            monthGrid
            Divider()
            dayEventList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Calendar")
        .toolbar { calendarToolbar }
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView()
                    .padding(.top, 8)
            }
        }
        .task(id: reloadToken) {
            await reloadEvents()
        }
        .onChange(of: visibleMonth) { _, _ in
            reloadToken = UUID()
        }
        .sheet(isPresented: $showingNewEvent) {
            NewEventSheet(defaultDate: selectedDay) { title, notes, start, end in
                createEvent(title: title, notes: notes, start: start, end: end)
            }
        }
        .sheet(item: $selectedEvent) { event in
            CalendarEventDetailView(event: event) {
                deleteEvent(id: event.id)
                selectedEvent = nil
            }
        }
        .accessibilityIdentifier("calendar-view")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var calendarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingNewEvent = true
            } label: {
                Label("New Event", systemImage: "plus")
            }
            .workspaceActionButtonTint()
            .accessibilityIdentifier("new-calendar-event-button")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                reloadToken = UUID()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .workspaceActionButtonTint()
            .accessibilityIdentifier("refresh-calendar-button")
        }
        ToolbarItem(placement: .primaryAction) {
            PopOutWindowButton(windowID: AppWindowID.calendar)
        }
    }

    // MARK: Month header (title + navigation)

    private var monthHeader: some View {
        HStack(spacing: 12) {
            Text(monthTitle)
                .font(.title2.weight(.semibold))

            Spacer()

            Button("Today") { goToToday() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("calendar-today-button")

            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous month")
            .accessibilityIdentifier("calendar-prev-month")

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next month")
            .accessibilityIdentifier("calendar-next-month")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Weekday header row

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(monthDays, id: \.self) { day in
                // A real Button (not a tap gesture) so day cells are reachable by
                // VoiceOver, Full Keyboard Access, and hardware keyboards.
                Button {
                    selectedDay = day
                } label: {
                    DayCell(
                        date: day,
                        isInMonth: calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                        eventCount: eventCount(on: day),
                        todayNumberColor: todayNumberColor
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dayCellAccessibilityLabel(for: day))
                .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: selectedDay) ? .isSelected : [])
                .accessibilityIdentifier("calendar-day-\(dayCellIdentifier(for: day))")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Selected-day event list

    private var dayEventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedDay.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            let dayEvents = events(on: selectedDay)
            if dayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No events")
                        .foregroundStyle(.secondary)
                    Button("New Event") { showingNewEvent = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(dayEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            eventRow(event)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("calendar-event-row-\(event.id)")
                    }
                    .onDelete { offsets in
                        deleteEvents(dayEvents, at: offsets)
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }

            if let errorMessage {
                StatusMessage(kind: .error, text: errorMessage)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// One event row: a tinted time block + title + optional location.
    private func eventRow(_ event: CalendarEventItem) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "(untitled)" : event.title)
                    .font(.body)
                Text(timeText(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Derived data

    /// Localized weekday symbols, rotated to start on the locale's first weekday.
    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// "June 2026" style title for the visible month.
    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    /// All day cells filling complete weeks across the visible month (typically 35–42).
    private var monthDays: [Date] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        let firstOfMonth = visibleMonth
        // Leading days to backfill so the grid starts on the first weekday column.
        let leading = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth) else { return [] }

        let totalDays = leading + monthRange.count
        // Round up to whole weeks (5 or 6 rows).
        let weeks = Int((Double(totalDays) / 7.0).rounded(.up))
        let cellCount = weeks * 7
        return (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func events(on day: Date) -> [CalendarEventItem] {
        events
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func eventCount(on day: Date) -> Int {
        events.reduce(0) { $0 + (calendar.isDate($1.startDate, inSameDayAs: day) ? 1 : 0) }
    }

    /// Color for today's day number: black or white chosen from the accent's
    /// relative luminance, instead of fixed white (which disappears on bright
    /// accents like Sunset).
    private var todayNumberColor: Color {
        contrastingForegroundColor(on: themeSettings.accent.color)
    }

    /// Spoken label for a day cell: the full date plus its event count.
    private func dayCellAccessibilityLabel(for day: Date) -> String {
        var label = day.formatted(date: .complete, time: .omitted)
        let count = eventCount(on: day)
        if count > 0 {
            label += ", \(count) event\(count == 1 ? "" : "s")"
        }
        return label
    }

    /// Stable per-day identifier (e.g. "2026-10-05") for UI tests.
    private func dayCellIdentifier(for day: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func timeText(_ event: CalendarEventItem) -> String {
        if event.allDay { return "All day" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Navigation

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = calendar.startOfMonth(for: next)
        }
    }

    private func goToToday() {
        visibleMonth = calendar.startOfMonth(for: .now)
        selectedDay = calendar.startOfDay(for: .now)
        reloadToken = UUID()
    }

    // MARK: Window bounds for the query

    /// Query window: a little before the grid start through a little after its end.
    private var queryStart: Date {
        monthDays.first.map { calendar.startOfDay(for: $0) } ?? visibleMonth
    }

    private var queryEnd: Date {
        guard let last = monthDays.last else { return visibleMonth }
        return calendar.date(byAdding: .day, value: 1, to: last) ?? last
    }

    // MARK: Data operations

    private func reloadEvents() async {
        guard let calendarService else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await calendarService.listEvents(from: queryStart, to: queryEnd)
        } catch {
            errorMessage = error.localizedDescription
            let cached = (try? calendarService.cachedEvents(from: queryStart, to: queryEnd)) ?? []
            events = cached.map {
                CalendarEventItem(
                    id: $0.id,
                    title: $0.title,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    calendarID: $0.calendarID,
                    notes: $0.notes,
                    location: $0.location,
                    allDay: $0.allDay,
                    sourceID: $0.id.hasPrefix("google-") ? "google" : eventKitCalendarConnectionID
                )
            }
        }
    }

    private func createEvent(title: String, notes: String?, start: Date, end: Date) {
        guard let calendarService else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        let service = calendarService
        let clampedEnd = max(end, start)
        Task {
            defer { isLoading = false }
            do {
                _ = try await service.createEvent(
                    title: trimmed,
                    startDate: start,
                    endDate: clampedEnd,
                    notes: notes,
                    location: nil
                )
                await MainActor.run {
                    showingNewEvent = false
                    selectedDay = calendar.startOfDay(for: start)
                    reloadToken = UUID()
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func deleteEvents(_ dayEvents: [CalendarEventItem], at offsets: IndexSet) {
        let ids = offsets.map { dayEvents[$0].id }
        for id in ids { deleteEvent(id: id) }
    }

    private func deleteEvent(id: String) {
        guard let calendarService else { return }
        let service = calendarService
        Task {
            try? await service.deleteEvent(id: id)
            await MainActor.run { reloadToken = UUID() }
        }
    }
}

// MARK: - Day cell

/// A single day cell in the month grid: the day number, today/selection styling,
/// and up to three event dots (with a "+N" overflow count).
private struct DayCell: View {
    let date: Date
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int
    /// Contrast color for today's number over the accent-filled circle,
    /// computed by the caller from the active accent.
    let todayNumberColor: Color

    private var dayNumber: String {
        "\(Calendar.current.component(.day, from: date))"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(dayNumber)
                .font(.callout)
                .fontWeight(isToday ? .bold : .regular)
                .frame(minWidth: 26, minHeight: 26)
                .background {
                    if isToday {
                        Circle().fill(.tint)
                    }
                }
                .foregroundStyle(dayNumberColor)

            HStack(spacing: 3) {
                ForEach(0..<min(eventCount, 3), id: \.self) { _ in
                    Circle().fill(.tint).frame(width: 5, height: 5)
                }
                if eventCount > 3 {
                    // A text style (not fixed 8pt) so the count follows Dynamic Type.
                    Text("+\(eventCount - 3)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 52)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.15))
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 1)
            }
        }
        .opacity(isInMonth ? 1 : 0.3)
        .contentShape(Rectangle())
    }

    private var dayNumberColor: Color {
        if isToday { return todayNumberColor }
        return isInMonth ? .primary : .secondary
    }
}

/// Picks a black or white foreground from a background color's relative
/// luminance, so glyphs over the accent stay legible for every palette.
func contrastingForegroundColor(on background: Color) -> Color {
    #if canImport(UIKit)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard UIColor(background).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return .white
    }
    #else
    guard let srgb = NSColor(background).usingColorSpace(.sRGB) else {
        return .white
    }
    let red = srgb.redComponent, green = srgb.greenComponent, blue = srgb.blueComponent
    #endif
    // Rec. 709 luminance weighting on the raw sRGB components — a sufficient
    // approximation for choosing a black vs. white overlay.
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    return luminance > 0.5 ? Color.black.opacity(0.85) : .white
}

// MARK: - New event composer

/// A focused sheet for creating an event, pre-seeded to the selected day.
private struct NewEventSheet: View {
    let defaultDate: Date
    let onCreate: (_ title: String, _ notes: String?, _ start: Date, _ end: Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var start: Date
    @State private var end: Date

    init(defaultDate: Date, onCreate: @escaping (String, String?, Date, Date) -> Void) {
        self.defaultDate = defaultDate
        self.onCreate = onCreate
        // Default to 9:00–10:00 on the selected day.
        let calendar = Calendar.current
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDate) ?? defaultDate
        _start = State(initialValue: nineAM)
        _end = State(initialValue: calendar.date(byAdding: .hour, value: 1, to: nineAM) ?? nineAM)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Event") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("calendar-event-title")
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end)
                }
            }
            .workspaceSettingsForm()
            .navigationTitle("New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title, notes.isEmpty ? nil : notes, start, end)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create-calendar-event-button")
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
    }
}

// MARK: - Event detail

/// Read-only details for a selected calendar event, with a delete action.
private struct CalendarEventDetailView: View {
    let event: CalendarEventItem
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Title", value: event.title)
                    LabeledContent("Starts", value: dateText(event.startDate))
                    LabeledContent("Ends", value: dateText(event.endDate))
                    if event.allDay {
                        LabeledContent("All Day", value: "Yes")
                    }
                    if let location = event.location, !location.isEmpty {
                        LabeledContent("Location", value: location)
                    }
                }

                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes).textSelection(.enabled)
                    }
                }

                Section {
                    Button("Delete Event", role: .destructive, action: onDelete)
                        .workspaceActionButtonTint(destructive: true)
                        .accessibilityIdentifier("delete-calendar-event-button")
                }
            }
            .workspaceSettingsForm()
            .navigationTitle(event.title.isEmpty ? "Event" : event.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("calendar-event-detail")
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private func dateText(_ date: Date) -> String {
        event.allDay
            ? date.formatted(date: .abbreviated, time: .omitted)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
