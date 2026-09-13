#!/bin/bash

#exit if the current user isnt root
if [[ $(whoami) != "root" ]]; then
  echo "The script must be run as root!"
  exit 1
fi

#store the GPU and audio PCI IDs and vender info
gpu="0000:01:00.0"
aud="0000:01:00.1"
gpu_vd="$(cat /sys/bus/pci/devices/$gpu/vendor) $(cat /sys/bus/pci/devices/$gpu/device)"
aud_vd="$(cat /sys/bus/pci/devices/$aud/vendor) $(cat /sys/bus/pci/devices/$aud/device)"

function show_GPU_status {
  #clean up the vender IDs
  gpu_id=$(echo $gpu_vd | sed "s/0x//g" | sed "s/ /:/g")
  aud_id=$(echo $aud_vd | sed "s/0x//g" | sed "s/ /:/g")
  
  #show the current status of the GPU and the audio devices
  lspci -nnk -d $gpu_id
  echo "-----------------------------"
  lspci -nnk -d $aud_id
}

function bind_vfio {
  #unbind the GPU & audio drivers
  echo "Going to unbind the GPU & audio's drivers."
  echo "$gpu" > "/sys/bus/pci/devices/$gpu/driver/unbind"
  echo "$aud" > "/sys/bus/pci/devices/$aud/driver/unbind"

  #bind the GPU & audio to PCI
  echo "Going to bind the GPU & audio's drivers to VFIO."
  echo "$gpu_vd" > /sys/bus/pci/drivers/vfio-pci/new_id
  echo "$aud_vd" > /sys/bus/pci/drivers/vfio-pci/new_id

  # echo $gpu > /sys/bus/pci/devices/$gpu/driver/unbind
  # echo $aud > /sys/bus/pci/devices/$aud/driver/unbind

  # echo $gpu > /sys/bus/pci/drivers/vfio-pci/bind
  # echo $aud > /sys/bus/pci/drivers/vfio-pci/bind
  
  #show the final result of the GPU
  show_GPU_status
}

function unbind_vfio {
  #remove the GPU and audio devices from VFIO
  echo "Going to unbind the GPU & audio's VFIO drivers."
  echo "$gpu_vd" > "/sys/bus/pci/drivers/vfio-pci/remove_id"
  echo "$aud_vd" > "/sys/bus/pci/drivers/vfio-pci/remove_id"

  #remove the devices from the system, and make the kernel rescan for them
  echo "Removing the GPU and auidio from the system, and reimporting them."
  echo 1 > "/sys/bus/pci/devices/$gpu/remove"
  echo 1 > "/sys/bus/pci/devices/$aud/remove"
  echo 1 > "/sys/bus/pci/rescan"

  # echo $gpu > /sys/bus/pci/devices/$gpu/driver/unbind
  # echo $aud > /sys/bus/pci/devices/$aud/driver/unbind

  # echo $gpu > /sys/bus/pci/drivers/nvidia/bind
  # echo $aud > /sys/bus/pci/drivers/snd_hda_intel/bind
  
  #show the final result of the GPU
  show_GPU_status
}



#check if the function argument is being used
if [[ -n $1 ]]; then
  #check what user function passed
    case $1 in
      #Bind the VFIO drivers
      "bind_vfio")
        bind_vfio
      ;;

      #Unbind the VFIO drivers
      "unbind_vfio")
        unbind_vfio
      ;;

      #invalid user flag passed.
      *)
        echo "Wrong user flag passed."
    esac
else 
  #list the user options
  echo "Do you want to bind or unbind the VFIO drivers?"
  echo "1) Bind"
  echo "2) Unbind"
  echo "3) Show current GPU status"
  echo "4) Exit"

  #infinite loop to get the correct user input
  while :; do
    read -p "Enter in your option here: " choice

    #check what option the user choose
    case $choice in
      #Bind the VFIO drivers, and exit
      1)
        bind_vfio
        exit 0
      ;;

      #Unbind the VFIO drivers, and exit
      2)
        unbind_vfio
        exit 0
      ;;

      #show the GPU status
      3)
        show_GPU_status
      ;;

      #exit
      4)
        echo "Exiting..."
        exit 0
      ;;

      #invalid user option
      *)
        echo "Wrong option try again."
    esac  
  done
fi