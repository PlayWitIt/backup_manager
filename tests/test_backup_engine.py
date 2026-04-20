import pytest
import tempfile
import os
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock
from datetime import datetime

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from backup_manager import BackupEngine, JobData, JobStatus


class TestBackupEngine:
    @pytest.fixture
    def temp_config_dir(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        with patch("platformdirs.user_config_dir", return_value=str(config_dir)):
            yield config_dir

    @pytest.fixture
    def engine(self, temp_config_dir):
        with patch("platformdirs.user_config_dir", return_value=str(temp_config_dir)):
            yield BackupEngine()

    def test_save_new_job(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup/path",
            archive_folder="/archive/path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)

        config_file = temp_config_dir / "test_job.ini"
        assert config_file.exists()

    def test_find_configs(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup/path",
            archive_folder="/archive/path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)

        configs = engine.find_configs()
        assert len(configs) == 1
        assert configs[0]["name"] == "Test Job"
        assert configs[0]["source"] == "/source/path"
        assert configs[0]["schedule"] == "manual"

    def test_update_job_status(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup/path",
            archive_folder="/archive/path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)

        engine.update_job_status("Test Job", "✅ Success", "2024-01-01 12:00")

        configs = engine.find_configs()
        assert configs[0]["status"] == "✅ Success"
        assert configs[0]["last_run"] == "2024-01-01 12:00"

    def test_update_job_status_empty_last_run(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup/path",
            archive_folder="/archive/path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)
        engine.update_job_status("Test Job", "✅ Success", "2024-01-01 12:00")

        engine.update_job_status("Test Job", "🔄 Syncing", "")

        configs = engine.find_configs()
        assert configs[0]["status"] == "🔄 Syncing"
        assert configs[0]["last_run"] == "2024-01-01 12:00"

    def test_delete_job(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup_folder",
            archive_folder="/archive_path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)

        result = engine.delete_job("Test Job")

        assert result is True
        assert not (temp_config_dir / "test_job.ini").exists()

    def test_get_config_by_name(self, engine, temp_config_dir):
        job_data = JobData(
            name="Test Job",
            source="/source/path",
            backup_folder="/backup/path",
            archive_folder="/archive/path",
            schedule="manual",
            filename="test_job.ini"
        )
        engine.save_new_job(job_data)

        config = engine.get_config_by_name("Test Job")

        assert config is not None
        assert config["name"] == "Test Job"

    def test_get_config_by_name_not_found(self, engine):
        config = engine.get_config_by_name("NonExistent")
        assert config is None

    def test_find_configs_empty_dir(self, engine):
        configs = engine.find_configs()
        assert configs == []


class TestJobStatus:
    def test_default_status(self):
        status = JobStatus(name="Test", schedule="manual")
        assert status.status == "⚪ Pending"
        assert status.last_run == "Never"

    def test_custom_status(self):
        status = JobStatus(name="Test", schedule="manual", status="✅ Success", last_run="2024-01-01")
        assert status.status == "✅ Success"
        assert status.last_run == "2024-01-01"