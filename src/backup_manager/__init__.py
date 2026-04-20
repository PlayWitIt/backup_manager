import os
import sys
import subprocess
import shutil
import configparser
import time
import re
import logging
from datetime import datetime, timedelta
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Dependency to find the correct user config directory on any OS
import platformdirs

from textual.app import App, ComposeResult
from textual.containers import Container, VerticalScroll, Vertical, Grid, Horizontal
from textual.screen import ModalScreen
from textual.widgets import (
    Header, Footer, DataTable, Button, Log, TabbedContent, TabPane, Markdown, Tree, Input, Label, Static, DirectoryTree
)
from textual.events import Key as KeyEvent
from textual.message import Message
from textual.reactive import reactive
from textual.widgets._data_table import RowKey, ColumnKey

# Data classes to manage the application's state cleanly
@dataclass
class JobData:
    name: str
    source: str
    backup_folder: str
    archive_folder: str
    schedule: str
    filename: str = "" # To store the .ini filename

@dataclass
class JobStatus:
    name: str
    schedule: str
    last_run: str = "Never"
    status: str = "⚪ Pending"
    next_run: datetime | None = None

# Custom messages for communicating between screens and workers
class JobUpdate(Message):
    """Message to update a job's status on the dashboard."""
    def __init__(self, job_name: str, status: str, last_run: str) -> None:
        self.job_name, self.status, self.last_run = job_name, status, last_run
        super().__init__()

class LogMessage(Message):
    """Message to append a line to the log view."""
    def __init__(self, log_text: str) -> None:
        self.log_text = log_text
        super().__init__()

class JobCreated(Message):
    """Message sent from the form back to the main app when a new job is saved."""
    def __init__(self, job_data: JobData):
        self.job_data = job_data
        super().__init__()


class JobDeleted(Message):
    """Message sent when a job is deleted."""
    def __init__(self, job_name: str):
        self.job_name = job_name
        super().__init__()


def check_system_dependencies() -> list[str]:
    """Check for required system commands. Returns list of missing commands."""
    missing = []
    for cmd in ["rsync", "tar"]:
        if not shutil.which(cmd):
            missing.append(cmd)
    return missing


def resolve_ntfs_path(path: str) -> str:
    """Resolve NTFS mount path with encoded characters."""
    if not path or not Path("/run/media").exists():
        return path
    if Path(path).exists():
        return path
    for mount in Path("/run/media").iterdir():
        if not mount.is_dir():
            continue
        for sub in mount.iterdir():
            if not sub.is_dir():
                continue
            if sub.name.startswith("Seagate") or "Seagate" in sub.name:
                if "Backups" in path:
                    fixed = str(sub / path.split("Seagate Portable Drive/")[-1].lstrip("/"))
                    if Path(fixed).exists():
                        return fixed
    return path
    if Path(path).exists():
        return path
    for mount in Path("/run/media").iterdir():
        if not mount.is_dir():
            continue
        for sub in mount.iterdir():
            if not sub.is_dir():
                continue
            clean_name = sub.name.replace("\\x", "").replace("\\", "").replace("20", " ")
            if clean_name.startswith("Seagate"):
                test_path = path.replace(str(mount), str(sub)).replace("Seagate Portable Drive", sub.name)
                if Path(test_path).exists():
                    return test_path
    return path


def validate_paths(source: str, backup_folder: str, archive_folder: str) -> tuple[bool, str]:
    """Validate that paths exist and are accessible. Returns (valid, error_message)."""
    if not source or not os.path.isdir(source):
        return False, f"Source folder does not exist: {source}"
    if not backup_folder:
        return False, "Backup folder cannot be empty"
    if not archive_folder:
        return False, "Archive folder cannot be empty"
    return True, ""


