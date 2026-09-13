#!/bin/bash

#exit if the current user isnt root
if [[ $(whoami) != "root" ]]; then
  echo "The script must be run as root!"
  exit 1
fi

#get the user info
USER="pengmania"
USER_ID=$(id -u $USER)

#get the wireplumber and niri config
WIREPLUMBER="/home/$USER/.config/wireplumber/wireplumber.conf.d/51-disable-hdmi-devices.conf"
NIRI="/home/$USER/.config/niri/config.kdl"

#get the user's runtime session
XDG_RUNTIME_DIR="/run/user/$USER_ID"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus"


run_as_user() {
  #temporary become the user to run a command (Claude wrote this)
  su - "$USER" -c "
    export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS
    $1
  "
}



#get the PCI IDs for the GPU and audio devices
gpu="0000:01:00.0"
aud="0000:01:00.1"

# clear the override so the kernel picks the normal driver again on next probe
echo "" > /sys/bus/pci/devices/$gpu/driver_override
echo "" > /sys/bus/pci/devices/$aud/driver_override

# unbind from vfio-pci
echo $gpu > /sys/bus/pci/devices/$gpu/driver/unbind
echo $aud > /sys/bus/pci/devices/$aud/driver/unbind

# let the kernel re-probe and match against nvidia / snd_hda_intel
echo $gpu > /sys/bus/pci/drivers_probe
echo $aud > /sys/bus/pci/drivers_probe


#enable the nvidia powerd daemon
systemctl start nvidia-powerd

#enable wireplumber from using the GPU
sed -i "s/device.disabled = true/device.disabled = false/" $WIREPLUMBER

# restart wireplumber
run_as_user "systemctl --user restart wireplumber"

#disable niri from using the GPU (and startup apps)
sed -i 's|^include "no_gpu.kdl"|//include "no_gpu.kdl"|' $NIRI
sed -i 's|^//include "startup.kdl"|include "startup.kdl"|' $NIRI

#temporary become the user to restart niri
#run_as_user "systemctl --user restart niri"
