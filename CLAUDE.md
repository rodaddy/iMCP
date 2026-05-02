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
- CLI subprocess discovers app via Bonjour, relays JSON-RPC over local TCP, and reconnects after transient app-side socket drops
- Services are modular: `App/Services/<Name>.swift` (one file per service, split into extensions when >600 lines)
- Uses official MCP Swift SDK (`modelcontextprotocol/swift-sdk`)
- ToolBuilder supports composing tools from multiple computed properties via `buildExpression`
- AppleScript-based services use `/usr/bin/osascript` subprocess with task-group timeout pattern
- Optional per-user launchd keepalive lives in `Scripts/launchd/` and relaunches `/Applications/iMCP.app` after crashes/non-zero exits
- Remotes: `origin` = rodaddy/iMCP (fork), `upstream` = mattt/iMCP

## Current State (2026-05-02)

### Working (93 tools, 91 via mcp2cli + 2 blocked, 17 services)

| Service | Tools | Framework |
|---------|-------|-----------|
| AppleScript | `applescript_execute`, `applescript_list_apps` | osascript subprocess |
| Calendar | `calendars_list`, `events_fetch`, `events_create`, `events_update`, `events_delete` | EventKit |
| Capture | `capture_take_screenshot`, `capture_record_screen` (camera/mic blocked by mcp2cli) | ScreenCaptureKit + AVAssetWriter |
| Chrome | `chrome_tabs_list`, `chrome_navigate`, `chrome_tab_activate`, `chrome_window_create`, `chrome_execute_javascript` | Chrome AppleScript |
| Contacts | `contacts_me`, `contacts_search`, `contacts_create`, `contacts_update`, `contacts_delete`, `contacts_groups_list` | Contacts framework |
| Desktop | `desktop_windows_list`, `desktop_window_move`, `desktop_window_focus`, `desktop_app_launch`, `desktop_app_quit`, `desktop_clipboard_read`, `desktop_clipboard_write`, `desktop_ui_elements`, `desktop_ui_click`, `desktop_ui_type`, `desktop_ui_read` | System Events AppleScript + NSWorkspace + NSPasteboard + AXUIElement |
| Files | `files_list`, `files_read`, `files_info`, `files_search`, `files_write` | FileManager + UniformTypeIdentifiers |
| Location | `location_current`, `location_geocode`, `location_reverse_geocode` | CoreLocation |
| Mail | `mail_mailboxes_list`, `mail_search`, `mail_read`, `mail_send`, `mail_reply`, `mail_forward`, `mail_delete`, `mail_move`, `mail_flag`, `mail_mark_read` | Mail AppleScript |
| Maps | `maps_search`, `maps_directions`, `maps_eta`, `maps_explore`, `maps_generate` | MapKit |
| Messages | `messages_chats_list`, `messages_fetch`, `messages_send` | SQLite (read) + AppleScript (send) |
| Music | `music_now_playing`, `music_control`, `music_catalog_search` | MusicKit + AppleScript |
| Notes | `notes_list`, `notes_search`, `notes_read`, `notes_create`, `notes_update`, `notes_delete`, `notes_folders_list`, `notes_folders_create`, `notes_attach`, `notes_move` | Notes AppleScript |
| Reminders | `reminders_lists`, `reminders_fetch`, `reminders_create`, `reminders_update`, `reminders_complete`, `reminders_delete`, `reminders_lists_create`, `reminders_lists_delete`, `reminders_lists_rename` | EventKit |
| Shortcuts | `shortcuts_list`, `shortcuts_run`, `shortcuts_get_details`, `shortcuts_delete` | /usr/bin/shortcuts CLI |
| Utilities | `utilities_notification`, `utilities_beep` | UNUserNotificationCenter + AudioToolbox |
| Weather | `weather_current`, `weather_daily`, `weather_hourly`, `weather_minute` | WeatherKit (Release only) |

