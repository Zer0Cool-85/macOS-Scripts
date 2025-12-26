#!/bin/zsh
###############################################################################
# SwiftDialog + Jamf Policy Install Prompt with Deferrals (Reusable Template)
#
# PURPOSE
#   This script prompts an end user to update an installed application to a
#   required minimum version. The user may defer up to a configured number of
#   times. When the user proceeds (or deferrals are exhausted), the script runs
#   a Jamf policy via a custom event trigger (jamf policy -event <trigger>).
#
# WHY THIS EXISTS
#   - Some apps need to be kept at/above a minimum version for security,
#     compatibility, or compliance.
#   - We want a user-friendly prompt (SwiftDialog) and controlled deferrals.
#   - We want one script that can be reused for ANY application by passing
#     Jamf script parameters ($4..$12).
#
# HIGH-LEVEL FLOW
#   1) Validate parameters & prerequisites (SwiftDialog exists, app exists).
#   2) Read installed app version from Info.plist.
#   3) If already compliant (installed >= required), exit.
#   4) Determine where to store deferral state (per-user or per-device).
#   5) Read deferral state; initialize it if missing.
#   6) Show SwiftDialog prompt (Continue or Defer).
#   7) If user defers and has deferrals remaining -> decrement & exit 0.
#   8) Otherwise -> show a wait/progress dialog and run Jamf policy trigger.
#
# DEFERRAL STORAGE DESIGN
#   - Deferral state is stored in a plist file.
#   - Default scope is PER-USER:
#       ~/Library/Preferences/com.<org>.<shortname>.deferrals.plist
#     This is "user friendly" (inspectable) and follows macOS conventions for
#     per-user preferences.
#   - Optional scope is PER-DEVICE:
#       /Library/Preferences/com.<org>.<shortname>.deferrals.plist
#     This is useful when deferrals should be shared across all users on the
#     same Mac (shared machines, multiple local accounts, etc).
#
# SHORTNAME DESIGN (TITLE-BASED)
#   We build a stable identifier from the human-friendly "title" rather than
#   bundle ID. Why:
#     - Admins can predict it, find it quickly, and document it easily.
#     - It remains stable even if the app path changes.
#   We "normalize" the title by stripping spaces and punctuation to create a
#   safe filename component:
#     "Google Chrome" -> "googlechrome"
#   You can override the derived shortname with a Jamf parameter if desired.
#
# REQUIRED JAMF PARAMETERS
#   $4  Title (display name shown to user; also used to derive shortname)
#   $5  App path (full path to .app bundle)
#   $6  Required version (string, compared using zsh is-at-least)
#   $7  Max deferrals (integer)
#   $9  Jamf policy trigger (custom event name)
#
# OPTIONAL JAMF PARAMETERS
#   $8  Additional info text (shown in prompt; can include \n new lines)
#   $10 Deferral scope: "user" (default) or "device"
#   $11 Reset mode: "onUpdate" (default) or "never"
#       - "onUpdate" resets deferrals automatically if the required version
#         changes in the future (ex: you bump required version from 1.2 -> 1.3)
#   $12 Shortname override (ex: "iboss" instead of "ibossmacoscloudconnector")
#
# EXAMPLE JAMF POLICY PARAMS
#   $4  Google Chrome
#   $5  /Applications/Google Chrome.app
#   $6  126.0.6478.127
#   $7  3
#   $8  \n\nThis update takes ~2 minutes.\n\n
#   $9  install_chrome_latest
#   $10 user
#   $11 onUpdate
#   $12 chrome
#
# NOTES ABOUT VERSION COMPARISON
#   - We read CFBundleShortVersionString from Info.plist.
#   - We compare installed vs required using zsh's is-at-least:
#       is-at-least <required> <installed>
#     Returns 0 if installed >= required.
#
# NOTES ABOUT SwiftDialog
#   - This assumes dialog is installed at /usr/local/bin/dialog.
#   - We use --quitoninfo so "info" button acts like a "Defer" action.
#   - SwiftDialog exit codes can vary slightly by version/config, but commonly:
#       0 = primary button ("Continue")
#       3 = info button ("Defer") when --quitoninfo is used
#
# SAFETY SETTINGS
#   set -u: treat unset variables as an error.
#     - This prevents silent failures when a Jamf parameter is missing.
#     - We use safe expansion like "${4:-}" to avoid crashing on optional params.
###############################################################################

