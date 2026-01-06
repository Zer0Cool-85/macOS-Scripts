#!/bin/zsh
###############################################################################
# SwiftDialog + Jamf Policy Install Prompt with Deferrals (Reusable Template)
#
# PARAMETER MAP (Jamf Pro script parameters allow $4 - $11)
#   $4  Title (display name shown to user)
#   $5  App path (full path to .app bundle)
#   $6  Required version (string)
#   $7  Max deferrals (integer)
#   $8  Additional info (optional message text; may include \n for new lines)
#   $9  Jamf policy trigger (custom event name)
#   $10 Wait time (seconds) for the progress dialog while install runs (optional)
#   $11 Shortname override (optional; e.g. "chrome" instead of "googlechrome")
#
# GLOBALS (edit in a new copy of the script if needed)
#   deferralScope = "user"  (default) OR "device"
#   resetMode     = "onUpdate" (default) OR "never"
#
# STORAGE
#   Per-user:  ~/Library/Preferences/com.<org>.<shortname>.deferrals.plist
#   Per-device:/Library/Preferences/com.<org>.<shortname>.deferrals.plist
#
# STATE KEYS (inside the plist)
#   Remaining          (int)    deferrals left
#   Max                (int)    max deferrals
#   RequiredVersion    (string) latest required version (for human readability)
#   DeferralVersionTag (string) used to detect required-version changes & reset
#   LastDeferEpoch     (int)    last deferral time (epoch)
###############################################################################

set -u
autoload is-at-least

###############################################################################
# GLOBAL CONFIG (these should rarely change)
###############################################################################
dialogapp="/usr/local/bin/dialog"
dialoglog="/var/tmp/dialog.log"

org="test"
softwareportal="Self Service"
dialogheight="430"
iconsize="120"

###############################################################################
# GLOBAL DEFERRAL BEHAVIOR (edit these in a new copy if needed)
###############################################################################
# Most orgs want:
#   - per-user deferrals (each user gets their own counter)
#   - reset deferrals when the required version changes (new update cycle)
deferralScope="user"     # "user" or "device"
resetMode="onUpdate"     # "onUpdate" or "never"

###############################################################################
# HELPERS
###############################################################################
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

get_console_user() {
  /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}' | head -n 1
}

# Normalize a title/shortname into a safe identifier:
# "Google Chrome" -> "googlechrome"
normalize_title() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+//g'
}

get_short_version() {
  local app="$1"
  /usr/bin/defaults read "${app}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
}

# defaults wrappers that explicitly target a plist path
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
# JAMF PARAMETERS ($4 - $11)
###############################################################################
title="${4:-}"
apptoupdate="${5:-}"
appversionrequired="${6:-}"
maxdeferrals="${7:-}"
additionalinfo="${8:-""}"
policytrigger="${9:-}"

# $10 waittime (seconds). If not provided, default to 60.
waittimeParam="${10:-}"
if [[ -n "$waittimeParam" ]]; then
  waittime="$waittimeParam"
else
  waittime=60
fi

# $11 shortname override (optional)
shortnameOverride="${11:-""}"

###############################################################################
# VALIDATION / GUARDRAILS
###############################################################################
if [[ -z "$title" || -z "$apptoupdate" || -z "$appversionrequired" || -z "$maxdeferrals" || -z "$policytrigger" ]]; then
  log "ERROR: Missing required Jamf parameters."
  log "Required: $4 title, $5 app path, $6 required version, $7 max deferrals, $9 policy trigger"
  exit 1
fi

# Ensure waittime is an integer >= 0 (lightweight validation)
if ! [[ "$waittime" =~ '^[0-9]+$' ]]; then
  log "ERROR: waittime must be a non-negative integer. Got: $waittime"
  exit 1
fi

if [[ ! -x "$dialogapp" ]]; then
  log "ERROR: SwiftDialog not found at $dialogapp"
  exit 1
fi

if [[ ! -e "$apptoupdate" ]]; then
  log "INFO: App not found on device: $apptoupdate"
  exit 0
fi

###############################################################################
# VERSION CHECK (exit if already compliant)
###############################################################################
installedappversion="$(get_short_version "$apptoupdate")"

if [[ -z "$installedappversion" ]]; then
  log "ERROR: Could not read CFBundleShortVersionString from $apptoupdate"
  exit 1
fi

is-at-least "$appversionrequired" "$installedappversion"
compareResult=$?

if [[ $compareResult -eq 0 ]]; then
  log "INFO: Already compliant. Installed=$installedappversion Required=$appversionrequired"
  exit 0
fi

