from setuptools import setup, find_packages

setup(
    name="backup-manager-tui",
    version="0.1.0",
    description="A Textual-based backup manager with scheduling and archive management",
    author="Your Name",
    author_email="your@email.com",
    package_dir={"": "src"},
    packages=find_packages("src"),
    package_data={"backup_manager": ["*.css"]},
    python_requires=">=3.11",
    install_requires=[
        "textual>=0.80.0",
        "platformdirs>=4.0.0",
    ],
    entry_points={
        "console_scripts": [
            "backup-manager=backup_manager:BackupManagerApp",
        ],
    },
)