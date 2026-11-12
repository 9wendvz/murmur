import SwiftUI
import UserNotifications

// MARK: - Model

/// Something worth remembering: a birthday, an anniversary, an exam.
struct ImportantDate: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// "yyyy-MM-dd". For yearly dates only the month and day matter.
    var day: String
    var yearly: Bool = true
    /// Remind this many days before (0 = on the day).
    var remindDaysBefore: Int = 0

    /// The next time this date comes round, on or after `from` (nil if it was one-off and has passed).
    func nextOccurrence(from: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        guard let d = DiaryStore.date(fromKey: day) else { return nil }
        let today = cal.startOfDay(for: from)
        guard yearly else { return d >= today ? d : nil }
        let md = cal.dateComponents([.month, .day], from: d)
        let year = cal.component(.year, from: today)
        for y in [year, year + 1] {
            if let next = Self.date(year: y, month: md.month!, day: md.day!, cal), next >= today { return next }
        }
        return nil
    }

    /// Feb 29 falls back to Feb 28 in years without one.
    private static func date(year: Int, month: Int, day: Int, _ cal: Calendar) -> Date? {
        let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
        let last = cal.range(of: .day, in: .month, for: first)!.count
        return cal.date(from: DateComponents(year: year, month: month, day: min(day, last)))
    }

    /// True if this date falls on `date` (taking yearly repeats into account).
    func falls(on date: Date, calendar cal: Calendar = .current) -> Bool {
        guard let next = nextOccurrence(from: date, calendar: cal) else { return false }
        return cal.isDate(next, inSameDayAs: date)
    }

    /// When the reminder should fire for the next occurrence: 9:00 am, `remindDaysBefore` days ahead of it.
    func reminderDate(from now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        guard let next = nextOccurrence(from: now, calendar: cal),
              let day = cal.date(byAdding: .day, value: -remindDaysBefore, to: next),
              let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { return nil }
        return fire > now ? fire : nil
    }

    static let remindOptions: [(Int, String)] = [(0, "on the day"), (1, "1 day before"), (3, "3 days before"), (7, "1 week before")]
}

// MARK: - Store + reminders

final class DatesStore: ObservableObject {
    static let shared = DatesStore()

    @Published private(set) var dates: [ImportantDate] = []
    @Published private(set) var notificationsAllowed: Bool?

    private let fileURL = DiaryStore.directory.appendingPathComponent("dates.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ImportantDate].self, from: data) { dates = decoded }
        refreshPermission()
        reschedule()
    }

    func add(_ d: ImportantDate) { dates.append(d); changed() }
    func remove(_ d: ImportantDate) { dates.removeAll { $0.id == d.id }; changed() }

    /// Dates that fall on a given day.
    func on(_ day: Date) -> [ImportantDate] { dates.filter { $0.falls(on: day) } }

    /// The soonest upcoming date (today counts) and its day.
    func next(from now: Date = Date()) -> (ImportantDate, Date)? {
        dates.compactMap { d in d.nextOccurrence(from: now).map { (d, $0) } }.min { $0.1 < $1.1 }
    }

    /// Upcoming dates, soonest first.
    var upcoming: [(ImportantDate, Date?)] {
        dates.map { ($0, $0.nextOccurrence()) }.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
    }

    private func changed() {
        if let data = try? JSONEncoder().encode(dates) { try? data.write(to: fileURL, options: .atomic) }
        requestPermissionIfNeeded()
        reschedule()
    }

    // MARK: notifications

    /// UNUserNotificationCenter throws (crashes) outside a real .app bundle (tests, benchmarks, previews).
    private var canNotify: Bool { Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil }

    func refreshPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                self.notificationsAllowed = s.authorizationStatus == .notDetermined ? nil
                    : (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            }
        }
    }

    func requestPermissionIfNeeded() {
        guard canNotify, notificationsAllowed == nil, !dates.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            self.refreshPermission()
            DispatchQueue.main.async { self.reschedule() }
        }
    }

    /// One pending notification per date, for its next occurrence. Re-run on launch and after every change,
    /// so yearly dates roll forward.
    func reschedule() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        let snapshot = dates
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("date-") })
            for d in snapshot {
                guard let fire = d.reminderDate(), let next = d.nextOccurrence() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "◆ " + d.title
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: fire), to: next).day ?? 0
                content.body = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                center.add(UNNotificationRequest(identifier: "date-\(d.id)", content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }
}

