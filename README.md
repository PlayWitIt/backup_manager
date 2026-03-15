
# Universal Backup Manager

**Author:** PlayWit Creations
**Date:** 2026-03-15

---

## Overview

The **Universal Backup Manager** is a shell script system that allows you to perform **incremental backups** of any folder and/or **compress them into timestamped archives**.
It supports **multiple backup tasks** through individual configuration files and can handle optional rsync backups and/or optional archiving depending on your configuration.

---

## Features

* Incremental backup using `rsync` (copies only changed or new files).
* Timestamped `.tar.gz` compressed archives for long-term storage.
* Supports multiple configuration files for different backup tasks.
* Automatic creation of backup and archive directories.
* Interactive selection of which backup task to run.
* Handles optional paths: you can do **backup-only**, **archive-only**, or **both**.
* Gracefully handles invalid or missing paths with clear error messages.

---

## Folder Structure

```
backup_manager/
├─ backup_manager.sh        # Main backup script
├─ configs/                 # Folder for all .conf configuration files
│  ├─ example.conf          # Template configuration
│  ├─ documents.conf        # Example documents backup
│  ├─ pictures.conf         # Example pictures backup
└─ README.md                # This file
```

---

## How to Use

1. **Create configuration files**

   * Copy `example.conf` and rename it for your task, e.g., `documents.conf`.
   * Edit the `SOURCE`, `BACKUP_FOLDER`, and `ARCHIVE_FOLDER` paths to match your system.
   * You can leave `BACKUP_FOLDER` empty if you only want to archive, or leave `ARCHIVE_FOLDER` empty if you only want an incremental rsync backup.

2. **Run the backup manager script**

```bash
chmod +x backup_manager.sh
./backup_manager.sh
```

3. **Select a configuration**

   * If multiple `.conf` files exist, you’ll see a numbered list.
   * Enter the number of the backup task you want to run.

4. **Confirm paths**

   * The script will display source, backup, and archive folders.
   * Type `y` to continue or `n` to cancel.

5. **Backup / Archive Execution**

   * **Incremental rsync backup:** If `SOURCE` and `BACKUP_FOLDER` are set, the script performs an incremental backup.
   * **Archive:** If `ARCHIVE_FOLDER` is set, the script compresses either the backup folder (if backup exists) or the source folder directly.
   * Clear messages are shown for skipped steps if optional paths are not set.

---

## Configuration File Example

```bash
# example.conf
SOURCE="/home/user/source_folder"
BACKUP_FOLDER="/home/user/incremental_backup"
ARCHIVE_FOLDER="/home/user/archive_folder"
```

> Notes:
>
> * Paths must be quoted.
> * Leave `BACKUP_FOLDER` empty to skip incremental backup.
> * Leave `ARCHIVE_FOLDER` empty to skip compression.

---

## Notes

* Linux paths are **case-sensitive**.
* Rsync may warn about files that disappear during transfer — this is normal for live folders.
* You can create **multiple `.conf` files** for different tasks — the script will let you choose interactively.
* The script now **supports flexible backups**: backup-only, archive-only, or both, depending on your configuration.

---

## License

* Free to use and modify.
* Created by **PlayWit Creations**.