# ------------------------------
# THE NEW JOB CREATION FORM
# ------------------------------
class DirectoryPicker(ModalScreen):
    """A file/directory picker modal."""
    def __init__(self, initial_path: str = "/"):
        super().__init__()
        self.initial_path = initial_path
        self.selected_path: Path | None = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Container(id="picker-container"):
            yield Label("Select a folder - Enter or Confirm to select | Escape to cancel | Backspace to go up | N for new folder", id="picker-label")
            yield DirectoryTree("/", id="dir-tree")
            with Horizontal(id="new-folder-row"):
                yield Input(placeholder="New folder name...", id="new-folder-name")
                yield Button("Create Folder", variant="primary", id="create-folder")
            with Horizontal(id="picker-buttons"):
                yield Button("Confirm", variant="success", id="confirm")
                yield Button("Cancel", variant="error", id="cancel-picker")

    def on_mount(self) -> None:
        tree = self.query_one("#dir-tree", DirectoryTree)
        if self.initial_path and self.initial_path != "/":
            try:
                tree.expand(self.initial_path)
                tree.select(self.initial_path)
            except Exception:
                pass

    def on_directory_tree_directory_selected(self, event: DirectoryTree.DirectorySelected) -> None:
        event.stop()
        self.selected_path = event.path

    def on_key(self, event: KeyEvent) -> None:
        if event.key == "escape":
            self.app.pop_screen()
        elif event.key == "enter":
            self._confirm_selection()
        elif event.key == "backspace":
            tree = self.query_one("#dir-tree", DirectoryTree)
            current = tree.cursor_node
            if current and current.data:
                parent_path = current.data.path.parent
                if parent_path != current.data.path:
                    tree.select(parent_path)
                    tree.expand(parent_path)
        elif event.key == "n":
            self.query_one("#new-folder-name", Input).focus()

    def _confirm_selection(self) -> None:
        tree = self.query_one("#dir-tree", DirectoryTree)
        current = tree.cursor_node
        if current and current.data:
            self.dismiss(current.data.path)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "confirm":
            self._confirm_selection()
        elif event.button.id == "cancel-picker":
            self.app.pop_screen()
        elif event.button.id == "create-folder":
            tree = self.query_one("#dir-tree", DirectoryTree)
            new_folder = self.query_one("#new-folder-name", Input).value.strip()
            if not new_folder:
                return
            current = tree.cursor_node
            if current and current.data:
                import os
                parent_path = str(current.data.path)
                new_path = os.path.join(parent_path, new_folder)
                try:
                    os.makedirs(new_path, exist_ok=True)
                    tree.reload()
                    tree.expand(parent_path)
                    # Refresh and select the new folder
                    def select_new():
                        for node in tree.root.iter_all_children():
                            if node.data and str(node.data.path) == new_path:
                                tree.select(node)
                                break
                    self.call_later(select_new)
                    self.query_one("#new-folder-name", Input).value = ""
                except Exception as e:
                    self.query_one("#picker-label", Label).update(f"Error creating folder: {e}")


class JobForm(ModalScreen):
    """A modal screen that appears for creating a new backup job."""

    def compose(self) -> ComposeResult:
        with Vertical(id="job-form"):
            yield Label("Create New Backup Job", classes="form-title")
            
            yield Label("Job Name:", classes="form-label")
            yield Input(placeholder="e.g., My Website", id="name", classes="form-input")

            yield Label("Source Folder:", classes="form-label")
            with Horizontal(classes="browse-row"):
                yield Input(placeholder="/path/to/your/project", id="source", classes="form-input")
                yield Button("Browse", variant="primary", id="browse-source")

            yield Label("Backup Folder (Incremental):", classes="form-label")
            with Horizontal(classes="browse-row"):
                yield Input(placeholder="/path/to/incremental/backups", id="backup_folder", classes="form-input")
                yield Button("Browse", variant="primary", id="browse-backup")

            yield Label("Archive Folder (Snapshots):", classes="form-label")
            with Horizontal(classes="browse-row"):
                yield Input(placeholder="/path/to/archived/snapshots", id="archive_folder", classes="form-input")
                yield Button("Browse", variant="primary", id="browse-archive")

            yield Label("Schedule:", classes="form-label")
            yield Input(placeholder="e.g., 12h, 1d, or manual", id="schedule", value="manual", classes="form-input")

            with Horizontal(id="form-buttons"):
                yield Button("Save", variant="success", id="save")
                yield Button("Cancel", variant="error", id="cancel")

    def on_key(self, event: KeyEvent) -> None:
        if event.key == "escape":
            self.app.pop_screen()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.app.pop_screen()
        elif event.button.id in ("browse-source", "browse-backup", "browse-archive"):
            input_id = {"browse-source": "#source", "browse-backup": "#backup_folder", "browse-archive": "#archive_folder"}[event.button.id]

            def on_path_selected(path: Path):
                if path:
                    self.query_one(input_id, Input).value = str(path)

            start = self.query_one(input_id, Input).value or str(Path.home())
            self.app.push_screen(DirectoryPicker(start), on_path_selected)
        elif event.button.id == "save":
            name = self.query_one("#name", Input).value.strip()
            source = self.query_one("#source", Input).value.strip()
            backup_folder = self.query_one("#backup_folder", Input).value.strip()
            archive_folder = self.query_one("#archive_folder", Input).value.strip()
            schedule = self.query_one("#schedule", Input).value.strip()

            if not name:
                self.query_one("#name", Input).focus()
                return
            if not source:
                self.query_one("#source", Input).focus()
                return

            valid, error = validate_paths(source, backup_folder, archive_folder)
            if not valid:
                self.app.notify(error, severity="error")
                return

            sanitized_name = re.sub(r'[^\w_.-]', '', name.lower().replace(" ", "_"))
            if not sanitized_name:
                sanitized_name = f"job_{int(time.time())}"

            job_data = JobData(
                name=name,
                source=source,
                backup_folder=backup_folder,
                archive_folder=archive_folder,
                schedule=schedule or "manual",
                filename=f"{sanitized_name}.ini"
            )
            self.dismiss(job_data)

