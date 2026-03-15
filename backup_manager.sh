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
# Step 1: Ask user which config to run
# ------------------------------
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
echo "Using configuration: $CONFIG_FILE"

# ------------------------------
# Step 2: Load config safely
# ------------------------------
source "$CONFIG_FILE"

# ------------------------------
# Step 3: Validate at least one path exists
# ------------------------------
if [ -z "$SOURCE" ] && [ -z "$ARCHIVE_FOLDER" ]; then
    echo "Error: Both SOURCE and ARCHIVE_FOLDER are empty. Nothing to do!"
    exit 1
fi

# If SOURCE is defined, check it exists
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
# Step 4: Rsync incremental backup if SOURCE is set
# ------------------------------
if [ -n "$SOURCE" ]; then
    if [ -z "$BACKUP_FOLDER" ]; then
        echo "Warning: BACKUP_FOLDER not set — skipping incremental backup."
    else
        mkdir -p "$BACKUP_FOLDER" || { echo "Error: Could not create BACKUP_FOLDER!"; exit 1; }
        echo "Running incremental backup with rsync..."
        if ! rsync -av --progress "$SOURCE/" "$BACKUP_FOLDER/"; then
            echo "Error: Rsync failed!"
            exit 1
        fi
    fi
else
    echo "SOURCE not set — skipping incremental backup."
fi

# ------------------------------
# Step 5: Archive if ARCHIVE_FOLDER is set
# ------------------------------
if [ -n "$ARCHIVE_FOLDER" ]; then
    mkdir -p "$ARCHIVE_FOLDER" || { echo "Error: Could not create ARCHIVE_FOLDER!"; exit 1; }
    TIMESTAMP=$(date +%F)

    # If SOURCE is set and BACKUP_FOLDER exists, archive that; otherwise archive SOURCE directly
    if [ -n "$SOURCE" ] && [ -n "$BACKUP_FOLDER" ]; then
        ARCHIVE_NAME="$(basename "$SOURCE")_$TIMESTAMP.tar.gz"
        echo "Compressing backup folder '$BACKUP_FOLDER' into $ARCHIVE_NAME..."
        if ! tar -czvf "$ARCHIVE_FOLDER/$ARCHIVE_NAME" -C "$BACKUP_FOLDER" .; then
            echo "Error: Failed to create archive from backup folder!"
            exit 1
        fi
    else
        ARCHIVE_NAME="Archive_$(date +%F).tar.gz"
        echo "Compressing source folder '$SOURCE' directly into $ARCHIVE_NAME..."
        if ! tar -czvf "$ARCHIVE_FOLDER/$ARCHIVE_NAME" -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")"; then
            echo "Error: Failed to create archive from source folder!"
            exit 1
        fi
    fi
else
    echo "ARCHIVE_FOLDER not set — skipping archive step."
fi

echo "Backup process completed successfully!"
