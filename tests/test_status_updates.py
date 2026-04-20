import pytest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from backup_manager import JobUpdate, JobStatus, JobData


class TestJobUpdateMessage:
    def test_job_update_message_creation(self):
        msg = JobUpdate(job_name="TestJob", status="🔄 Syncing", last_run="2024-01-01 12:00")
        assert msg.job_name == "TestJob"
        assert msg.status == "🔄 Syncing"
        assert msg.last_run == "2024-01-01 12:00"

    def test_job_update_message_empty_last_run(self):
        msg = JobUpdate(job_name="TestJob", status="🔄 Syncing", last_run="")
        assert msg.last_run == ""


class TestJobStatusBehavior:
    def test_status_changes_correctly(self):
        status = JobStatus(name="Test", schedule="manual", status="⚪ Pending", last_run="Never")
        assert status.status == "⚪ Pending"

        status.status = "🔄 Syncing"
        assert status.status == "🔄 Syncing"

        status.status = "✅ Success"
        assert status.status == "✅ Success"

    def test_last_run_updates_correctly(self):
        status = JobStatus(name="Test", schedule="manual", status="⚪ Pending", last_run="Never")
        assert status.last_run == "Never"

        status.last_run = "2024-01-01 12:00"
        assert status.last_run == "2024-01-01 12:00"


class TestJobData:
    def test_job_data_creation(self):
        job = JobData(
            name="My Backup",
            source="/home/user/data",
            backup_folder="/backups/data",
            archive_folder="/backups/archive",
            schedule="12h",
            filename="my_backup.ini"
        )
        assert job.name == "My Backup"
        assert job.source == "/home/user/data"
        assert job.backup_folder == "/backups/data"
        assert job.archive_folder == "/backups/archive"
        assert job.schedule == "12h"
        assert job.filename == "my_backup.ini"

    def test_job_data_default_filename(self):
        job = JobData(
            name="Test Job",
            source="/source",
            backup_folder="/backup",
            archive_folder="/archive",
            schedule="manual"
        )
        assert job.filename == ""