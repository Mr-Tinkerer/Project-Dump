#!/bin/bash

#get the borg directory
REPO="/mnt/OMV/PC_Backups"

#get the name of the current archive
ARCHIVE_NAME=$(date +%m-%d-%Y__%H-%M-%S)

#the maxinium amount of backups to keep before it start to delete the older ones.
MAX_BACKUPS=10

#stop if the borg repo doesn't exist
if [[ ! -e $REPO/data ]]; then
    notify-send "Auto Borg Backup Error" "the Borg repo path is invalid. Make it first before running this script"
    exit 1
fi

#get the file that's storing the borg secret
SECRET_FILE="./BORG_SECRET"

#check if the file exists
if [[ -e $SECRET_FILE ]]; then
    #check if the file is readable, and has content inside it
    if [[ -r $SECRET_FILE ]] && [[ -s $SECRET_FILE ]]; then
        #get the password and set it to 400 for security
        export BORG_PASSPHRASE=$(cat $SECRET_FILE)
        chmod 400 $SECRET_FILE
    else
        #notify the file error
        notify-send "Auto Borg Backup Error" "The $SECRET_FILE needs to be readable, and have the password inside it."
        exit 1
    fi
else
    #notify the missing file error
    notify-send "Auto Borg Backup Error" "The $SECRET_FILE file needs to exist in order for the script to work."
    exit 1
fi

#the borg file that will be used to store the stats of the backup 
BORG_FILE=borg_results.txt

#start the borg backup while ignoring the cache, games, and the trash directory.
#also redirect the output to a file for parsing. 
notify-send "Starting Auto Borg Backup..."
(borg create \
    -e "$HOME/.cache" \
    -e "$HOME/.local/share/Steam/steamapps" \
    -e "$HOME/.steam" \
    -e "$HOME/Games" \
    -e "$HOME/.local/share/Trash/" \
    -e "$HOME/Projects/VMs/ISOs" \
    "$REPO::$ARCHIVE_NAME" \
    "$HOME" \
    "$HOME/Projects/VMs" \
    --stats 2>&1) | tee $BORG_FILE

#get the stats from the borg backup file and delete it
DURATION=$(grep "Duration" $BORG_FILE | awk -F ' ' '{print $2, $3}')
CURRENT_STORAGE=$(grep "This archive" $BORG_FILE | awk -F ' ' '{print $7, $8}')
TOTAL_STORAGE=$(grep "All archives" $BORG_FILE | awk -F ' ' '{print $7, $8}')
rm $BORG_FILE

#notify that it's done with stats
notify-send "Auto Borg Backup Done in $DURATION." "This borg backup has taken up $CURRENT_STORAGE out of $TOTAL_STORAGE."

#check if there is more backups then the maxinium
BACKUPS=$(borg list $REPO | wc -l)
if [[ $BACKUPS -gt $MAX_BACKUPS ]]; then 
    #notify about the backups higher then the max
    notify-send "Auto Borg Backup Prune." "There is currently $BACKUPS out of $MAX_BACKUPS maxinium allowed. Going to delete the old one to make space."
    
    #delete the older backups to make the backups under the max
    borg prune --verbose --keep-last $MAX_BACKUPS $REPO

    #get the new size of the borg repo 
    SIZE=$(du -sh $REPO | awk -F ' ' '{print $1}')

    #notify that it's done, and say the new size.
    notify-send "Auto Borg Backup Prune Done." "Sucessfully prune the old backups. The repo is now $SIZE."
fi

