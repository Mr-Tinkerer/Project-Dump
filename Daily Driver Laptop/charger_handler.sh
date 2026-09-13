#!/bin/bash

# Ensure the script is run at the user level (not as root)
if [ "$EUID" -eq 0 ]; then
    echo "Error: This script must be run at the user level, not as root." >&2
    exit 1
fi

plugged_actions () {
    echo "Charger plugged in. Applying performance settings..."
    # Set power level to performance
    powerprofilesctl set performance

    # Set brightness to 100
    dms brightness set backlight:intel_backlight 100

    # Set display profile to dual
    dms ipc outputs setProfile 'Dual Monitors'
}

unplugged_actions () {
    echo "Charger unplugged. Applying power-saving settings..."

    # Set power level to power saving
    powerprofilesctl set power-saver

    # Set brightness to 50
    dms brightness set backlight:intel_backlight 50

    # Set display profile to single
    dms ipc outputs setProfile 'Single Laptop Mode'
}

# Check initial charger state and run actions once on startup
LINE_POWER_PATH=$(upower -e | grep 'line_power' | head -n 1)
LAST_STATE=""

if [ -n "$LINE_POWER_PATH" ]; then
    IS_ONLINE=$(upower -i "$LINE_POWER_PATH" | grep "online:" | awk '{print $2}')
    LAST_STATE="$IS_ONLINE"

    echo "Initial charger state: online = $IS_ONLINE"
    if [ "$IS_ONLINE" = "yes" ]; then
        plugged_actions
    elif [ "$IS_ONLINE" = "no" ]; then
        unplugged_actions
    fi
fi

echo "Starting advanced charger monitor... Listening for power state changes."

# Monitor power supply events using upower
upower --monitor | while read -r line; do
    if echo "$line" | grep -q "line_power"; then
        LINE_POWER_PATH=$(upower -e | grep 'line_power' | head -n 1)

        if [ -n "$LINE_POWER_PATH" ]; then
            IS_ONLINE=$(upower -i "$LINE_POWER_PATH" | grep "online:" | awk '{print $2}')

            # Only trigger if the state actually changed
            if [ "$IS_ONLINE" != "$LAST_STATE" ]; then
                LAST_STATE="$IS_ONLINE"

                if [ "$IS_ONLINE" = "no" ]; then
                    unplugged_actions

                elif [ "$IS_ONLINE" = "yes" ]; then
                    plugged_actions
                fi
            fi
        fi
    fi
done
