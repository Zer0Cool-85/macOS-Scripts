#!/bin/bash

# ----------------------------
# System Info dialog prompt
# ----------------------------

get_logged_in_user() {
  local u
  u="$(scutil <<< "show State:/Users/ConsoleUser" | awk -F': ' '/Name/ {print $2; exit}')"
  [[ "$u" == "loginwindow" || -z "$u" ]] && u="$(stat -f%Su /dev/console 2>/dev/null)"
  echo "$u"
}

get_computer_name() {
  scutil --get ComputerName 2>/dev/null || hostname
}

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
  # clearing variables
  MARKETING_MODEL="" 
  LOGGEDINUSER=""
  HOME_DIR=""

  # logged in user
  LOGGEDINUSER=$(stat -f '%Su' /dev/console)

  # logged in user home directory
  HOME_DIR=$(dscl /Local/Default read /Users/"$LOGGEDINUSER" NFSHomeDirectory | sed 's/NFSHomeDirectory://' | xargs)

      # get model name if Apple Silicon
      if [ "$(/usr/bin/uname -m)" = 'arm64' ]; then
          MARKETING_MODEL=$(/usr/libexec/PlistBuddy -c 'print 0:product-name' /dev/stdin <<< "$(/usr/sbin/ioreg -ar -k product-name)")

      # if the machine is not Apple Silicon, we need to quickly open the System Information app as the logged in user and extract the information
      elif [ "$(/usr/bin/uname -m)" != 'arm64' ]; then
          if ! [ -e "$HOME_DIR"/Library/Preferences/com.apple.SystemProfiler.plist ]; then
              su "$LOGGEDINUSER" -l -c 'killall cfprefsd'
              sleep 2
              su "$LOGGEDINUSER" -l -c '/usr/bin/open "/System/Library/CoreServices/Applications/About This Mac.app"'
              sleep 2
            /usr/bin/pkill -ail 'System Information'
            sleep 1
          fi
          MARKETING_MODEL=$(defaults read "$HOME_DIR"/Library/Preferences/com.apple.SystemProfiler.plist "CPU Names" | awk -F= '{print $2}' | sed 's|[",;]||g' | sed 's/^[\t ]*//g' | sed '/^[[:space:]]*$/d')
      fi

      if [ "$MARKETING_MODEL" != "" ]; then
        echo "$MARKETING_MODEL"
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

get_jamf_status() {
  local jamf_bin="/usr/local/bin/jamf"
  local enrolled="Unknown"
  local server="Unknown"
  local availability="Unknown"
  local output

  if [[ -x "$jamf_bin" ]]; then
    enrolled="Yes"

    # "jamf checkJSSConnection" prints connection info
    output="$("$jamf_bin" checkJSSConnection 2>/dev/null)"

    # Extract server URL
    server="$(echo "$output" \
      | awk -F' ' '/Checking availability of/ {gsub(/\.\.\./,"",$NF); print $NF; exit}')"

    # Determine availability
    if echo "$output" | grep -q "The JSS is available"; then
      availability="Available"
    else
      availability="Unavailable"
    fi
    server="$(echo "$server" | sed 's|^https://||; s|/$||')"
    [[ -n "$server" ]] && server="$server ($availability)"

  else
    enrolled="No (jamf binary not found)"
    server="N/A"
  fi

  printf "Jamf Server: %s" "$server"
}

get_jamf_checkin() {
  local availability="Unknown"
  local last_checkin="Unknown"
  local last_invUpdate="Unknown"

    # Last check-in and inventory is usually present in jamf.log
    # Scrape log for the most recent time stamps of these actions
    if [[ -f /var/log/jamf.log ]]; then
      last_checkin="$(grep -E "recurring check-in" /var/log/jamf.log 2>/dev/null | tail -n 1 | awk '{print $1, $2, $3, $4}')"
      [[ -z "$last_checkin" ]] && last_checkin="Unknown"
    else
      last_checkin="Unknown"
    fi
    if [[ -f /var/log/jamf.log ]]; then
      last_invUpdate="$(grep -E "Update Inventory" /var/log/jamf.log 2>/dev/null | tail -n 1 | awk '{print $1, $2, $3, $4}')"
      [[ -z "$last_invUpdate" ]] && last_invUpdate="Unknown"
    else
      last_invUpdate="Unknown"
    fi

  printf "Last Check-in: %s\nLast Inventory: %s" "$last_checkin" "$last_invUpdate"
}

# Create variables
COMPUTER_NAME="$(get_computer_name)"
USERNAME="$(get_logged_in_user)"
SERIAL="$(get_serial)"
OSINFO="$(get_os)"
MODEL="$(get_model_marketing)"
UPTIME="$(get_uptime_dhm)"
IPINFO=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | grep -v '192.*' | awk '{print $2}')
JAMFINFO="$(get_jamf_status)"
JAMFINFO2="$(get_jamf_checkin)"
SERVER="$(get_jamf_status | grep "Jamf Server:" | awk '{print $3}')"
LAST_CHECKIN="$(get_jamf_checkin | grep "Last Check-in:" | awk '{print $3, $4, $5, $6}')"
LAST_INVUPDATE="$(get_jamf_checkin | grep "Last Inventory:" | awk '{print $3, $4, $5, $6}')"

# Generate variable for use when copying the information from the dialog prompt
INFO_BLOCK=$(
cat <<EOF
------------------------------
         System Info 
------------------------------
Computer Name: $COMPUTER_NAME
Username: $USERNAME
Serial: $SERIAL
Model: $MODEL
OS: $OSINFO
Uptime: $UPTIME
IP: $IPINFO

------------------------------
        Jamf Status
------------------------------
$JAMFINFO
$JAMFINFO2
EOF
)

# ---------- SwiftDialog popup ----------

# Dialog variables
DIALOG="/usr/local/bin/dialog"
ICON="SF=laptopcomputer.and.arrow.down,weight=semibold"

# Create message content for dialog window using markdown format with tables
MESSAGE=$(
cat <<EOF
## System Info
|  |  |
|------|-------|
| **Computer Name** | $COMPUTER_NAME |
| **Username** | $USERNAME |
| **Serial** | $SERIAL |
| **Model** | $MODEL |
| **OS** | $OSINFO |
| **Uptime** | $UPTIME |
| **IP Address** | $IPINFO |
<br><br>
## Jamf Information
|  |  |
|------|-------|
| **Jamf Server** | $SERVER |
| **Last Check-in** | $LAST_CHECKIN |
| **Last Inventory** | $LAST_INVUPDATE |
<br><br>
>Click **Copy** to copy all information to your clipboard.
EOF
)

# If dialog is missing, just print to stdout
if [[ ! -x "$DIALOG" ]]; then
  echo "$INFO_BLOCK"
  exit 0
fi

# Show dialog with a Copy button
"$DIALOG" \
  --title "" \
  --icon "$ICON" \
  --message "$MESSAGE" \
  --button1text "Copy" \
  --button2text "Close" \
  --ontop \
  --width 820 \
  --height 650
rc=$?

# If user clicked "Copy" (button 1), copy the block to clipboard and present another popup
if [[ "$rc" -eq 0 ]]; then
  printf "%s" "$INFO_BLOCK" | pbcopy
  "$DIALOG" \
    --title "$TITLE" \
    --message "Copied system information to clipboard ✅\n\nPaste info into your ticket or chat with support." \
    --icon "$ICON" \
    --button1text "OK" \
    --mini \
    --ontop
fi

exit 0
