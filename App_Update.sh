#!/bin/zsh
set -u

autoload is-at-least

# -----------------------------
# Config
# -----------------------------
dialogapp="/usr/local/bin/dialog"
dialoglog="/var/tmp/dialog.log"

org="test"
softwareportal="Self Service"
dialogheight="430"
iconsize="120"
waittime=60

# -----------------------------
# Helpers
# -----------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

get_console_user() {
  /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}' | head -n 1
}

safe_key() {
  # turn arbitrary string into a stable safe key
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g'
}

get_bundle_id() {
  local app="$1"
  /usr/bin/defaults read "${app}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true
}

get_short_version() {
  local app="$1"
  /usr/bin/defaults read "${app}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
}

# defaults wrapper that works with explicit plist file paths
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

# -----------------------------
# Params (Jamf)
# -----------------------------
if [[ "${1:-}" == "test" ]]; then
  title="iboss"
  apptoupdate="/Applications/iboss macOS Cloud Connector.app"
  appversionrequired="7.0.2.0"
  maxdeferrals="5"
  additionalinfo="\n\nYour VPN will disconnect during the update. Estimated installation time: 1 minute\n\n"
  policytrigger="YOUR_TRIGGER_HERE"
  deferralScope="user"
  resetMode="onUpdate"
else
  title="${4:-}"
  apptoupdate="${5:-}"
  appversionrequired="${6:-}"
  maxdeferrals="${7:-}"
  additionalinfo="${8:-""}"      # optional
  policytrigger="${9:-}"
  deferralScope="${10:-user}"    # user|device
  resetMode="${11:-onUpdate}"    # onUpdate|never

  if [[ -z "$title" || -z "$apptoupdate" || -z "$appversionrequired" || -z "$maxdeferrals" || -z "$policytrigger" ]]; then
    log "Incorrect parameters entered."
    log "Required: $4 title, $5 app path, $6 required version, $7 max deferrals, $9 policy trigger"
    exit 1
  fi
fi

# -----------------------------
# Preconditions
# -----------------------------
if [[ ! -x "$dialogapp" ]]; then
  log "swiftDialog not found at $dialogapp"
  exit 1
fi

if [[ ! -e "$apptoupdate" ]]; then
  log "App does not exist: $apptoupdate"
  exit 0
fi

installedappversion="$(get_short_version "$apptoupdate")"
if [[ -z "$installedappversion" ]]; then
  log "Could not determine installed version for $apptoupdate"
  # You can choose to continue prompting anyway; I’ll exit to avoid false prompts.
  exit 1
fi

is-at-least "$appversionrequired" "$installedappversion"
result=$?
if [[ $result -eq 0 ]]; then
  log "Already up to date ($installedappversion >= $appversionrequired)"
  exit 0
fi

# -----------------------------
# Deferral state location + key
# -----------------------------
consoleUser="$(get_console_user)"
bundleId="$(get_bundle_id "$apptoupdate")"
appName="$(basename "$apptoupdate")"

keyBase="$bundleId"
if [[ -z "$keyBase" ]]; then
  keyBase="$appName"
fi

# Reverse-DNS-ish stable domain
domain="com.${org}.$(safe_key "$keyBase").deferrals"

# Choose plist storage
plist=""
if [[ "$deferralScope" == "device" || -z "$consoleUser" || "$consoleUser" == "loginwindow" ]]; then
  plist="/Library/Preferences/${domain}.plist"
else
  plist="/Users/${consoleUser}/Library/Preferences/${domain}.plist"
fi

# -----------------------------
# Read / initialize deferral state
# -----------------------------
# Keys:
# Remaining (int)
# Max (int)
# RequiredVersion (string)
# LastDeferEpoch (int)
# DeferralVersionTag (string)  # used to reset when version changes (optional)

remaining="$(d_read "$plist" Remaining || true)"
storedMax="$(d_read "$plist" Max || true)"
storedReqVer="$(d_read "$plist" RequiredVersion || true)"
storedTag="$(d_read "$plist" DeferralVersionTag || true)"

