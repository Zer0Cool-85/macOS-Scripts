#!/bin/bash

# ----------------------------
# System Info for Help Desk
# ----------------------------

get_serial() {
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}'
}

get_os() {
  local name ver build
  name="$(sw_vers -productName 2>/dev/null)"
  ver="$(sw_vers -productVersion 2>/dev/null)"
  build="$(sw_vers -buildVersion 2>/dev/null)"
  printf "%s %s (%s)" "$name" "$ver" "$build"
}

get_model_marketing() {
  # Works on macOS 11+; uses Apple’s model database if available
  local model_id marketing
  model_id="$(sysctl -n hw.model 2>/dev/null)"

  marketing="$(/usr/libexec/PlistBuddy -c "Print :$model_id" \
    /System/Library/PrivateFrameworks/DeviceIdentity.framework/Versions/A/Resources/DeviceIdentityModelInfo.plist 2>/dev/null)"

  if [[ -n "$marketing" ]]; then
    printf "%s" "$marketing"
  else
    # Fallback: show model identifier
    printf "%s" "$model_id"
  fi
}

get_uptime_dhm() {
  local boot now diff days hours mins
  boot="$(sysctl -n kern.boottime | awk -F'[ ,}]+' '{print $4}')"  # epoch seconds
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
  # Best-effort: show primary interface + IPv4 (and Wi-Fi name if relevant)
  local primary_if ip4 ssid

  primary_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -n "$primary_if" ]]; then
    ip4="$(ipconfig getifaddr "$primary_if" 2>/dev/null)"
  fi

  # Wi-Fi SSID if on en0 (common) or if airport reports something
  ssid="$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null \
    | awk -F': ' '/ SSID/{print $2; exit}')"

  if [[ -n "$primary_if" && -n "$ip4" ]]; then
    if [[ -n "$ssid" ]]; then
      printf "%s: %s (Wi-Fi: %s)" "$primary_if" "$ip4" "$ssid"
    else
      printf "%s: %s" "$primary_if" "$ip4"
    fi
  else
    # Fallback: list all active IPv4 addresses
    ifconfig 2>/dev/null | awk '
      /^[a-z]/ {iface=$1; sub(":", "", iface)}
      /status: active/ {active[iface]=1}
      /inet / && active[iface]==1 {print iface ": " $2}
    ' | paste -sd ", " -
  fi
}

get_jamf_status() {
  local jamf_bin="/usr/local/bin/jamf"
  local enrolled="Unknown"
  local last_checkin="Unknown"
  local server="Unknown"

  if [[ -x "$jamf_bin" ]]; then
    enrolled="Yes"

    # "jamf checkJSSConnection" prints connection info; keep it light
    server="$("$jamf_bin" checkJSSConnection 2>/dev/null | awk -F': ' '/Checking connection to/{print $2; exit}')"
    [[ -z "$server" ]] && server="Connected (server not parsed)"

    # Last check-in is commonly present in jamf.log
    if [[ -f /var/log/jamf.log ]]; then
      last_checkin="$(grep -E "Checking for policies|Submitting inventory|Contacting JSS" /var/log/jamf.log 2>/dev/null | tail -n 1)"
      [[ -z "$last_checkin" ]] && last_checkin="jamf.log present (no recent entry parsed)"
    else
      last_checkin="jamf.log not found"
    fi
  else
    enrolled="No (jamf binary not found)"
    server="N/A"
    last_checkin="N/A"
  fi

  printf "Enrolled: %s\nJamf Server: %s\nLast Jamf Activity: %s" "$enrolled" "$server" "$last_checkin"
}

SERIAL="$(get_serial)"
OSINFO="$(get_os)"
MODEL="$(get_model_marketing)"
UPTIME="$(get_uptime_dhm)"
IPINFO="$(get_ip_summary)"
JAMFINFO="$(get_jamf_status)"

cat <<EOF
==============================
 System Info for Help Desk
==============================
Serial:      $SERIAL
Model:       $MODEL
OS:          $OSINFO
Uptime:      $UPTIME
IP:          $IPINFO

Jamf Status:
$JAMFINFO
==============================
EOF
