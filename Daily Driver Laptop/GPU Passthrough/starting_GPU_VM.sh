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

get_gpu_processes() {
  #get the list of processes name that's currently using the GPU (Claude wrote this)
  programs=$(lsof +c 0 /dev/nvidia* 2> /dev/null | awk 'NR>1 {print $1}' | sort -u)
  
  #use bash string substitution to format the list to be seperated by ", " (Claude wrote this) 
  programs=$(echo "${programs//$'\n'/, }")
  
  #cleanly remove Niri from the list
  programs=$(echo $programs | sed "s/niri//")
  programs=$(echo $programs | sed "s/ , / /")

  #return the list
  echo $programs
}


#disable the nvidia powerd daemon
systemctl stop nvidia-powerd

#disable wireplumber from using the GPU
sed -i "s/device.disabled = false/device.disabled = true/" $WIREPLUMBER

# restart wireplumber 
run_as_user "systemctl --user restart wireplumber"



#get a list of programs that needed to be killed manually
programs=$(get_gpu_processes)

#the ID to keep track of the current notifcation
id=0

#wait until all of the gpu process stopped
while [[ -n $programs ]]; do
  #notify the user about the programs that is need to be kill. The notfication will stay in place, and self update
  id=$(run_as_user "notify-send -p -t 0 -u critical -r '$id' 'GPU Passthrough Manual Intervention!' 'Kill the following programs for the GPU to work: $programs'")
  
  #sleep a second and update the program list
  sleep 1
  programs=$(get_gpu_processes)
done

#notify the user that everything has been killed, and the script is moving on
run_as_user "notify-send -t 1 -u low -r '$id' 'GPU Passthrough Manual Intervention!' 'All of the programs have been killed. Now moving on.'"




#disable niri from using the GPU (and startup apps)
sed -i 's|^// include "no_gpu.kdl"|include "no_gpu.kdl"|' $NIRI
sed -i 's|^//include "no_gpu.kdl"|include "no_gpu.kdl"|' $NIRI
sed -i 's|^include "startup.kdl"|//include "startup.kdl"|' $NIRI

#temporary become the user to restart niri
run_as_user "systemctl --user restart niri"


#get the PCI IDs for the GPU and audio devices
gpu="0000:01:00.0"
aud="0000:01:00.1"

#tell the GPU and the audio device to only use VFIO
echo vfio-pci > /sys/bus/pci/devices/$gpu/driver_override
echo vfio-pci > /sys/bus/pci/devices/$aud/driver_override

#unbind the driver
echo $gpu > /sys/bus/pci/devices/$gpu/driver/unbind
echo $aud > /sys/bus/pci/devices/$aud/driver/unbind

#tell the devices to look for what drivers to use (told to only use VFIO eariler)
echo $gpu > /sys/bus/pci/drivers_probe
echo $aud > /sys/bus/pci/drivers_probe
