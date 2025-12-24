#!/bin/bash

DIALOG="/usr/local/bin/dialog"
TITLE="System Info for Help Desk"
ICON="SF=laptopcomputer.and.arrow.down,weight=semibold"

# ---------- Collectors ----------

get_serial() {
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}'
}

get_os() {
  local name ver build
  name="$(sw_vers -productName 2>/dev/null)"
  ver="$(sw_vers -productVersion 2>/dev/null)"
  build="$(sw_vers -buildVersion 2>/dev/null)"
  printf "%s %s (%s)" "$name" "$ver" "$build"
}

get_model_marketing() {
  local model_id marketing plist
  model_id="$(sysctl -n hw.model 2>/dev/null)"
  plist="/System/Library/PrivateFrameworks/DeviceIdentity.framework/Versions/A/Resources/DeviceIdentityModelInfo.plist"
  marketing="$(/usr/libexec/PlistBuddy -c "Print :$model_id" "$plist" 2>/dev/null)"
  [[ -n "$marketing" ]] && printf "%s" "$marketing" || printf "%s" "$model_id"
}

get_uptime_dhm() {
  local boot now diff days hours mins
  boot="$(sysctl -n kern.boottime | awk -F'[ ,}]+' '{print $4}')"
  now="$(date +%s)"
  diff=$(( now - boot ))

  days=$(( diff / 86400 ))
  diff=$(( diff % 86400 ))
  hours=$(( diff / 3600 ))
  diff=$(( diff % 3600 ))
  mins=$(( diff / 60 ))

  if (( days > 0 )); then
    printf "%d day(s), %02d hour(s), %02d min(s)" "$days" "$hours" "$mins"
  else
    printf "%02d hour(s), %02d min(s)" "$hours" "$mins"
  fi
}

get_ip_summary() {
  local primary_if ip4 ssid
  primary_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  [[ -n "$primary_if" ]] && ip4="$(ipconfig getifaddr "$primary_if" 2>/dev/null)"

  ssid="$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null \
    | awk -F': ' '/ SSID/{print $2; exit}')"

  if [[ -n "$primary_if" && -n "$ip4" ]]; then
    if [[ -n "$ssid" ]]; then
      printf "%s: %s (Wi-Fi: %s)" "$primary_if" "$ip4" "$ssid"
    else
      printf "%s: %s" "$primary_if" "$ip4"
    fi
  else
    echo "Unknown"
  fi
}

get_last_successful_policy_checkin() {
  local log="/var/log/jamf.log"
  [[ -f "$log" ]] || { echo "jamf.log not found"; return 0; }

  awk '
    /Checking for policies/ {
      chk_line = $0
      if (getline next_line) {
        if (next_line !~ /Could not connect to the JSS/) {
          last_ok = chk_line
        }
      }
    }
    END {
      if (last_ok != "") print last_ok
      else print "No successful policy check found"
    }
  ' "$log"
}

get_jamf_server_status() {
  local jamf_bin="/usr/local/bin/jamf"
  local output server availability

  if [[ ! -x "$jamf_bin" ]]; then
    echo "Not Enrolled"
    return 0
  fi

  output="$("$jamf_bin" checkJSSConnection 2>/dev/null)"

  server="$(echo "$output" | awk '/Checking availability of/ {for(i=1;i<=NF;i++) if ($i ~ /^https?:\/\//) {gsub(/\.\.\./,"",$i); print $i; exit}}')"

  if echo "$output" | grep -q "The JSS is available"; then
    availability="Available"
  else
    availability="Unavailable"
  fi

  server="$(echo "$server" | sed 's|^https\?://||; s|/$||')"
  [[ -n "$server" ]] && echo "$server ($availability)" || echo "Unknown ($availability)"
}

get_logged_in_user() {
  local u
  u="$(scutil <<< "show State:/Users/ConsoleUser" | awk -F': ' '/Name/ {print $2; exit}')"
  [[ "$u" == "loginwindow" || -z "$u" ]] && u="$(stat -f%Su /dev/console 2>/dev/null)"
  echo "$u"
}

get_computer_name() {
  scutil --get ComputerName 2>/dev/null || hostname
}

md_escape() {
  # Minimal escape so tables don’t break if values include pipes.
  # Also strips carriage returns and collapses newlines to spaces.
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  s="${s//|/\\|}"
  echo "$s"
}

# ---------- Gather values ----------

COMPUTER_NAME="$(get_computer_name)"
USERNAME="$(get_logged_in_user)"
SERIAL="$(get_serial)"
OSINFO="$(get_os)"
MODEL="$(get_model_marketing)"
UPTIME="$(get_uptime_dhm)"
IPINFO="$(get_ip_summary)"
JAMF_SERVER="$(get_jamf_server_status)"
JAMF_LAST_OK="$(get_last_successful_policy_checkin)"

# Escaped for markdown table safety
COMPUTER_NAME_MD="$(md_escape "$COMPUTER_NAME")"
USERNAME_MD="$(md_escape "$USERNAME")"
SERIAL_MD="$(md_escape "$SERIAL")"
MODEL_MD="$(md_escape "$MODEL")"
OSINFO_MD="$(md_escape "$OSINFO")"
UPTIME_MD="$(md_escape "$UPTIME")"
IPINFO_MD="$(md_escape "$IPINFO")"
JAMF_SERVER_MD="$(md_escape "$JAMF_SERVER")"
JAMF_LAST_OK_MD="$(md_escape "$JAMF_LAST_OK")"

INFO_BLOCK=$(
cat <<EOF
==============================
 System Info for Help Desk
==============================
Computer Name: $COMPUTER_NAME
Username:      $USERNAME
Serial:        $SERIAL
Model:         $MODEL
OS:            $OSINFO
Uptime:        $UPTIME
IP:            $IPINFO

Jamf Server:   $JAMF_SERVER
Last Successful Policy Check:
$JAMF_LAST_OK
==============================
EOF
)

MESSAGE_MD=$(
cat <<EOF
### System Info

| Item | Value |
|------|-------|
| **Computer Name** | $COMPUTER_NAME_MD |
| **Username** | $USERNAME_MD |
| **Serial** | $SERIAL_MD |
| **Model** | $MODEL_MD |
| **OS** | $OSINFO_MD |
| **Uptime** | $UPTIME_MD |
| **IP** | $IPINFO_MD |
| **Jamf** | $JAMF_SERVER_MD |

**Last Successful Policy Check**  
\`\`\`
$JAMF_LAST_OK_MD
\`\`\`

Click **Copy** to copy the full block for your help desk ticket.
EOF
)

# ---------- Dialog ----------

if [[ ! -x "$DIALOG" ]]; then
  echo "$INFO_BLOCK"
  exit 0
fi

"$DIALOG" \
  --title "$TITLE" \
  --icon "$ICON" \
  --message "$MESSAGE_MD" \
  --button1text "Copy" \
  --button2text "Close" \
  --ontop \
  --width 900 \
  --height 620

rc=$?

if [[ "$rc" -eq 0 ]]; then
  printf "%s" "$INFO_BLOCK" | pbcopy
  "$DIALOG" \
    --title "$TITLE" \
    --icon "$ICON" \
    --message "Copied to clipboard ✅\n\nPaste it into your help desk ticket." \
    --button1text "OK" \
    --mini \
    --ontop
fi

exit 0