###############################################################################
# DETERMINE DEFERRAL PLIST NAME + LOCATION
###############################################################################
# shortname selection:
#   - If $11 provided, use it (normalized)
#   - Else derive from $4 title (normalized)
if [[ -n "$shortnameOverride" ]]; then
  shortname="$(normalize_title "$shortnameOverride")"
else
  shortname="$(normalize_title "$title")"
fi

domain="com.${org}.${shortname}.deferrals"

# Pick per-user or per-device storage
consoleUser="$(get_console_user)"
if [[ "$deferralScope" == "device" || -z "$consoleUser" || "$consoleUser" == "loginwindow" ]]; then
  plist="/Library/Preferences/${domain}.plist"
else
  plist="/Users/${consoleUser}/Library/Preferences/${domain}.plist"
fi

###############################################################################
# READ / INITIALIZE DEFERRAL STATE
###############################################################################
remaining="$(d_read "$plist" Remaining || true)"
storedMax="$(d_read "$plist" Max || true)"
storedTag="$(d_read "$plist" DeferralVersionTag || true)"

# Initialize if missing
if [[ -z "$remaining" || -z "$storedMax" ]]; then
  remaining="$maxdeferrals"
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" Max "$maxdeferrals"
  d_write_str "$plist" RequiredVersion "$appversionrequired"
  d_write_str "$plist" DeferralVersionTag "$appversionrequired"
else
  # If Max deferrals changed since last run, reconcile remaining intelligently:
  if [[ "$storedMax" != "$maxdeferrals" ]]; then
    diff=$(( maxdeferrals - storedMax ))
    newRemaining=$(( remaining + diff ))
    if (( newRemaining > maxdeferrals )); then newRemaining=$maxdeferrals; fi
    if (( newRemaining < 0 )); then newRemaining=0; fi
    remaining="$newRemaining"
    d_write_int "$plist" Remaining "$remaining"
    d_write_int "$plist" Max "$maxdeferrals"
  fi

  # Reset deferrals automatically when required version changes (default behavior)
  if [[ "$resetMode" == "onUpdate" && -n "$storedTag" && "$storedTag" != "$appversionrequired" ]]; then
    log "INFO: Required version changed ($storedTag -> $appversionrequired). Resetting deferrals."
    remaining="$maxdeferrals"
    d_write_int "$plist" Remaining "$remaining"
    d_write_str "$plist" DeferralVersionTag "$appversionrequired"
  fi

  # Keep the RequiredVersion key current for debugging/readability
  d_write_str "$plist" RequiredVersion "$appversionrequired"
fi

###############################################################################
# BUILD MAIN PROMPT
###############################################################################
if (( remaining > 0 )); then
  infobuttontext="Defer"
else
  infobuttontext="Max Deferrals Reached"
fi

message="${org} requires **${title}** to be updated to version **${appversionrequired}**.\n\n\
_Current version: **${installedappversion}**_\n\
_Remaining Deferrals: **${remaining}**_\n\n\
${additionalinfo}\n\
You can also update at any time from ${softwareportal}. Search for **${title}**."

###############################################################################
# SHOW PROMPT
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
# IF USER DEFERS (AND DEFERRALS REMAIN), DECREMENT + EXIT
###############################################################################
if [[ $dialogExit -eq 3 && $remaining -gt 0 ]]; then
  remaining=$(( remaining - 1 ))
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" LastDeferEpoch "$(date +%s)"
  log "INFO: User deferred. Remaining=$remaining (plist=$plist)"
  exit 0
fi

###############################################################################
# OTHERWISE, PROCEED WITH INSTALL/UPDATE
###############################################################################
log "INFO: Proceeding with installation via Jamf trigger '$policytrigger'"

# Mirror your original behavior: once user proceeds, clear remaining so future
# prompts start fresh unless you prefer to keep for audit/tracking.
d_delete_key "$plist" Remaining
d_delete_key "$plist" LastDeferEpoch

###############################################################################
# SHOW PROGRESS DIALOG (COSMETIC TIMER)
###############################################################################
# This progress is time-based (not real install progress). It's meant to give
# the user something to look at while Jamf runs in the background.
rm -f "$dialoglog" 2>/dev/null || true

"$dialogapp" \
  --title "${title} Install" \
  --icon "${apptoupdate}" \
  --height 230 \
  --progress "${waittime}" \
  --progresstext "" \
  --message "Please wait while ${title} is installed..." \
  --commandfile "$dialoglog" &

# Drive the progress bar forward for waittime seconds
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
# RUN JAMF POLICY
###############################################################################
/usr/local/bin/jamf policy -event "$policytrigger"
exit $?