// MARK: - Sheet

struct DatesSheet: View {
    @ObservedObject private var dates = DatesStore.shared
    @ObservedObject private var nav = AppNav.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var day = Date()
    @State private var yearly = true
    @State private var remind = 0
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("~/diary/dates")
                Spacer()
                Button("[done]") { dismiss() }.buttonStyle(TextButtonStyle(active: true)).keyboardShortcut(.cancelAction)
            }
            .font(Theme.font(13))

            // add a date
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(">").foregroundStyle(Theme.amber)
                    TextField("what's the date? (mom's birthday…)", text: $title)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit(add)
                }
                .font(Theme.font(13))
                HStack(spacing: 16) {
                    DatePicker("", selection: $day, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button { yearly.toggle() } label: { HStack(spacing: 6) { LED(on: yearly, color: Theme.amber); Text("yearly") } }
                        .buttonStyle(TextButtonStyle(active: yearly))
                    Menu {
                        ForEach(ImportantDate.remindOptions, id: \.0) { opt in Button(opt.1) { remind = opt.0 } }
                    } label: {
                        Text("remind: " + (ImportantDate.remindOptions.first { $0.0 == remind }?.1 ?? ""))
                            .font(Theme.font(11))
                            .foregroundStyle(Theme.sub)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                    Button("[add]", action: add)
                        .buttonStyle(TextButtonStyle(active: !title.trimmingCharacters(in: .whitespaces).isEmpty))
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(Theme.font(11))
            }
            .padding(14)
            .background(Theme.card)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))

            // the list
            if dates.dates.isEmpty {
                Text("no dates yet.").foregroundStyle(Theme.faint)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(dates.upcoming, id: \.0.id) { d, next in row(d, next) }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                LED(on: dates.notificationsAllowed == true)
                Text(dates.notificationsAllowed == false ? "notifications are off for diary" :
                     dates.notificationsAllowed == true ? "reminders arrive at 9:00 am, even if diary is closed" :
                     "you'll be asked to allow notifications when you add a date")
                if dates.notificationsAllowed == false {
                    Button("[open settings]") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(TextButtonStyle())
                }
            }
            .font(Theme.font(10))
            .foregroundStyle(Theme.faint)
        }
        .padding(28)
        .frame(width: 560, height: 520)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .font(Theme.font(12))
        .onAppear {
            if let d = nav.dateDraft { day = d; nav.dateDraft = nil }
            titleFocused = true
            dates.refreshPermission()
        }
    }

    private func row(_ d: ImportantDate, _ next: Date?) -> some View {
        let days = next.map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: $0).day ?? 0 }
        return HStack(spacing: 12) {
            Text("◆").foregroundStyle(days == 0 ? Theme.amber : Theme.faint)
            Text(d.title).lineLimit(1)
            Spacer()
            Text(next.map { String(format: "%02d.%02d", Calendar.current.component(.month, from: $0), Calendar.current.component(.day, from: $0)) } ?? d.day)
                .foregroundStyle(Theme.sub)
            Text((d.yearly ? "yearly" : "once") + (d.remindDaysBefore > 0 ? " · -\(d.remindDaysBefore)d" : ""))
                .foregroundStyle(Theme.faint)
                .frame(width: 92, alignment: .leading)
            Text(days.map { $0 == 0 ? "today" : "in \($0)d" } ?? "passed")
                .foregroundStyle(days == 0 ? Theme.amber : Theme.sub)
                .frame(width: 60, alignment: .trailing)
                .monospacedDigit()
            Button("[×]") { withAnimation(.easeOut(duration: 0.2)) { dates.remove(d) } }.buttonStyle(TextButtonStyle())
        }
        .font(Theme.font(11))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            dates.add(ImportantDate(title: t, day: DiaryStore.key(day), yearly: yearly, remindDaysBefore: remind))
        }
        title = ""
    }
}