set -u
autoload is-at-least

###############################################################################
# STATIC CONFIG (edit here if you want global defaults)
###############################################################################
dialogapp="/usr/local/bin/dialog"

# Command file used by SwiftDialog for progress updates (a simple text file).
# /var/tmp persists across reboots more often than /tmp, but is still "temp-ish".
dialoglog="/var/tmp/dialog.log"

org="test"                      # Used in plist domain: com.<org>.<shortname>.deferrals
softwareportal="Self Service"   # For messaging only (what end user sees)
dialogheight="430"
iconsize="120"
waittime=60                     # Seconds to show a progress dialog during install

###############################################################################
# HELPERS
###############################################################################

# Basic logger to stdout (Jamf will capture in policy logs/jamf.log output)
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Returns the currently logged-in console user (empty or "loginwindow" if none)
get_console_user() {
  /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}' | head -n 1
}

# Normalize a title into a safe "shortname" used in plist filenames/domains.
# - lowercases
# - strips anything not a-z or 0-9
# Examples:
#   "Google Chrome" -> "googlechrome"
#   "Microsoft Teams (work)" -> "microsoftteamswork"
normalize_title() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+//g'
}

# Read the installed short version from an app bundle.
# Returns empty string if missing/unreadable.
get_short_version() {
  local app="$1"
  /usr/bin/defaults read "${app}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
}

# defaults wrappers that work with explicit plist file paths (recommended here).
# Why explicit file paths?
#   - Easier to reason about where data lives (especially for per-user files).
#   - Makes troubleshooting simple (open the plist file directly if needed).
d_read() {
  local plist="$1" key="$2"
  /usr/bin/defaults read "$plist" "$key" 2>/dev/null
}
d_write_int() {
  local plist="$1" key="$2" val="$3"
  /usr/bin/defaults write "$plist" "$key" -int "$val"
}
d_write_str() {
  local plist="$1" key="$2" val="$3"
  /usr/bin/defaults write "$plist" "$key" -string "$val"
}
d_delete_key() {
  local plist="$1" key="$2"
  /usr/bin/defaults delete "$plist" "$key" 2>/dev/null || true
}

###############################################################################
# INPUT PARAMETERS (Jamf passes script parameters starting at $4)
###############################################################################
title="${4:-}"
apptoupdate="${5:-}"
appversionrequired="${6:-}"
maxdeferrals="${7:-}"
additionalinfo="${8:-""}"       # Optional message text
policytrigger="${9:-}"

deferralScope="${10:-user}"     # "user" (default) or "device"
resetMode="${11:-onUpdate}"     # "onUpdate" (default) or "never"
shortnameOverride="${12:-""}"   # Optional override for shortname derived from title

###############################################################################
# BASIC VALIDATION
###############################################################################
if [[ -z "$title" || -z "$apptoupdate" || -z "$appversionrequired" || -z "$maxdeferrals" || -z "$policytrigger" ]]; then
  log "ERROR: Missing required Jamf parameters."
  log "Required: $4 title, $5 app path, $6 required version, $7 max deferrals, $9 policy trigger"
  exit 1
fi

if [[ ! -x "$dialogapp" ]]; then
  log "ERROR: SwiftDialog not found at $dialogapp"
  exit 1
fi

if [[ ! -e "$apptoupdate" ]]; then
  # If the app isn't installed, we generally do not prompt.
  # Depending on your environment, you may want to:
  #   - exit 0 (silent), or
  #   - run the install policy anyway.
  log "INFO: App not found on device: $apptoupdate"
  exit 0
