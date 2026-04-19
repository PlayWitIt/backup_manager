import os
import sys
import subprocess
import shutil
import configparser
import time
import re
from datetime import datetime, timedelta
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

# Dependency to find the correct user config directory on any OS
import platformdirs

from textual.app import App, ComposeResult
from textual.containers import Container, VerticalScroll, Vertical, Grid, Horizontal
from textual.screen import ModalScreen
from textual.widgets import (
    Header, Footer, DataTable, Button, Log, TabbedContent, TabPane, Markdown, Tree, Input, Label, Static
)
from textual.message import Message
from textual.reactive import reactive

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
class JobForm(ModalScreen):
    """A modal screen that appears for creating a new backup job."""

    def compose(self) -> ComposeResult:
        with Grid(id="job-form"):
            yield Label("Job Name:", classes="form-label")
            yield Input(placeholder="e.g., My Website", id="name", classes="form-input")

            yield Label("Source Folder:", classes="form-label")
            yield Input(placeholder="/path/to/your/project", id="source", classes="form-input")

            yield Label("Backup Folder (Incremental):", classes="form-label")
            yield Input(placeholder="/path/to/incremental/backups", id="backup_folder", classes="form-input")

            yield Label("Archive Folder (Snapshots):", classes="form-label")
            yield Input(placeholder="/path/to/archived/snapshots", id="archive_folder", classes="form-input")

            yield Label("Schedule:", classes="form-label")
            yield Input(placeholder="e.g., 12h, 1d, or manual", id="schedule", value="manual", classes="form-input")

            with Container(id="form-buttons"):
                yield Button("Save", variant="success", id="save")
                yield Button("Cancel", variant="error", id="cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.app.pop_screen()
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
            parser = configparser.ConfigParser(); parser.read(path)
            configs.append({
                "name": parser.get("backup", "name", fallback=path.stem),
                "source": parser.get("backup", "source", fallback=None),
                "backup_folder": parser.get("backup", "backup_folder", fallback=None),
                "archive_folder": parser.get("backup", "archive_folder", fallback=None),
                "schedule": parser.get("schedule", "interval", fallback="manual"),
                "_path": path
            })
        return configs

    def save_new_job(self, job_data: JobData):
        """Creates and saves a new .ini config file."""
        config = configparser.ConfigParser()
        config["backup"] = {
            "name": job_data.name,
            "source": job_data.source,
            "backup_folder": job_data.backup_folder,
            "archive_folder": job_data.archive_folder
        }
        config["schedule"] = {"interval": job_data.schedule}

        config_path = self.config_dir / job_data.filename
        with open(config_path, "w") as configfile:
            config.write(configfile)

    def delete_job(self, job_name: str) -> bool:
        """Delete a job config file by name. Returns True if deleted."""
        for path in self.config_dir.glob("*.ini"):
            parser = configparser.ConfigParser()
            parser.read(path)
            if parser.get("backup", "name", fallback=path.stem) == job_name:
                path.unlink()
                return True
        return False

    def get_config_by_name(self, job_name: str) -> Optional[dict]:
        """Get a specific job config by name."""
        for config in self.find_configs():
            if config["name"] == job_name:
                return config
        return None

    def get_archive_history(self, config: dict) -> list[Path]:
        archive_folder = config.get("archive_folder")
        if not archive_folder or not Path(archive_folder).is_dir(): return []
        return sorted(Path(archive_folder).glob("*.tar.gz"), reverse=True)

    def list_archive_contents(self, archive_path: Path) -> list[str]:
        try: result = subprocess.check_output(["tar", "-tf", str(archive_path)], text=True); return result.strip().split("\n")
        except: return []

    def run_backup_process(self, config: dict, log_callback):
        source, backup_folder, archive_folder = config.get("source"), config.get("backup_folder"), config.get("archive_folder")
        if not all([source, backup_folder, archive_folder]): raise ValueError("Incomplete configuration.")

        log_callback(f"▶️ [bold cyan]Rsync:[/bold cyan] {source} -> {backup_folder}"); Path(backup_folder).mkdir(parents=True, exist_ok=True)
        self._run_command(["rsync", "-a", "--delete", f"{source}/", backup_folder], log_callback)

        log_callback(f"▶️ [bold cyan]Archive:[/bold cyan] Compressing snapshot..."); Path(archive_folder).mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
        archive_path = Path(archive_folder) / f"{Path(source).name}_{timestamp}.tar.gz"
        self._run_command(["tar", "-czf", str(archive_path), "-C", backup_folder, "."], log_callback)
        log_callback(f"✅ [bold green]Archive created:[/bold green] {archive_path}")

    def _run_command(self, cmd: list[str], log_callback):
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in iter(process.stdout.readline, ''):
            if line: log_callback(line.strip())
        if process.wait() != 0: raise RuntimeError(f"Command failed: {' '.join(cmd)}")

# ------------------------------
# The Main Textual Application
# ------------------------------
class BackupManagerApp(App):
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
        table = self.query_one(DataTable); table.add_columns("Status", "Job Name", "Schedule", "Last Run"); self.load_jobs(); self.run_worker(self.scheduler_worker, thread=True)

    def load_jobs(self) -> None:
        table = self.query_one(DataTable); table.clear(); configs = self.engine.find_configs(); temp_jobs = {}
        for config in configs: name = config["name"]; status = JobStatus(name, config["schedule"]); temp_jobs[name] = {"status": status, "config": config}; table.add_row(status.status, status.name, status.schedule, status.last_run, key=name)
        self.jobs = temp_jobs;

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "new-job":
            def check_form_result(job_data: JobData):
                if job_data:
                    self.engine.save_new_job(job_data)
                    self.load_jobs() # Refresh the table
            self.push_screen(JobForm(), check_form_result)

        elif event.button.id == "run-manual" and self.selected_job_name:
            self.run_worker(self.job_worker, self.selected_job_name, thread=True, group="backups")

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
                    self.run_worker(self.job_worker, n, thread=True)
                    s.next_run = now + parse(s.schedule)
            time.sleep(30)

    def job_worker(self, job_name: str) -> None:
        log = lambda line: self.post_message(LogMessage(f"[{job_name}] {line}")); config = self.jobs[job_name]["config"]
        try:
            self.call_from_thread(self.query_one(DataTable).update_cell, job_name, "Status", "🕒 Running"); log("🚀 Starting...")
            self.engine.run_backup_process(config, log)
            self.post_message(JobUpdate(job_name, "✅ Success", datetime.now().strftime("%Y-%m-%d %H:%M"))); log("🎉 Finished.")
        except Exception as e:
            self.post_message(JobUpdate(job_name, "❌ Failed", datetime.now().strftime("%Y-%m-%d %H:%M"))); log(f"🔥 FAILED: {e}")

    def on_job_update(self, message: JobUpdate) -> None:
        table = self.query_one(DataTable); table.update_cell(message.job_name, "Status", message.status); table.update_cell(message.job_name, "Last Run", message.last_run)

    def on_log_message(self, message: LogMessage) -> None:
        self.query_one("#log-view").write_line(message.log_text)

    def on_job_deleted(self, message: JobDeleted) -> None:
        self.selected_job_name = None
        self.load_jobs()


if __name__ == "__main__":
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

    BackupManagerApp().run()
