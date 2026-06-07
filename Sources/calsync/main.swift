// calsync — mirrors busy time between calendars as anonymous blocker events.
// Reads all sources locally via EventKit; writes blockers to target calendars.
// Reconciliation is pure create/delete keyed on the marker line in event notes.

import EventKit
import Foundation

// MARK: - Config

struct Target: Codable {
    let calendar: String
    let sources: [String]
}

struct Config: Codable {
    var horizonDays: Int
    var blockerTitle: String
    var minBlockMinutes: Int
    var skipTitleContains: [String]
    var targets: [Target]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        horizonDays = try c.decodeIfPresent(Int.self, forKey: .horizonDays) ?? 56
        blockerTitle = try c.decodeIfPresent(String.self, forKey: .blockerTitle) ?? "Busy"
        minBlockMinutes = try c.decodeIfPresent(Int.self, forKey: .minBlockMinutes) ?? 5
        skipTitleContains = try c.decodeIfPresent([String].self, forKey: .skipTitleContains) ?? []
        targets = try c.decode([Target].self, forKey: .targets)
    }
}

// MARK: - Intervals

struct Interval: Hashable {
    let start: Date
    let end: Date
}

/// Merge overlapping or adjacent intervals into disjoint spans.
func merge(_ intervals: [Interval]) -> [Interval] {
    let sorted = intervals.sorted { $0.start < $1.start }
    var out: [Interval] = []
    for iv in sorted {
        if let last = out.last, iv.start <= last.end {
            if iv.end > last.end {
                out[out.count - 1] = Interval(start: last.start, end: iv.end)
            }
        } else {
            out.append(iv)
        }
    }
    return out
}

/// Subtract merged `cover` from merged `base`; returns the uncovered fragments.
func subtract(_ base: [Interval], _ cover: [Interval]) -> [Interval] {
    var out: [Interval] = []
    for iv in base {
        var cursor = iv.start
        for c in cover where c.end > iv.start && c.start < iv.end {
            if c.start > cursor {
                out.append(Interval(start: cursor, end: c.start))
            }
            cursor = max(cursor, c.end)
        }
        if cursor < iv.end {
            out.append(Interval(start: cursor, end: iv.end))
        }
    }
    return out
}

// MARK: - Helpers

let marker = "calsync:v1"

func markerLine(_ iv: Interval) -> String {
    "\(marker) \(Int(iv.start.timeIntervalSince1970))-\(Int(iv.end.timeIntervalSince1970))"
}

func parseMarker(_ notes: String?) -> Interval? {
    guard let line = notes?.split(separator: "\n").first(where: { $0.hasPrefix(marker + " ") }) else { return nil }
    // Tolerate trailing text (user-edited notes must not orphan a blocker).
    let parts = line.dropFirst(marker.count + 1).split(separator: "-", maxSplits: 1)
    guard parts.count == 2,
          let s = Int(parts[0]),
          let e = Int(parts[1].prefix(while: { $0.isNumber })), e > 0
    else { return nil }
    return Interval(start: Date(timeIntervalSince1970: Double(s)), end: Date(timeIntervalSince1970: Double(e)))
}

let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    return f
}()

let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

func show(_ iv: Interval) -> String {
    let sameDay = Calendar.current.isDate(iv.start, inSameDayAs: iv.end)
    let end = sameDay ? timeFmt.string(from: iv.end) : fmt.string(from: iv.end)
    return "\(fmt.string(from: iv.start))–\(end)"
}

/// True if the event represents real busy time for the user.
func isBusy(_ e: EKEvent) -> Bool {
    if e.isAllDay { return false }
    if e.availability == .free { return false }
    if e.status == .canceled { return false }
    if let me = e.attendees?.first(where: { $0.isCurrentUser }),
       me.participantStatus == .declined { return false }
    return true
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("calsync: " + msg + "\n").utf8))
    // Surface failures from background runs — the log isn't watched.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let safe = msg.replacingOccurrences(of: "\"", with: "'")
    p.arguments = ["-e", "display notification \"\(safe)\" with title \"calsync\""]
    try? p.run()
    p.waitUntilExit()
    exit(1)
}

// MARK: - Main

let dryRun = CommandLine.arguments.contains("--dry-run")

let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/calsync/config.json")
guard let configData = try? Data(contentsOf: configPath) else {
    die("no config at \(configPath.path)")
}
let config: Config
do { config = try JSONDecoder().decode(Config.self, from: configData) }
catch { die("bad config: \(error)") }

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { g, _ in granted = g; sem.signal() }
sem.wait()
guard granted else { die("calendar access denied — grant in System Settings → Privacy & Security → Calendars") }

