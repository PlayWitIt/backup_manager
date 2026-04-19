# BuM - Backup Manager

**Author:** PlayWit Creations
**Date:** 2026-04-19

---

## Overview

**BuM (Backup Manager)** is a modern Textual-based TUI application for managing folder backups with an intuitive interface. It performs incremental backups using `rsync` and creates timestamped `.tar.gz` archives for long-term storage.

---

## Features

* **Interactive TUI** - Beautiful Textual-based interface with keyboard navigation
* **Multiple Jobs** - Create and manage multiple backup jobs with individual configurations
* **Incremental Backups** - Uses rsync to copy only changed files
* **Archived Snapshots** - Creates compressed `.tar.gz` archives with timestamps
* **Progress Tracking** - Real-time progress indicators showing files synced/archived
* **Interrupt Recovery** - Detects interrupted backups and cleans up gracefully
* **Persistent Status** - Job status and last run time saved across sessions
* **Flexible Scheduling** - Manual or scheduled backups (e.g., 12h, 1d, 30m)
* **Directory Browser** - Built-in file/folder picker with create folder support

---

## Installation

```bash
pip install -e .
```

Or run directly:
```bash
python -m backup_manager
bum
```

---

## Usage

1. Launch the application: `bum`
2. Click **"New Backup Job"** or press the button
3. Fill in:
   - **Job Name** - Friendly name for the job
   - **Source Folder** - Folder to back up
   - **Backup Folder** - Where to store incremental backups
   - **Archive Folder** - Where to store compressed archives
   - **Schedule** - `manual` or interval (e.g., `12h`, `1d`, `30m`)
4. Click **Save**
5. Select a job and click **Run Now** to start backup

### Keyboard Shortcuts

- **Arrow Keys** - Navigate between jobs in the table
- **Enter** - Confirm selection in directory picker
- **Escape** - Cancel/close dialogs
- **Backspace** - Go up one directory level
- **N** - Focus new folder input in directory picker

---

## Configuration

Jobs are stored as `.ini` files in `~/.config/BackupManagerTUI/`

Example config structure:
```ini
[backup]
name = My Website
source = /home/user/website
backup_folder = /home/user/backups/website
archive_folder = /home/user/archives/website
last_run = 2026-04-19 14:30
status = ✅ Success

[schedule]
interval = manual
```

---

## Architecture

- **Textual TUI** - Rich terminal user interface
- **rsync** - Incremental file synchronization
- **tar** - Archive compression
- **configparser** - Job configuration storage

---

## License

* Free to use and modify.
* Created by **PlayWit Creations**.