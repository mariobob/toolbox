# Ensure blueutil is installed
if ! command -v <blueutil_folder>/blueutil &> /dev/null; then
    print "blueutil not found. Please install via: brew install blueutil"
    exit 1
fi

# Define devices as an associative array
typeset -A devices
devices=(
    keyboard "3c-a6-f6-f1-4a-2d"
    trackpad "3c-a6-f6-bf-6c-23"
)

# Path to blueutil command
BLUEUTIL="<blueutil_folder>/blueutil"

# Function to handle device connection
handle_device() {
    local device_name=$1
    local device_id=$2
    
    print "Processing ${device_name} ${device_id}"
    
    # Check connection status 
    local connection_state=$($BLUEUTIL --is-connected $device_id)
    print "Connection status: ${connection_state}"
    
    # Always unpair first
    $BLUEUTIL --unpair $device_id
    
    # If device was not connected, reconnect it
    if [[ $connection_state != "1" ]]; then
        print "Device not connected, reconnecting."
        sleep 1
        $BLUEUTIL --pair $device_id
        sleep 1
        $BLUEUTIL --connect $device_id
    else
        print "Device was connected, disconnection complete"
    fi
}

# Process each device
for key device in ${(kv)devices}; do
    handle_device $key $device
    print "---"
done

# Show notification when complete
osascript -e 'display notification "Bluetooth devices reset complete" with title "Bluetooth Reset"'
print "Done"
