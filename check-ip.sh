#!/bin/bash

# Path to the file where the last known IP address will be stored
IP_FILE="/tmp/last_ip_address"

# Function to fetch the current public IP address
fetch_current_ip() {
    echo $(curl -s ipinfo.io/ip)
}

# Initialize the IP address storage with the current IP if the file doesn't exist or is empty
if [ ! -f "$IP_FILE" ] || [ ! -s "$IP_FILE" ]; then
    echo "Fetching IP address for the first time..."
    CURRENT_IP=$(fetch_current_ip)
    if [ -z "$CURRENT_IP" ]; then
        echo "Failed to retrieve initial IP address. Exiting."
        exit 1
    else
        echo "IP address is $CURRENT_IP, detected at $(date '+%Y-%m-%d %H:%M:%S')."
        echo "$CURRENT_IP" > "$IP_FILE"
    fi
    exit -1
fi

while true; do
    # Fetch the current public IP address
    CURRENT_IP=$(fetch_current_ip)
    if [ -z "$CURRENT_IP" ]; then
        echo "Failed to retrieve IP address. Sleeping 10 seconds..."
        sleep 10
    else
        # Read the last known IP address
        LAST_IP=$(cat "$IP_FILE")
        
        # Compare the current IP address with the last known IP address
        if [ "$CURRENT_IP" != "$LAST_IP" ]; then
            # IP has changed, print the change with timestamp
            echo "IP address has changed from $LAST_IP to $CURRENT_IP, detected at $(date '+%Y-%m-%d %H:%M:%S')."
            # Update the last known IP address
            echo "$CURRENT_IP" > "$IP_FILE"
            exit -1
        fi
    fi
    
    # If current time is between specified time, check the IP address every minute
    CURRENT_HOUR=$(date +'%H')
    if [ "$CURRENT_HOUR" -ge 4 ] && [ "$CURRENT_HOUR" -lt 5 ]; then
        sleep 60
    else
        break
    fi
done