### Patched
- MCP Swift SDK `NetworkTransport.swift` -- fixed 2 `CheckedContinuation` data races (SendFlag/RecvFlag wrappers). Patch is in local DerivedData, not committed to SDK repo.
- `imcp-server` now separates MCP host stdin shutdown from app-side network loss. Stdin EOF exits normally; TCP resets/closed app connections trigger Bonjour rediscovery and reconnect.
- Added `Scripts/launchd/` keepalive installer/uninstaller for supervised local installs.

### Unreleased upstream branches
- `mattt/files-service` -- File system access via MCP resource template. Needs cleanup (disables sandbox, changes bundle ID, has merge conflicts).

### Known Issues
- Bonjour relay now reconnects after socket churn, but active in-flight tool calls can still fail during app restarts or listener recovery
- MCP Swift SDK may have more concurrency bugs beyond the 2 we patched
- `applescript_execute` and `chrome_execute_javascript` are arbitrary code execution (by design, annotated destructiveHint)
- `notes_search` is slow on large libraries (AppleScript `whose plaintext contains` is O(n))
- `mail_search` without mailbox/account scope can be slow on large mailboxes -- use account param
- Desktop `windows_list`/`window_move` require System Events automation permission
- Desktop `desktop_ui_*` tools require Accessibility permission (System Settings > Privacy > Accessibility)
- Services disabled by default need one-time enable via iMCP menubar UI or `defaults write com.rodaddy.iMCP <key>Enabled -bool true`
- ServerController.swift is 1,075 lines (tech debt -- needs extraction)
- `runScript` osascript pattern duplicated across 5 services (extract shared runner)
- Contacts error domain is "ContactsService" instead of "ContactsError" (upstream inconsistency)
- `notes_attach` requires file access entitlements -- works in debug, may sandbox-fail in release for paths outside temp directory
- `capture_record_screen` returns video as base64 over JSON-RPC -- mcp2cli 30s timeout too short for video. Save-to-file approach needed for practical use.

## Build

```bash
# From source (dev signed, no sandbox -- required for Accessibility/UI scripting)
xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Release build \
  CODE_SIGN_IDENTITY="Apple Development: rodaddy@icloud.com (M273RUB393)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="R8S2JFBBDW" \
  PROVISIONING_PROFILE_SPECIFIER="" ENABLE_APP_SANDBOX=NO

# Or open in Xcode with your signing identity
open iMCP.xcodeproj
# Set Team to "Rico Rojas (Personal Team)" on both targets
# Remove WeatherKit capability (personal teams don't support it)
# Bundle ID: com.rodaddy.iMCP
```

**Important:** After replacing the binary, re-grant iMCP in System Settings for Accessibility and Screen Recording (remove + re-add). Using stable code signing (`R8S2JFBBDW` team) minimizes how often this happens. Sandbox must be disabled for UI scripting tools.

### Local Install / Keepalive

```bash
# After a successful Release build:
BUILT_APP="$(xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Release -showBuildSettings | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ { dir=$2 } /FULL_PRODUCT_NAME/ { app=$2 } END { print dir "/" app }')"
ditto "$BUILT_APP" /Applications/iMCP.app

# Optional: install per-user launchd supervision.
Scripts/launchd/install-keepalive.sh

# Remove launchd supervision.
Scripts/launchd/uninstall-keepalive.sh
```

Do not leave backup bundles named `*.app*` in `/Applications`; Launchpad may show them as duplicate apps. Move backups outside `/Applications` or use a non-app suffix.

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
- `mail_send` supports comma-separated To/CC/BCC, `attachments` array of file paths, `isHTML` flag, `from` for account selection
- `mail_reply`/`mail_forward` use Mail.app's native reply/forward commands (preserves threading)
- `mail_search` supports `account` param to avoid ambiguous mailbox names across accounts
- `notes_attach` embeds files as true iCloud-syncing attachments (not HTML references)
- `notes_move` moves to pre-existing folders -- useful for shared/collaborative folder workflow
- `desktop_ui_click` element param uses AppleScript UI element references (e.g. `button "Done" of window 1`)
- `desktop_ui_type` types into whatever has focus -- use `desktop_window_focus` first to target an app
- `capture_record_screen` uses SCStream + AVAssetWriter at 30fps, quality controls resolution scaling
