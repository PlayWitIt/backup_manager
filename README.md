# Universal Backup Manager
**Author:** PlayWit Creations  
**Date:** 2026-03-15

---

## Overview

The **Universal Backup Manager** is a shell script system that allows you to perform **incremental backups** of any folder and compress them into timestamped archives.  
It supports **multiple backup tasks** through individual configuration files.

---

## Features

- Incremental backup using `rsync` (copies only changed or new files).  
- Timestamped `.tar.gz` compressed archives for long-term storage.  
- Supports multiple configuration files for different backup tasks.  
- Automatic creation of backup and archive directories.  
- Interactive selection of which backup task to run.

---

## Folder Structure

```
backup_manager/
├─ backup_manager.sh        # Main backup script
├─ configs/                 # Folder for all .conf configuration files
│  ├─ example.conf          # Template configuration
│  ├─ obsidian.conf         # Your Obsidian backup task
│  ├─ documents.conf        # Example documents backup
└─ README.md                # This file
```

---

## How to Use

1. **Create configuration files**  
   - Copy `example.conf` and rename it for your task, e.g., `obsidian.conf`.  
   - Edit the `SOURCE`, `BACKUP_FOLDER`, and `ARCHIVE_FOLDER` paths to match your system.

2. **Run the backup manager script**  

```bash
chmod +x backup_manager.sh
./backup_manager.sh
```

3. **Select a configuration**  
   - If multiple `.conf` files exist, you’ll see a numbered list.  
   - Enter the number of the backup task you want to run.

4. **Confirm paths**  
   - The script will display source, backup, and archive folders.  
   - Type `y` to continue or `n` to cancel.

5. **Rsync and compress**  
   - The script runs `rsync` to copy changed files.  
   - Creates a timestamped `.tar.gz` in the archive folder.

---

## Configuration File Example

```bash
# obsidian.conf
SOURCE="/run/media/play/Seagate\\x20Portable\\x20Drive/Obsidian"
BACKUP_FOLDER="/run/media/play/Seagate\\x20Portable\\x20Drive/Backups/Obsidian Backups"
ARCHIVE_FOLDER="/run/media/play/Seagate\\x20Portable\\x20Drive/Backups/Obsidian Archives"
```

> Paths must be quoted and escaped properly if they contain spaces (`\ ` or `\\x20`).

---

## Notes

- Linux paths are **case-sensitive**.  
- Rsync may warn about files that disappear during transfer — this is normal for live folders like Obsidian.  
- The script only compresses the incremental backup folder. If you want full compression of original source, adjust the `ARCHIVE_FOLDER` path.  
- You can create **multiple `.conf` files** for different tasks — the script will let you choose interactively.

---

## License

- Free to use and modify.  
- Created by **PlayWit Creations**.

