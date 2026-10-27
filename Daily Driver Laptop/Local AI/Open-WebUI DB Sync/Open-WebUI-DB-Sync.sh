#!/bin/bash

#make it stop on any failure
set -e

#test if there is a connection to the VM.
AI_VM_IP=10.10.0.5
AI_VM_SSH_NAME=AI-Local
AI_VM_CONNECTION=$(ping $AI_VM_IP -c 1 | grep " 0% packet loss")
OPEN_WEBUI_PATH="/home/pengmania/LLMs/open-webui"

#stop if it didnt get any connection msg
if [[ -z $AI_VM_CONNECTION ]]; then
    echo "Error, there is no connection to the AI VM Machine ($AI_VM_IP)."
    exit 1
fi

#create a current backup of the open-webui db
cd $OPEN_WEBUI_PATH
sqlite3 webui.db ".backup snapshot.db"
echo "Created the bcakup of the local database"

#stop the service on the remote machine, and delete the old databases
ssh $AI_VM_SSH_NAME "systemctl --user stop open-webui"
ssh $AI_VM_SSH_NAME "rm -f ~/open-webui/*.db*"
echo "Stopped the service, and deleted the old files"

#copy the database over, and start the service
scp snapshot.db $AI_VM_SSH_NAME:~/open-webui/webui.db
ssh $AI_VM_SSH_NAME "systemctl --user start open-webui"
echo "Migrated the DB over, and started the service"
