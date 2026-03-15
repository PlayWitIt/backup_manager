#!/bin/bash

CONFIG_DIR="./configs"

# ------------------------------
# Step 0: Find available configs
# ------------------------------
CONF_FILES=("$CONFIG_DIR"/*.conf)

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Config directory '$CONFIG_DIR' does not exist!"
    exit 1
fi

if [ ${#CONF_FILES[@]} -eq 0 ]; then
    echo "Error: No configuration files found in '$CONFIG_DIR'."
    exit 1
fi

# ------------------------------
# Step 1: Determine which config to run
# ------------------------------
if [ ${#CONF_FILES[@]} -eq 1 ]; then
    CONFIG_FILE="${CONF_FILES[0]}"
    echo "Only one configuration found. Using: $(basename "$CONFIG_FILE")"
else
    echo "Available backup configurations:"
    for i in "${!CONF_FILES[@]}"; do
        echo "[$i] $(basename "${CONF_FILES[$i]}")"
    done

    read -p "Select a configuration to run (number): " index
    if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -ge "${#CONF_FILES[@]}" ]; then
        echo "Error: Invalid selection."
        exit 1
    fi

    CONFIG_FILE="${CONF_FILES[$index]}"
    echo "Using configuration: $(basename "$CONFIG_FILE")"
fi

# ------------------------------
# Step 2: Load configuration
# ------------------------------
source "$CONFIG_FILE"

# ------------------------------
# Step 3: Validate paths
# ------------------------------
if [ -z "$SOURCE" ] && [ -z "$ARCHIVE_FOLDER" ]; then
    echo "Error: Both SOURCE and ARCHIVE_FOLDER are empty. Nothing to do!"
    exit 1
fi

if [ -n "$SOURCE" ] && [ ! -d "$SOURCE" ]; then
    echo "Error: SOURCE folder '$SOURCE' does not exist!"
    exit 1
fi

# Confirm with user
echo "Source folder: ${SOURCE:-<not set>}"
echo "Backup folder: ${BACKUP_FOLDER:-<not set>}"
echo "Archive folder: ${ARCHIVE_FOLDER:-<not set>}"
read -p "Proceed with backup? (y/n) " choice
if [[ "$choice" != "y" ]]; then
    echo "Backup cancelled."
    exit 0
fi

# ------------------------------
# Step 4: Rsync incremental backup
# ------------------------------
if [ -n "$SOURCE" ] && [ -n "$BACKUP_FOLDER" ]; then
    mkdir -p "$BACKUP_FOLDER" || { echo "Error: Could not create BACKUP_FOLDER!"; exit 1; }
    echo "Running incremental backup with rsync..."
    rsync -av --progress --exclude='*.tmp' --exclude='*.swp' --exclude='*.DS_Store' --exclude='*.log' --exclude='*.bak' "$SOURCE/" "$BACKUP_FOLDER/"
    RSYNC_EXIT=$?
    if [ $RSYNC_EXIT -eq 0 ] || [ $RSYNC_EXIT -eq 24 ]; then
        echo "Rsync completed (some files may have vanished, see warnings above)."
    else
        echo "Error: Rsync failed with code $RSYNC_EXIT!"
        exit 1
    fi
elif [ -n "$SOURCE" ]; then
    echo "Warning: BACKUP_FOLDER not set — skipping incremental backup."
else
    echo "SOURCE not set — skipping incremental backup."
fi

# ------------------------------
# Step 5: Archive
# ------------------------------
if [ -n "$ARCHIVE_FOLDER" ]; then
    mkdir -p "$ARCHIVE_FOLDER" || { echo "Error: Could not create ARCHIVE_FOLDER!"; exit 1; }
    TIMESTAMP=$(date +%F)

    if [ -n "$SOURCE" ] && [ -n "$BACKUP_FOLDER" ] && [ -d "$BACKUP_FOLDER" ]; then
        ARCHIVE_NAME="$(basename "$SOURCE")_$TIMESTAMP.tar.gz"
        echo "Compressing backup folder '$BACKUP_FOLDER' into $ARCHIVE_NAME..."
        tar -czvf "$ARCHIVE_FOLDER/$ARCHIVE_NAME" -C "$BACKUP_FOLDER" . || { echo "Error: Failed to create archive from backup folder!"; exit 1; }
    elif [ -n "$SOURCE" ] && [ -d "$SOURCE" ]; then
        ARCHIVE_NAME="$(basename "$SOURCE")_$TIMESTAMP.tar.gz"
        echo "Compressing source folder '$SOURCE' directly into $ARCHIVE_NAME..."
        tar -czvf "$ARCHIVE_FOLDER/$ARCHIVE_NAME" -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" || { echo "Error: Failed to create archive from source folder!"; exit 1; }
    else
        echo "Warning: Nothing available to archive. Skipping archive step."
    fi
else
    echo "ARCHIVE_FOLDER not set — skipping archive step."
fi

echo "Backup process completed successfully!"