fi

###############################################################################
# VERSION CHECK (exit if already compliant)
###############################################################################
installedappversion="$(get_short_version "$apptoupdate")"

if [[ -z "$installedappversion" ]]; then
  # If CFBundleShortVersionString is missing, you could optionally:
  #   - fall back to CFBundleVersion, or
  #   - continue prompting anyway.
  log "ERROR: Could not determine installed version (CFBundleShortVersionString) for $apptoupdate"
  exit 1
fi

# Compare installed vs required
is-at-least "$appversionrequired" "$installedappversion"
compareResult=$?

if [[ $compareResult -eq 0 ]]; then
  log "INFO: Already compliant. Installed=$installedappversion Required=$appversionrequired"
  exit 0
fi

###############################################################################
# DEFERRAL KEY/DOMAIN + STORAGE PATH
###############################################################################
# Determine shortname:
#   - If override provided ($12), use it
#   - Else derive from title
if [[ -n "$shortnameOverride" ]]; then
  shortname="$(normalize_title "$shortnameOverride")"
else
  shortname="$(normalize_title "$title")"
fi

# Build a reverse-DNS-ish domain (readable + predictable)
domain="com.${org}.${shortname}.deferrals"

# Determine whether to store per-user or per-device:
#   - Per-user is default and is "user friendly" to find in Finder.
#   - Per-device is useful when multiple users share a Mac.
consoleUser="$(get_console_user)"

if [[ "$deferralScope" == "device" || -z "$consoleUser" || "$consoleUser" == "loginwindow" ]]; then
  plist="/Library/Preferences/${domain}.plist"
else
  plist="/Users/${consoleUser}/Library/Preferences/${domain}.plist"
fi

###############################################################################
# READ / INITIALIZE DEFERRAL STATE
###############################################################################
# Keys in plist (documenting for future admins):
#   Remaining         (int)   How many deferrals are left
#   Max               (int)   Max deferrals allowed (from Jamf parameter)
#   RequiredVersion   (string)The version currently required (for display/troubleshooting)
#   DeferralVersionTag(string)Used to detect version bumps and reset deferrals (if resetMode=onUpdate)
#   LastDeferEpoch    (int)   Epoch timestamp of most recent deferral

remaining="$(d_read "$plist" Remaining || true)"
storedMax="$(d_read "$plist" Max || true)"
storedTag="$(d_read "$plist" DeferralVersionTag || true)"

# If state is missing, initialize.
# We intentionally initialize Remaining to maxdeferrals so the end user sees full
# deferral count the first time they are prompted.
if [[ -z "$remaining" || -z "$storedMax" ]]; then
  remaining="$maxdeferrals"
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" Max "$maxdeferrals"
  d_write_str "$plist" RequiredVersion "$appversionrequired"
  d_write_str "$plist" DeferralVersionTag "$appversionrequired"
else
  # If an admin changes maxdeferrals later (policy updated), we reconcile:
  #   remaining = min(newMax, remaining + (newMax - oldMax))
  # This keeps behavior intuitive:
  #   - If you INCREASE max, users get a few more deferrals.
  #   - If you DECREASE max, users lose deferrals but not below zero.
  if [[ "$storedMax" != "$maxdeferrals" ]]; then
    diff=$(( maxdeferrals - storedMax ))
    newRemaining=$(( remaining + diff ))
    if (( newRemaining > maxdeferrals )); then newRemaining=$maxdeferrals; fi
    if (( newRemaining < 0 )); then newRemaining=0; fi
    remaining="$newRemaining"
    d_write_int "$plist" Remaining "$remaining"
    d_write_int "$plist" Max "$maxdeferrals"
  fi

  # Reset deferrals when the required version changes (optional behavior).
  # This is useful when you increase the required version and want to grant
  # a fresh deferral set for the new requirement.
  if [[ "$resetMode" == "onUpdate" && -n "$storedTag" && "$storedTag" != "$appversionrequired" ]]; then
    remaining="$maxdeferrals"
    d_write_int "$plist" Remaining "$remaining"
    d_write_str "$plist" DeferralVersionTag "$appversionrequired"
  fi

  # Keep RequiredVersion current for readability/debugging.
  d_write_str "$plist" RequiredVersion "$appversionrequired"
