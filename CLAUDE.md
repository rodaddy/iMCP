# iMCP -- Forked Apple MCP Server


> All LAWs (#!/bin/bash, protected branches, stack prefs) enforced via ~/.claude/CLAUDE.md and hooks.



> All LAWs (#!/bin/bash, protected branches, stack prefs) enforced via ~/.claude/CLAUDE.md and hooks.


## Project

Native Swift macOS app providing Apple service access via MCP. Forked from [mattt/iMCP](https://github.com/mattt/iMCP) v1.4.0 to [rodaddy/iMCP](https://github.com/rodaddy/iMCP). Building locally with Swift 6.3 / Xcode 26.4 / macOS 26.4 (Tahoe).

## PAI LAWs ARE MANDATORY

All 15 PAI LAWs from `~/.claude/CLAUDE.md` apply. Check LAWs BEFORE every action.

## Architecture

- **Xcode project** (not SPM) at `iMCP.xcodeproj`
- Two targets: `iMCP` (SwiftUI menubar app) and `imcp-server` (stdio CLI proxy)
- CLI subprocess discovers app via Bonjour, relays JSON-RPC over local TCP
- Services are modular: `App/Services/<Name>.swift` (one file per service, split into extensions when >600 lines)
- Uses official MCP Swift SDK (`modelcontextprotocol/swift-sdk`)
- ToolBuilder supports composing tools from multiple computed properties via `buildExpression`
- AppleScript-based services use `/usr/bin/osascript` subprocess with task-group timeout pattern
- Remotes: `origin` = rodaddy/iMCP (fork), `upstream` = mattt/iMCP

## Current State (2026-03-31)

### Working (73 tools via mcp2cli, 16 services)

| Service | Tools | Framework |
|---------|-------|-----------|
| AppleScript | `applescript_execute`, `applescript_list_apps` | osascript subprocess |
| Calendar | `calendars_list`, `events_fetch`, `events_create`, `events_update`, `events_delete` | EventKit |
| Capture | `capture_take_screenshot` (camera/mic blocked by mcp2cli) | ScreenCaptureKit |
| Chrome | `chrome_tabs_list`, `chrome_navigate`, `chrome_tab_activate`, `chrome_window_create`, `chrome_execute_javascript` | Chrome AppleScript |
| Contacts | `contacts_me`, `contacts_search`, `contacts_create`, `contacts_update`, `contacts_delete`, `contacts_groups_list` | Contacts framework |
| Desktop | `desktop_windows_list`, `desktop_window_move`, `desktop_window_focus`, `desktop_app_launch`, `desktop_app_quit`, `desktop_clipboard_read`, `desktop_clipboard_write` | System Events AppleScript + NSWorkspace + NSPasteboard |
| Location | `location_current`, `location_geocode`, `location_reverse_geocode` | CoreLocation |
| Mail | `mail_mailboxes_list`, `mail_search`, `mail_read`, `mail_send` | Mail AppleScript |
| Maps | `maps_search`, `maps_directions`, `maps_eta`, `maps_explore`, `maps_generate` | MapKit |
| Messages | `messages_chats_list`, `messages_fetch`, `messages_send` | SQLite (read) + AppleScript (send) |
| Music | `music_now_playing`, `music_control`, `music_catalog_search` | MusicKit + AppleScript |
| Notes | `notes_list`, `notes_search`, `notes_read`, `notes_create`, `notes_update`, `notes_delete`, `notes_folders_list`, `notes_folders_create` | Notes AppleScript |
| Reminders | `reminders_lists`, `reminders_fetch`, `reminders_create`, `reminders_update`, `reminders_complete`, `reminders_delete`, `reminders_lists_create`, `reminders_lists_delete`, `reminders_lists_rename` | EventKit |
| Shortcuts | `shortcuts_list`, `shortcuts_run`, `shortcuts_get_details`, `shortcuts_delete` | /usr/bin/shortcuts CLI |
| Utilities | `utilities_notification`, `utilities_beep` | UNUserNotificationCenter + AudioToolbox |
| Weather | `weather_current`, `weather_daily`, `weather_hourly`, `weather_minute` | WeatherKit (Release only) |

### Patched
- MCP Swift SDK `NetworkTransport.swift` -- fixed 2 `CheckedContinuation` data races (SendFlag/RecvFlag wrappers). Patch is in local DerivedData, not committed to SDK repo.

### Unreleased upstream branches
- `mattt/files-service` -- File system access via MCP resource template. Needs cleanup (disables sandbox, changes bundle ID, has merge conflicts).

### Known Issues
- Bonjour relay is fragile under connection churn (rapid mcp2cli calls)
- MCP Swift SDK may have more concurrency bugs beyond the 2 we patched
- `applescript_execute` and `chrome_execute_javascript` are arbitrary code execution (by design, annotated destructiveHint)
- `notes_search` is slow on large libraries (AppleScript `whose plaintext contains` is O(n))
- `mail_search` without mailbox scope can be slow on large mailboxes
- Desktop `windows_list`/`window_move` require System Events automation permission
- Services disabled by default need one-time enable via iMCP menubar UI or `defaults write com.rodaddy.iMCP <key>Enabled -bool true`
- ServerController.swift is 1,075 lines (tech debt -- needs extraction)
- `runScript` osascript pattern duplicated across 5 services (extract shared runner)
- Contacts error domain is "ContactsService" instead of "ContactsError" (upstream inconsistency)

## Build

```bash
# From source (ad-hoc signing)
xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""

# Or open in Xcode with your signing identity
open iMCP.xcodeproj
# Set Team to "Rico Rojas (Personal Team)" on both targets
# Remove WeatherKit capability (personal teams don't support it)
# Bundle ID: com.rodaddy.iMCP
```

## mcp2cli Integration

Registered as `imcp` service in `~/.config/mcp2cli/services.json`:
```json
{
  "imcp": {
    "backend": "stdio",
    "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server",
    "blockTools": ["capture_take_picture", "capture_record_audio"]
  }
}
```

Note: consider adding `applescript_execute`, `chrome_execute_javascript`, `messages_send` to blockTools depending on security policy.

## Corrections

- WeatherKit needs coordinates (lat/lon), not city names -- use `maps_search` to geocode first
- `maps_eta` and `maps_directions` need `originAddress`/`destinationAddress`, not `from`/`to`
- `events_create` uses flat params (`title`, `start`, `end`, `calendar`), not nested objects
- `events_create` supports recurrence via `recurrence` object (`frequency`, `interval`, `daysOfWeek`, `endDate`, `occurrenceCount`)
- iMCP.app must be running in menubar for imcp-server CLI to work
- Calendar/Reminder identifiers are returned in `@id` field -- use this for update/delete
- Named calendar lookup is case-insensitive by title -- ambiguous if two sources share a name
- Notes `body` in create/update is HTML (Notes.app uses rich text internally)
- AppleScript-based tools need one-time Automation permission grant per target app
