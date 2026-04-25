#!/usr/bin/env bash

# Docs: https://apple.stackexchange.com/questions/399829/best-way-to-switch-magic-keyboard-and-trackpad-between-work-personal-macs
# Run blueutil --paired and identify device address

# Ensure blueutil is installed
if ! command -v blueutil &> /dev/null; then
    echo "Error: blueutil not found. Please install via: brew install blueutil"
    exit 1
fi

# Device names and their corresponding MAC addresses
device_names=(
    "keyboard"
    "trackpad"
)
# Your devices' MAC addresses. Find them with `blueutil --paired`, then either edit the
# placeholders below or export BT_KEYBOARD_MAC / BT_TRACKPAD_MAC in your shell config.
device_macs=(
    "${BT_KEYBOARD_MAC:-aa-bb-cc-dd-ee-01}"
    "${BT_TRACKPAD_MAC:-aa-bb-cc-dd-ee-02}"
)

# Function to handle device connection reset
handle_device() {
    local device_name=$1
    local device_id=$2

    echo "🕒 Processing ${device_name} (${device_id})"

    # Check connection status
    local connection_state
    connection_state=$(blueutil --is-connected "$device_id" 2>/dev/null)
    echo "🔌 Connection status: ${connection_state:-unknown}"

    if [[ "$connection_state" == "1" ]]; then
        echo "✅ $device_name is already connected, skipping"
        return 0
    fi

    echo "🕒 Device not connected, attempting to reconnect..."
    
    # Unpair first
    if ! blueutil --unpair "$device_id"; then
        echo "⚠️ Failed to unpair $device_name"
    fi

    sleep 1
    blueutil --pair "$device_id" || echo "⚠️ Pairing failed for $device_name"
    sleep 1
    blueutil --connect "$device_id" || echo "⚠️ Connection failed for $device_name"

    # Retry loop to confirm connection
    for retry in {1..5}; do
        if [[ $(blueutil --is-connected "$device_id") == "1" ]]; then
            echo "✅ $device_name connected successfully"
            break
        fi
        sleep 1
    done
}

# Validate arrays have matching lengths
if [[ ${#device_names[@]} -ne ${#device_macs[@]} ]]; then
    echo "❌ Error: device_names and device_macs arrays must have the same length"
    exit 1
fi

# Process each device
for ((i=0; i<${#device_names[@]}; i++)); do
    handle_device "${device_names[i]}" "${device_macs[i]}"
    echo "----"
done

# Show notification when complete (only if GUI available)
if pgrep -x "Finder" &>/dev/null; then
    osascript -e 'display notification "Bluetooth devices reset complete" with title "Bluetooth Reset"'
fi

echo "✅ Done. Processed ${#device_names[@]} devices."