fi

###############################################################################
# DIALOG TEXT + BUTTONS
###############################################################################
# Info button ("Defer") should only be meaningful if remaining > 0
if (( remaining > 0 )); then
  infobuttontext="Defer"
else
  # We still show an info button label, but you could also choose to remove
  # the info button entirely when remaining == 0 by changing the dialog call.
  infobuttontext="Max Deferrals Reached"
fi

# Build message using SwiftDialog markdown formatting.
# NOTE: Use \n new lines; SwiftDialog supports GitHub-ish markdown for **bold**
message="${org} requires **${title}** to be updated to version **${appversionrequired}**.\n\n\
_Current version: **${installedappversion}**_\n\
_Remaining Deferrals: **${remaining}**_\n\n\
${additionalinfo}\n\
You can also update at any time from ${softwareportal}. Search for **${title}**."

###############################################################################
# SHOW MAIN PROMPT
###############################################################################
"$dialogapp" \
  --title "${title} Update" \
  --titlefont colour=#00a4c7 \
  --icon "${apptoupdate}" \
  --message "${message}" \
  --infobuttontext "${infobuttontext}" \
  --button1text "Continue" \
  --height "${dialogheight}" \
  --iconsize "${iconsize}" \
  --quitoninfo \
  --alignment centre \
  --centreicon

dialogExit=$?

###############################################################################
# HANDLE USER CHOICE
###############################################################################
# With --quitoninfo, SwiftDialog typically returns exit code 3 when the user
# clicks the info button. If deferrals remain, decrement and exit successfully.
if [[ $dialogExit -eq 3 && $remaining -gt 0 ]]; then
  remaining=$(( remaining - 1 ))
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" LastDeferEpoch "$(date +%s)"
  log "INFO: User deferred. Remaining=$remaining (plist=$plist)"
  exit 0
fi

# If we reach here:
#   - User clicked "Continue", OR
#   - They attempted to defer with 0 remaining (treated as continue), OR
#   - Some other exit code occurred (we still proceed to enforcement).
log "INFO: Proceeding with installation via Jamf trigger '$policytrigger'"

# Optional cleanup:
# Original behavior removed deferral count once user continues.
# This makes the next prompt (if it happens again) start at a fresh max.
# Some orgs prefer to keep state for audit/tracking; choose what you prefer.
d_delete_key "$plist" Remaining
d_delete_key "$plist" LastDeferEpoch

###############################################################################
# SHOW INSTALL / WAIT DIALOG
###############################################################################
# This is a "cosmetic" progress UI so the user sees something happening
# while Jamf policy runs. It does NOT measure real install progress.
rm -f "$dialoglog" 2>/dev/null || true

"$dialogapp" \
  --title "${title} Install" \
  --icon "${apptoupdate}" \
  --height 230 \
  --progress "${waittime}" \
  --progresstext "" \
  --message "Please wait while ${title} is installed..." \
  --commandfile "$dialoglog" &

# Drive progress bar forward for $waittime seconds
for ((i=1; i<=waittime; i++)); do
  echo "progress: increment" >> "$dialoglog"
  sleep 1
  if [[ $i -eq $waittime ]]; then
    echo "progress: complete" >> "$dialoglog"
    sleep 1
    echo "quit:" >> "$dialoglog"
  fi
done &

###############################################################################
# RUN THE JAMF POLICY
###############################################################################
# This is the enforcement/install step. The policy should:
#   - install/update the app
#   - handle any required user prompts (if unavoidable)
#   - return an appropriate exit code
/usr/local/bin/jamf policy -event "$policytrigger"
exit $?
