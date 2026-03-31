import AppKit
import CoreLocation
import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("calendar")

extension CalendarService {
    @ToolBuilder var mutationTools: [Tool] {
        Tool(
            name: "events_create",
            description: "Create a new calendar event with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start": .string(
                        description:
                            "Start date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to use (uses default if not specified)"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(
                        default: false
                    ),
                    "availability": .string(
                        description: "Availability status",
                        default: .string(EKEventAvailability.busy.stringValue),
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "recurrence": .object(
                        description: "Recurrence rule for the event",
                        properties: [
                            "frequency": .string(
                                description: "How often the event repeats",
                                enum: ["daily", "weekly", "monthly", "yearly"]
                            ),
                            "interval": .integer(
                                description: "Interval between recurrences (e.g. 2 = every 2 weeks)",
                                default: .int(1)
                            ),
                            "daysOfWeek": .array(
                                description: "Days of the week for weekly recurrence",
                                items: .string(enum: ["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
                            ),
                            "endDate": .string(
                                description: "End date for the recurrence",
                                format: .dateTime
                            ),
                            "occurrenceCount": .integer(
                                description: "Number of occurrences before stopping"
                            ),
                        ],
                        required: ["frequency"]
                    ),
                    "alarms": .array(
                        description: "Alarm configurations for the event",
                        items: .anyOf(
                            [
                                .object(
                                    properties: [
                                        "type": .string(const: "relative"),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["minutes"],
                                    additionalProperties: false
                                ),
                                .object(
                                    properties: [
                                        "type": .string(const: "absolute"),
                                        "datetime": .string(
                                            description:
                                                "Alarm date/time. If timezone is omitted, local time is assumed.",
                                            format: .dateTime
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["datetime"],
                                    additionalProperties: false
                                ),
                                .object(
                                    properties: [
                                        "type": .string(const: "proximity"),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
                                        ),
                                        "locationTitle": .string(),
                                        "latitude": .number(),
                                        "longitude": .number(),
                                        "radius": .number(
                                            description: "Radius in meters",
                                            default: .int(200)
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                ],
                required: ["title", "start", "end"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let event = EKEvent(eventStore: self.eventStore)

            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            guard case .string(let startDateStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                case .string(let endDateStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            let calendar = Calendar.current
            let startDate = calendar.normalizedStartDate(
                from: parsedStart.date,
                isDateOnly: parsedStart.isDateOnly
            )
            let endDate = calendar.normalizedEndDate(
                from: parsedEnd.date,
                isDateOnly: parsedEnd.isDateOnly
            )

            if case .bool(true) = arguments["isAllDay"] {
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            var targetCalendar = self.eventStore.defaultCalendarForNewEvents
            if case .string(let calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    targetCalendar = matchingCalendar
                }
            }
            event.calendar = targetCalendar

            if case .string(let location) = arguments["location"] {
                event.location = location
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set recurrence rule
            if case .object(let recurrence) = arguments["recurrence"],
                case .string(let frequencyStr) = recurrence["frequency"]
            {
                let frequency = EKRecurrenceFrequency(frequencyStr)
                let interval: Int
                if case .int(let i) = recurrence["interval"] {
                    interval = i
                } else {
                    interval = 1
                }

                var daysOfWeek: [EKRecurrenceDayOfWeek]?
                if case .array(let days) = recurrence["daysOfWeek"] {
                    daysOfWeek = days.compactMap { dayValue -> EKRecurrenceDayOfWeek? in
                        guard case .string(let day) = dayValue else { return nil }
                        switch day.uppercased() {
                        case "MO": return EKRecurrenceDayOfWeek(.monday)
                        case "TU": return EKRecurrenceDayOfWeek(.tuesday)
                        case "WE": return EKRecurrenceDayOfWeek(.wednesday)
                        case "TH": return EKRecurrenceDayOfWeek(.thursday)
                        case "FR": return EKRecurrenceDayOfWeek(.friday)
                        case "SA": return EKRecurrenceDayOfWeek(.saturday)
                        case "SU": return EKRecurrenceDayOfWeek(.sunday)
                        default: return nil
                        }
                    }
                }

                var end: EKRecurrenceEnd?
                if case .string(let endDateStr) = recurrence["endDate"],
                    let parsedEnd = ISO8601DateFormatter.lenientDate(
                        fromISO8601String: endDateStr
                    )
                {
                    end = EKRecurrenceEnd(end: parsedEnd)
                } else if case .int(let count) = recurrence["occurrenceCount"] {
                    end = EKRecurrenceEnd(occurrenceCount: count)
                }

                let rule = EKRecurrenceRule(
                    recurrenceWith: frequency,
                    interval: interval,
                    daysOfTheWeek: daysOfWeek,
                    daysOfTheMonth: nil,
                    monthsOfTheYear: nil,
                    weeksOfTheYear: nil,
                    daysOfTheYear: nil,
                    setPositions: nil,
                    end: end
                )
                event.recurrenceRules = [rule]
            }

            // Set alarms
            if case .array(let alarmConfigs) = arguments["alarms"] {
                event.alarms = Self.parseAlarms(alarmConfigs)
            }

            try self.eventStore.save(event, span: .thisEvent)

            var result = Event(event)
            result.identifier = event.calendarItemIdentifier
            return result
        }

        Tool(
            name: "events_update",
            description:
                "Update an existing calendar event. Only provided fields are modified.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Unique identifier of the event to update (from events_fetch)"
                    ),
                    "title": .string(),
                    "start": .string(
                        description: "New start date/time. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "New end date/time. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to move the event to"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(format: .uri),
                    "isAllDay": .boolean(),
                    "availability": .string(
                        description: "Availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "span": .string(
                        description: "For recurring events: update this event only or all future events",
                        default: "thisEvent",
                        enum: ["thisEvent", "futureEvents"]
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"],
                let calendarItem = self.eventStore.calendarItem(withIdentifier: identifier),
                let event = calendarItem as? EKEvent
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found with the provided identifier"]
                )
            }

            if case .string(let title) = arguments["title"] {
                event.title = title
            }

            let cal = Calendar.current

            if case .string(let startStr) = arguments["start"],
                let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: startStr)
            {
                event.startDate = cal.normalizedStartDate(
                    from: parsed.date, isDateOnly: parsed.isDateOnly
                )
            }

            if case .string(let endStr) = arguments["end"],
                let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: endStr)
            {
                event.endDate = cal.normalizedEndDate(
                    from: parsed.date, isDateOnly: parsed.isDateOnly
                )
            }

            if case .string(let calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    event.calendar = matchingCalendar
                }
            }

            if case .string(let location) = arguments["location"] {
                event.location = location
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .bool(let isAllDay) = arguments["isAllDay"] {
                event.isAllDay = isAllDay
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            let span: EKSpan
            if case .string(let spanStr) = arguments["span"], spanStr == "futureEvents" {
                span = .futureEvents
            } else {
                span = .thisEvent
            }

            try self.eventStore.save(event, span: span)

            var result = Event(event)
            result.identifier = event.calendarItemIdentifier
            return result
        }

        Tool(
            name: "events_delete",
            description: "Delete a calendar event by its identifier",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Unique identifier of the event to delete (from events_fetch)"
                    ),
                    "span": .string(
                        description: "For recurring events: delete this event only or all future events",
                        default: "thisEvent",
                        enum: ["thisEvent", "futureEvents"]
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"],
                let calendarItem = self.eventStore.calendarItem(withIdentifier: identifier),
                let event = calendarItem as? EKEvent
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found with the provided identifier"]
                )
            }

            let span: EKSpan
            if case .string(let spanStr) = arguments["span"], spanStr == "futureEvents" {
                span = .futureEvents
            } else {
                span = .thisEvent
            }

            let title = event.title ?? "Untitled"
            try self.eventStore.remove(event, span: span, commit: true)

            return Value.object([
                "success": .bool(true),
                "deleted": .string(title),
            ])
        }
    }

    /// Parse alarm configuration array into EKAlarm objects
    static func parseAlarms(_ alarmConfigs: [Value]) -> [EKAlarm] {
        var alarms: [EKAlarm] = []

        for alarmConfig in alarmConfigs {
            guard case .object(let config) = alarmConfig else { continue }

            var alarm: EKAlarm?

            let alarmType = config["type"]?.stringValue ?? "relative"
            switch alarmType {
            case "relative":
                if case .int(let minutes) = config["minutes"] {
                    alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }

            case "absolute":
                if case .string(let datetimeStr) = config["datetime"] {
                    if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr) {
                        log.error(
                            "Absolute alarm datetime must include time component: \(datetimeStr, privacy: .public)"
                        )
                    } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                        fromISO8601String: datetimeStr
                    ) {
                        alarm = EKAlarm(absoluteDate: absoluteDate)
                    }
                }

            case "proximity":
                let latitude: Double?
                if case .double(let d) = config["latitude"] { latitude = d }
                else if case .int(let i) = config["latitude"] { latitude = Double(i) }
                else { latitude = nil }

                let longitude: Double?
                if case .double(let d) = config["longitude"] { longitude = d }
                else if case .int(let i) = config["longitude"] { longitude = Double(i) }
                else { longitude = nil }

                if case .string(let locationTitle) = config["locationTitle"],
                    let latitude, let longitude
                {
                    alarm = EKAlarm()

                    let structuredLocation = EKStructuredLocation(title: locationTitle)
                    structuredLocation.geoLocation = CLLocation(
                        latitude: latitude,
                        longitude: longitude
                    )

                    if case .double(let radius) = config["radius"] {
                        structuredLocation.radius = radius
                    } else if case .int(let radiusInt) = config["radius"] {
                        structuredLocation.radius = Double(radiusInt)
                    }

                    let proximityType = config["proximity"]?.stringValue ?? "enter"
                    let proximity: EKAlarmProximity =
                        proximityType == "enter" ? .enter : .leave
                    alarm?.proximity = proximity
                    alarm?.structuredLocation = structuredLocation
                }

            default:
                log.error(
                    "Unexpected alarm type encountered: \(alarmType, privacy: .public)"
                )
                continue
            }

            guard let alarm = alarm else { continue }

            if case .string(let soundName) = config["sound"],
                Sound(rawValue: soundName) != nil
            {
                alarm.soundName = soundName
            }

            if case .string(let email) = config["emailAddress"], !email.isEmpty {
                alarm.emailAddress = email
            }

            alarms.append(alarm)
        }

        return alarms
    }
}