# ------------------------------
# The Backup Engine (Now with saving capability)
# ------------------------------
class BackupEngine:
    def __init__(self):
        self.config_dir = Path(platformdirs.user_config_dir("BackupManagerTUI"))
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def find_configs(self) -> list[dict]:
        configs = []
        for path in sorted(self.config_dir.glob("*.ini")):
            try:
                parser = configparser.ConfigParser()
                parser.read(path)
                configs.append({
                    "name": parser.get("backup", "name", fallback=path.stem),
                    "source": parser.get("backup", "source", fallback=None),
                    "backup_folder": parser.get("backup", "backup_folder", fallback=None),
                    "archive_folder": parser.get("backup", "archive_folder", fallback=None),
                    "schedule": parser.get("schedule", "interval", fallback="manual"),
                    "status": parser.get("backup", "status", fallback="⚪ Pending"),
                    "last_run": parser.get("backup", "last_run", fallback="Never"),
                    "_path": path
                })
            except Exception as e:
                logger.warning(f"Failed to parse config {path}: {e}")
        return configs

    def save_new_job(self, job_data: JobData):
        """Creates and saves a new .ini config file."""
        config = configparser.ConfigParser()
        config["backup"] = {
            "name": job_data.name,
            "source": job_data.source,
            "backup_folder": job_data.backup_folder,
            "archive_folder": job_data.archive_folder,
            "last_run": "Never",
            "status": "⚪ Pending"
        }
        config["schedule"] = {"interval": job_data.schedule}

        config_path = self.config_dir / job_data.filename
        try:
            with open(config_path, "w") as configfile:
                config.write(configfile)
            logger.info(f"Saved new job config: {job_data.name}")
        except Exception as e:
            logger.error(f"Failed to save job {job_data.name}: {e}")
            raise

    def update_job_status(self, job_name: str, status: str, last_run: str):
        """Update job status and last run time in config."""
        for config in self.find_configs():
            if config["name"] == job_name:
                config["status"] = status
                if last_run:
                    config["last_run"] = last_run
                config_path = config.get("_path")
                if config_path:
                    try:
                        parser = configparser.ConfigParser()
                        parser["backup"] = {k: v for k, v in config.items() if k != "_path"}
                        parser["schedule"] = {"interval": config.get("schedule", "manual")}
                        with open(config_path, "w") as f:
                            parser.write(f)
                        logger.info(f"Updated status for {job_name}: {status}")
                    except Exception as e:
                        logger.error(f"Failed to update status for {job_name}: {e}")
                        raise
                break

    def delete_job(self, job_name: str) -> bool:
        """Delete a job config file by name. Returns True if deleted."""
        for path in self.config_dir.glob("*.ini"):
            try:
                parser = configparser.ConfigParser()
                parser.read(path)
                if parser.get("backup", "name", fallback=path.stem) == job_name:
                    path.unlink()
                    logger.info(f"Deleted job: {job_name}")
                    return True
            except Exception as e:
                logger.warning(f"Failed to read config {path}: {e}")
        return False

    def get_config_by_name(self, job_name: str) -> Optional[dict]:
        """Get a specific job config by name."""
        for config in self.find_configs():
            if config["name"] == job_name:
                return config
        return None

    def get_archive_history(self, config: dict) -> list[Path]:
        archive_folder = config.get("archive_folder")
        if not archive_folder or not Path(archive_folder).is_dir():
            return []
        try:
            return sorted(Path(archive_folder).glob("*.tar.gz"), reverse=True)
        except Exception as e:
            logger.warning(f"Failed to list archives in {archive_folder}: {e}")
            return []

    def list_archive_contents(self, archive_path: Path) -> list[str]:
        try:
            result = subprocess.check_output(
                ["tar", "-tf", str(archive_path)],
                text=True
            )
            return result.strip().split("\n")
        except FileNotFoundError:
            logger.error("tar command not found. Please install tar.")
            return []
        except subprocess.CalledProcessError as e:
            logger.warning(f"Failed to list archive contents: {e}")
            return []
        except Exception as e:
            logger.error(f"Unexpected error reading archive: {e}")
            return []

    def run_backup_process(self, config: dict, log_callback, set_status=None):
        source = config.get("source")
        backup_folder = config.get("backup_folder")
        archive_folder = config.get("archive_folder")

        if not all([source, backup_folder, archive_folder]):
            logger.error(f"Incomplete configuration for job: {config.get('name', 'unknown')}")
            raise ValueError("Incomplete configuration.")

        if not shutil.which("rsync"):
            raise RuntimeError("rsync command not found. Please install rsync.")

        job_name = config.get("name", "backup")

        if not shutil.which("tar"):
            raise RuntimeError("tar command not found. Please install tar.")

        backup_folder = resolve_ntfs_path(backup_folder)
        source = resolve_ntfs_path(source)
        archive_folder = resolve_ntfs_path(archive_folder)
        backup_path = Path(backup_folder)
        try:
            backup_path.mkdir(parents=True, exist_ok=True)
        except PermissionError as e:
            logger.error(f"Permission denied accessing {backup_folder}: {e}")
            raise RuntimeError(f"Permission denied accessing {backup_folder}. Check mount options and permissions.")
        except OSError as e:
            logger.error(f"OS error creating backup folder {backup_folder}: {e}")
            raise RuntimeError(f"Cannot access backup folder {backup_folder}: {e}")
        except Exception as e:
            logger.error(f"Failed to create backup folder {backup_folder}: {e}")
            raise

        lock_file = Path(backup_folder) / f".{job_name}.lock"

        if lock_file.exists():
            log_callback("⚠️ Previous run was interrupted. Cleaning up...")
            lock_file.unlink()

        try:
            lock_file.write_text(str(os.getpid()))
        except Exception as e:
            logger.error(f"Failed to create lock file: {e}")
            raise
        
        try:
            log_callback(f"▶️ [bold cyan]Syncing:[/bold cyan] {source} -> {backup_folder}")
            file_count = sum(1 for _ in Path(source).rglob('*') if _.is_file())
            log_callback(f"📊 Total files to sync: {file_count}")
            
            process = subprocess.Popen(
                ["rsync", "-a", "--delete", "--progress", f"{source}/", backup_folder],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            synced = 0
            for line in iter(process.stdout.readline, ''):
                if line:
                    line = line.strip()
                    if line.endswith('%'):
                        log_callback(f"   {line}")
                    elif 'total size is' in line.lower() or 'speedup is' in line.lower():
                        log_callback(f"   ✅ {line}")
                    elif line and not line.startswith('sending'):
                        log_callback(f"   {line}")
            process.wait()
            
            if process.returncode != 0:
                raise RuntimeError(f"Rsync failed with code {process.returncode}")
            
            if set_status:
                set_status("📦 Archiving")
            log_callback(f"▶️ [bold cyan]Archiving:[/bold cyan] Compressing snapshot...")
            timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
            archive_path = Path(archive_folder) / f"{Path(source).name}_{timestamp}.tar.gz"
            Path(archive_folder).mkdir(parents=True, exist_ok=True)
            
            process = subprocess.Popen(
                ["tar", "-czv", "-C", backup_folder, "-f", str(archive_path), "."],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            archived = 0
            for line in iter(process.stdout.readline, ''):
                if line:
                    archived += 1
                    if archived % 100 == 0:
                        log_callback(f"   📦 Archived {archived} files...")
                    line = line.strip()
                    if len(line) < 80:
                        log_callback(f"   {line}")
            process.wait()
            
            if process.returncode not in (0, 1):
                raise RuntimeError(f"Tar failed with code {process.returncode}")
            
            log_callback(f"✅ [bold green]Archive created:[/bold green] {archive_path} ({archived} files)")
        finally:
            if lock_file.exists():
                lock_file.unlink()

    def _run_command(self, cmd: list[str], log_callback):
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        output_lines = []
        for line in iter(process.stdout.readline, ''):
            if line: 
                line = line.strip()
                output_lines.append(line)
                log_callback(line)
        return_code = process.wait()
        # tar returns 1 for warnings like "file changed as we read it" - not a real error
        if return_code != 0 and not (cmd[0] == 'tar' and return_code == 1):
            raise RuntimeError(f"Command failed (code {return_code}): {' '.join(cmd)}\n{output_lines[-1] if output_lines else ''}")

# ------------------------------
# The Main Textual Application
# ------------------------------
class BuMBackupManager(App):
    TITLE = "BuM-BackupManager"
    CSS_PATH = "backup_manager.css"
    jobs = reactive({}, layout=True)
    selected_job_name = reactive(None)

    def __init__(self):
        super().__init__(); self.engine = BackupEngine()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with TabbedContent(initial="dashboard"):
            with TabPane("Dashboard", id="dashboard"):
                yield Button("➕ New Backup Job", variant="success", id="new-job")
                yield DataTable(id="job-table")
                with Container(id="details"):
                    yield Markdown(id="details-md")
                    with Horizontal(id="detail-buttons"):
                        yield Button("Run Now", variant="primary", id="run-manual", disabled=True)
                        yield Button("Delete Job", variant="error", id="delete-job", disabled=True)
            with TabPane("History & Restore", id="history"):
                 yield VerticalScroll(Markdown("# Select a job from the Dashboard"), Tree("No archive selected", id="archive-tree"))
            with TabPane("Logs", id="logs"):
                yield Log(id="log-view", auto_scroll=True)
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("Status", "Job Name", "Schedule", "Last Run")
        table.cursor_type = "row"
        self.load_jobs()
        # Focus table after loading jobs so cursor is visible
        table.focus()
        self.run_worker(self.scheduler_worker, thread=True)

    def load_jobs(self) -> None:
        table = self.query_one(DataTable)
        current_selection = self.selected_job_name
        table.clear()
        configs = self.engine.find_configs()
        temp_jobs = {}
        for config in configs:
            name = config["name"]
            status_str = config.get("status", "⚪ Pending")
            last_run = config.get("last_run", "Never")
            status = JobStatus(name, config["schedule"], last_run=last_run, status=status_str)
            temp_jobs[name] = {"status": status, "config": config}
            table.add_row(status.status, status.name, status.schedule, status.last_run, key=name)
        self.jobs = temp_jobs
        if current_selection and current_selection in temp_jobs:
            self.selected_job_name = current_selection
        elif temp_jobs:
            self.selected_job_name = next(iter(temp_jobs.keys()))

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "new-job":
            def check_form_result(job_data: JobData):
                if job_data:
                    self.engine.save_new_job(job_data)
                    self.load_jobs() # Refresh the table
            self.push_screen(JobForm(), check_form_result)

        elif event.button.id == "run-manual" and self.selected_job_name:
            self.run_worker(lambda job_name=self.selected_job_name: self.job_worker(job_name), thread=True, group="backups")

        elif event.button.id == "delete-job" and self.selected_job_name:
            job_name = self.selected_job_name
            self.engine.delete_job(job_name)
            self.post_message(JobDeleted(job_name))

    def watch_selected_job_name(self, new_name: str | None) -> None:
        disabled = new_name is None
        self.query_one("#run-manual").disabled = disabled
        self.query_one("#delete-job").disabled = disabled
        md = self.query_one("#details-md")
        if new_name and new_name in self.jobs:
            config = self.jobs[new_name]["config"]
            source = config.get("source", "N/A")
            schedule = config.get("schedule", "manual")
            archive = config.get("archive_folder", "N/A")
            backup = config.get("backup_folder", "N/A")
            md.update(f"### {config['name']}\n\n**Source:** `{source}`\n\n**Backup:** `{backup}`\n\n**Archive:** `{archive}`\n\n**Schedule:** `{schedule}`")
            self.update_history_view(config)
        else:
            md.update("*Select a job from the table to view details.*")

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.row_key:
            self.selected_job_name = event.row_key.value

    def on_data_table_cell_selected(self, event: DataTable.CellSelected) -> None:
        if event.row_key:
            self.selected_job_name = event.row_key.value

    def update_history_view(self, config: dict):
        tree = self.query_one("#history Tree")
        tree.clear()
        tree.root.label = config["name"]
        md = self.query_one("#history Markdown")
        md.update(f"### History for {config['name']}\n\n*Click an archive to view its contents.*")
        for archive in sorted(self.engine.get_archive_history(config), key=lambda p: p.stat().st_mtime, reverse=True):
            tree.root.add(archive.name, data=archive)

    def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
        if event.node and event.node.data:
            archive_path = event.node.data
            contents = self.engine.list_archive_contents(archive_path)
            md = self.query_one("#history Markdown")
            files_preview = "\n".join(contents[:50])
            if len(contents) > 50:
                files_preview += f"\n... and {len(contents) - 50} more files"
            md.update(f"### {archive_path.name}\n\n```\n{files_preview}\n```")

    def scheduler_worker(self) -> None:
        def parse(s):
            match = re.match(r"(\d+)([hmd])", s.lower())
            if match:
                unit = {"h": "hours", "d": "days", "m": "minutes"}[match.group(2)]
                return timedelta(**{unit: int(match.group(1))})
            return None
        while True:
            if not self.jobs:
                time.sleep(30)
                continue
            for j in self.jobs.values():
                if i := parse(j["status"].schedule):
                    j["status"].next_run = datetime.now() + i
            now = datetime.now()
            for n, d in list(self.jobs.items()):
                s = d["status"]
                if s.next_run and now >= s.next_run:
                    self.run_worker(lambda job=n: self.job_worker(job), thread=True)
                    s.next_run = now + parse(s.schedule)
            time.sleep(30)

    def job_worker(self, job_name: str) -> None:
        def log(line):
            self.post_message(LogMessage(f"[{job_name}] {line}"))

        config = self.jobs[job_name]["config"]

        def set_status(status):
            # Post message for backend
            self.post_message(JobUpdate(job_name, status, ""))
            # Update UI immediately in main thread - bypass message queue
            def update_ui():
                if job_name in self.jobs:
                    self.jobs[job_name]["status"].status = status
                    table = self.query_one(DataTable)
                    if job_name in table.rows:
                        table.update_cell(job_name, "Status", status)
            self.call_later(update_ui)

        try:
            self.engine.update_job_status(job_name, "🔄 Syncing", "")
            set_status("🔄 Syncing")
            log("🚀 Starting sync...")
            self.engine.run_backup_process(config, log, set_status)
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
            self.engine.update_job_status(job_name, "✅ Success", timestamp)
            set_status("✅ Success")
            log("🎉 Finished.")
        except Exception as e:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
            self.engine.update_job_status(job_name, "❌ Failed", timestamp)
            set_status("❌ Failed")
            log(f"🔥 FAILED: {e}")

    def on_job_update(self, message: JobUpdate) -> None:
        if message.job_name in self.jobs:
            self.jobs[message.job_name]["status"].status = message.status
            if message.last_run:
                self.jobs[message.job_name]["status"].last_run = message.last_run
            self.load_jobs()

    def on_log_message(self, message: LogMessage) -> None:
        self.query_one("#log-view").write_line(message.log_text)

    def on_job_deleted(self, message: JobDeleted) -> None:
        self.selected_job_name = None
        self.load_jobs()


if __name__ == "__main__":
    run_app()


def run_app() -> None:
    """Entry point for CLI."""
    missing_deps = check_system_dependencies()
    if missing_deps:
        print(f"ERROR: Missing required system commands: {', '.join(missing_deps)}")
        print("Please install rsync and tar to use this application.")
        sys.exit(1)

    # Create the necessary CSS file for styling the form
    css = """
    #dashboard > Button {
        width: 100%;
        margin-bottom: 1;
    }
    #details { height: 1fr; border: solid $accent; padding: 1; }
    #history-view { height: 1fr; }
    Tree { padding: 1; width: 100%; height: 1fr; }
    #job-form {
        grid-size: 2;
        grid-gutter: 1 2;
        padding: 0 1;
        width: 80w;
        height: 12;
        border: thick $primary;
        background: $surface;
    }
    .form-label { text-align: right; }
    .form-input { width: 1fr; }
    #form-buttons {
        column-span: 2;
        align-horizontal: center;
        padding-top: 1;
    }
    #form-buttons > Button {
        margin: 0 2;
    }
    """
    with open("backup_manager.css", "w") as f:
        f.write(css)

    BuMBackupManager().run()