# Initialize if missing
if [[ -z "${remaining}" || -z "${storedMax}" ]]; then
  remaining="$maxdeferrals"
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" Max "$maxdeferrals"
  d_write_str "$plist" RequiredVersion "$appversionrequired"
  d_write_str "$plist" DeferralVersionTag "$appversionrequired"
else
  # If admin changed maxdeferrals upward/downward, clamp remaining intelligently:
  # - If Max changed, adjust remaining proportionally by diff, but never exceed new max.
  if [[ "$storedMax" != "$maxdeferrals" ]]; then
    # remaining = min(newMax, remaining + (newMax - oldMax))
    diff=$(( maxdeferrals - storedMax ))
    newRemaining=$(( remaining + diff ))
    if (( newRemaining > maxdeferrals )); then newRemaining=$maxdeferrals; fi
    if (( newRemaining < 0 )); then newRemaining=0; fi
    remaining="$newRemaining"
    d_write_int "$plist" Remaining "$remaining"
    d_write_int "$plist" Max "$maxdeferrals"
  fi

  # Reset deferrals when required version changes (optional)
  if [[ "$resetMode" == "onUpdate" && -n "$storedTag" && "$storedTag" != "$appversionrequired" ]]; then
    remaining="$maxdeferrals"
    d_write_int "$plist" Remaining "$remaining"
    d_write_str "$plist" DeferralVersionTag "$appversionrequired"
    d_write_str "$plist" RequiredVersion "$appversionrequired"
  else
    # keep RequiredVersion current for display
    d_write_str "$plist" RequiredVersion "$appversionrequired"
  fi
fi

if (( remaining > 0 )); then
  infobuttontext="Defer"
else
  infobuttontext="Max Deferrals Reached"
fi

# -----------------------------
# Dialog
# -----------------------------
message="${org} requires **${title}** to be updated to version **${appversionrequired}**.\n\n\
_Current version: **${installedappversion}**_\n\
_Remaining Deferrals: **${remaining}**_\n\n\
${additionalinfo}\n\
You can also update at any time from ${softwareportal}. Search for **${title}**."

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

# swiftDialog exit codes vary by options, but with --quitoninfo:
# - 0 typically means button1 (Continue)
# - 3 often means info button (Defer)
if [[ $dialogExit -eq 3 && $remaining -gt 0 ]]; then
  remaining=$(( remaining - 1 ))
  d_write_int "$plist" Remaining "$remaining"
  d_write_int "$plist" LastDeferEpoch "$(date +%s)"
  log "Deferred. Remaining deferrals: $remaining"
  exit 0
fi

# If remaining is 0, they shouldn't be able to "defer" usefully; treat as continue.
log "Continuing with install trigger: $policytrigger"

# Optionally clear remaining when continuing so future prompts reset naturally
# (Personally I keep it, but your original deletes it; I'll mirror your behavior.)
d_delete_key "$plist" Remaining
d_delete_key "$plist" LastDeferEpoch

# -----------------------------
# Wait/progress dialog
# -----------------------------
rm -f "$dialoglog" 2>/dev/null || true

"$dialogapp" \
  --title "${title} Install" \
  --icon "${apptoupdate}" \
  --height 230 \
  --progress "${waittime}" \
  --progresstext "" \
  --message "Please wait while ${title} is installed..." \
  --commandfile "$dialoglog" &

for ((i=1; i<=waittime; i++)); do
  echo "progress: increment" >> "$dialoglog"
  sleep 1
  if [[ $i -eq $waittime ]]; then
    echo "progress: complete" >> "$dialoglog"
    sleep 1
    echo "quit:" >> "$dialoglog"
  fi
done &

# -----------------------------
# Run Jamf policy
# -----------------------------
/usr/local/bin/jamf policy -event "$policytrigger"
exit $?