let calendars = store.calendars(for: .event)
func resolve(_ name: String) -> EKCalendar {
    let hits = calendars.filter { $0.title == name }
    if hits.isEmpty { die("calendar not found: \(name)") }
    if hits.count > 1 { die("ambiguous calendar name: \(name)") }
    return hits[0]
}

let windowStart = Calendar.current.startOfDay(for: Date())
let windowEnd = Calendar.current.date(byAdding: .day, value: config.horizonDays, to: windowStart)!
let minBlock = TimeInterval(config.minBlockMinutes * 60)

print("[\(fmt.string(from: Date()))] calsync\(dryRun ? " (dry-run)" : "") — window \(fmt.string(from: windowStart)) → \(fmt.string(from: windowEnd))")

var totalCreate = 0, totalDelete = 0

for target in config.targets {
    let targetCal = resolve(target.calendar)
    if !targetCal.allowsContentModifications { die("target not writable: \(target.calendar)") }
    let sourceCals = target.sources.map(resolve)

    // Busy intervals from sources, clamped to window.
    let srcPredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: sourceCals)
    let srcEvents = store.events(matching: srcPredicate)
    if ProcessInfo.processInfo.environment["CALSYNC_DEBUG"] != nil {
        for e in srcEvents {
            let skipped = !isBusy(e) || parseMarker(e.notes) != nil
                || config.skipTitleContains.contains { e.title?.localizedCaseInsensitiveContains($0) ?? false }
            print("  src \(show(Interval(start: e.startDate, end: e.endDate))) \(e.title ?? "?") [\(e.calendar.title)] avail=\(e.availability.rawValue)\(skipped ? " SKIP" : "")")
        }
    }
    let srcBusy = srcEvents
        .filter(isBusy)
        .filter { parseMarker($0.notes) == nil }  // never mirror a mirror
        .filter { e in !config.skipTitleContains.contains { e.title?.localizedCaseInsensitiveContains($0) ?? false } }
        .map { Interval(start: max($0.startDate, windowStart), end: min($0.endDate, windowEnd)) }
        .filter { $0.end > $0.start }

    // Target events: split into calsync blockers and real busy time.
    let tgtPredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [targetCal])
    let tgtEvents = store.events(matching: tgtPredicate)
    let blockers = tgtEvents.filter { parseMarker($0.notes) != nil }
    let realBusy = tgtEvents
        .filter { parseMarker($0.notes) == nil }
        .filter(isBusy)
        .map { Interval(start: max($0.startDate, windowStart), end: min($0.endDate, windowEnd)) }
        .filter { $0.end > $0.start }

    // Desired blockers = source busy minus what the target already shows as busy.
    let desired = Set(
        subtract(merge(srcBusy), merge(realBusy))
            .filter { $0.end.timeIntervalSince($0.start) >= minBlock }
    )

    // Index blockers by marker; same-key twins and time-drifted blockers are strays to delete.
    var existing: [Interval: EKEvent] = [:]
    var strays: [EKEvent] = []
    for b in blockers {
        guard let iv = parseMarker(b.notes) else { continue }
        let drift = abs(b.startDate.timeIntervalSince(iv.start)) + abs(b.endDate.timeIntervalSince(iv.end))
        if drift > 60 || existing[iv] != nil { strays.append(b) } else { existing[iv] = b }
    }

    let toCreate = desired.subtracting(existing.keys).sorted { $0.start < $1.start }
    let toDelete = existing.filter { !desired.contains($0.key) }
        .map { ($0.key, $0.value) } + strays.map { (Interval(start: $0.startDate, end: $0.endDate), $0) }

    print("→ \(target.calendar): \(toCreate.count) create, \(toDelete.count) delete, \(desired.count - toCreate.count) unchanged")
    for iv in toCreate {
        print("   + \(show(iv))")
        guard !dryRun else { continue }
        let e = EKEvent(eventStore: store)
        e.calendar = targetCal
        e.title = config.blockerTitle
        e.startDate = iv.start
        e.endDate = iv.end
        e.availability = .busy
        e.notes = markerLine(iv)
        do { try store.save(e, span: .thisEvent, commit: false) }
        catch { die("save failed: \(error)") }
    }
    for (iv, e) in toDelete.sorted(by: { $0.0.start < $1.0.start }) {
        print("   - \(show(iv))")
        guard !dryRun else { continue }
        do { try store.remove(e, span: .thisEvent, commit: false) }
        catch { die("remove failed: \(error)") }
    }
    totalCreate += toCreate.count
    totalDelete += toDelete.count
}

if !dryRun && (totalCreate > 0 || totalDelete > 0) {
    do { try store.commit() } catch { die("commit failed: \(error)") }
}
print("done: \(totalCreate) created, \(totalDelete) deleted")
