#!/usr/bin/env bash
# shellcheck shell=bash

# ==============================================================================
# Script to robustly activate a Python virtual environment (if found)
# and run a Python script (main.py, app.py, or myapp.py).
#
# Features:
# - Exits immediately on error, unset variable, or pipe failure.
# - Optionally launches itself in a new terminal if not already in one.
# - Automatically detects virtual environment: '.venv' (preferred) or 'venv'.
# - If a venv directory is found but misconfigured (e.g., no activate script
#   or python executable), it errors out.
# - If no venv is found, it gracefully uses the system Python.
# - Automatically detects Python script to run: 'main.py' (preferred),
#   'app.py' (secondary), or 'myapp.py' (tertiary). If none are found, it
#   prompts the user and can permanently update itself with the new choice.
# - If a venv is used, it explicitly calls the venv's Python interpreter.
# - Provides clear informational and error messages.
# ==============================================================================

# --- Script Configuration ---
# Toggle whether to attempt launching in a new terminal if not run from one.
# Set to "false" to disable this feature.
LAUNCH_IN_TERMINAL="true"

# Preferred venv directory names
VENV_DIR_PRIMARY=".venv"
VENV_DIR_SECONDARY="venv"

# Python script names in order of preference
SCRIPT_PRIMARY="backup_manager.py"
SCRIPT_SECONDARY="app.py"
SCRIPT_TERTIARY="myapp.py"
# --- End Configuration ---


# Strict mode
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last
#              command to exit with a non-zero status, or zero if no
#              command exited with a non-zero status.
set -euo pipefail

trap 'echo -e "\n\033[1;33mCancelled by user\033[0m"; exit 130' INT

# --- Self-launch in terminal if not already in one (and feature is enabled) ---
if [ "$LAUNCH_IN_TERMINAL" = "true" ]; then
    if [ "${_IN_TERMINAL_ALREADY:-false}" != "true" ]; then
        if ! [ -t 0 ]; then
            echo "Script not launched in a terminal. Attempting to re-launch in a new terminal..."
            SCRIPT_PATH_FOR_RELAUNCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

            TERMINAL_LAUNCH_CMD=()

            # The inner command string ensures the loop-prevention variable is set,
            # executes the script, captures its exit code, displays a message,
            # waits for a key press, and then exits with the original script's code.
            INNER_COMMAND_STRING="export _IN_TERMINAL_ALREADY=true; \"\$0\" \"\$@\"; RES=\$?; echo; echo \"--- Script execution finished (Exit Code: \$RES) ---\"; read -rsp $'Press any key to close this terminal window...\n' -n1 key; exit \$RES"

            if command -v gnome-terminal &> /dev/null; then
                TERMINAL_LAUNCH_CMD=(gnome-terminal -- bash -c "$INNER_COMMAND_STRING")
            elif command -v konsole &> /dev/null; then
                TERMINAL_LAUNCH_CMD=(konsole -e bash -c "$INNER_COMMAND_STRING")
            elif command -v xfce4-terminal &> /dev/null; then
                 TERMINAL_LAUNCH_CMD=(xfce4-terminal --hold --command="bash -c '$INNER_COMMAND_STRING'")
            elif command -v xterm &> /dev/null; then
                TERMINAL_LAUNCH_CMD=(xterm -hold -e bash -c "$INNER_COMMAND_STRING")
            fi

            if [ ${#TERMINAL_LAUNCH_CMD[@]} -gt 0 ]; then
                info "Launching in new terminal..."
                "${TERMINAL_LAUNCH_CMD[@]}" "$SCRIPT_PATH_FOR_RELAUNCH" "$@"
                exit_status=$?
                if [ $exit_status -ne 0 ]; then
                    error_exit "Failed to launch in new terminal (exit code: $exit_status)"
                fi
                exit "$exit_status"
            else
                error_exit "No suitable terminal found (gnome-terminal, konsole, xfce4-terminal, xterm)"
            fi
        fi
    fi
fi
# --- End of self-launch logic ---


# Variables to be determined by the script
VENV_DIR_TO_USE=""
PYTHON_SCRIPT_TO_RUN=""
PYTHON_EXECUTABLE="python3"
# --- Helper Functions ---
# Function to print error messages to stderr and exit
error_exit() {
    echo "" >&2
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
    exit 1
}

# Function to print informational messages to stdout
info() {
    echo -e "\033[1;36m[INFO]\033[0m $1"
}

# Function to print success messages
success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

# Function to print section headers
section() {
    echo ""
    echo -e "\033[1;34m=== $1 ===\033[0m"
}
# --- End Helper Functions ---

# --- Main Script Logic ---

# 1. Determine virtual environment directory to use
section "Virtual Environment"
info "Checking for virtual environment..."
if [ -d "$VENV_DIR_PRIMARY" ]; then
    VENV_DIR_TO_USE="$VENV_DIR_PRIMARY"
    success "Found: $VENV_DIR_PRIMARY"
elif [ -d "$VENV_DIR_SECONDARY" ]; then
    VENV_DIR_TO_USE="$VENV_DIR_SECONDARY"
    success "Found: $VENV_DIR_SECONDARY"
else
    info "No virtual environment detected."
fi

# 2. Determine Python executable and activate venv if one was identified
if [ -n "$VENV_DIR_TO_USE" ]; then # -n checks if the string is not empty (i.e., a venv dir was found)
    ACTIVATE_SCRIPT="$VENV_DIR_TO_USE/bin/activate"
    # Prefer python3 in venv as well, but fall back to python if python3 isn't there
    # This is more robust for venvs created with older 'virtualenv' or specific flags.
    if [ -f "$VENV_DIR_TO_USE/bin/python3" ]; then
        EXPECTED_VENV_PYTHON="$VENV_DIR_TO_USE/bin/python3"
    elif [ -f "$VENV_DIR_TO_USE/bin/python" ]; then
        EXPECTED_VENV_PYTHON="$VENV_DIR_TO_USE/bin/python"
    else
        EXPECTED_VENV_PYTHON="" # Will be caught by the check below
    fi


    if [ ! -f "$ACTIVATE_SCRIPT" ]; then
        error_exit "Virtual environment directory '$VENV_DIR_TO_USE' found, but its activation script '$ACTIVATE_SCRIPT' is missing. Please ensure it's a valid virtual environment."
    fi

    if [ -z "$EXPECTED_VENV_PYTHON" ] || [ ! -f "$EXPECTED_VENV_PYTHON" ]; then
        error_exit "Virtual environment directory '$VENV_DIR_TO_USE' found, and '$ACTIVATE_SCRIPT' exists, but a Python executable ('$VENV_DIR_TO_USE/bin/python3' or '$VENV_DIR_TO_USE/bin/python') is missing. The venv seems corrupted or improperly created."
    fi

    info "Activating virtual environment..."
    # shellcheck source=/dev/null
    source "$ACTIVATE_SCRIPT"

    PYTHON_EXECUTABLE="$EXPECTED_VENV_PYTHON"
    success "Using: $PYTHON_EXECUTABLE (from venv)"
else
    if ! command -v "$PYTHON_EXECUTABLE" &> /dev/null; then
        if command -v "python" &> /dev/null; then
            PYTHON_EXECUTABLE="python"
            info "python3 not found, using: python"
        else
            error_exit "No virtual environment and Python not found in PATH."
        fi
    fi
    success "Using system Python: $PYTHON_EXECUTABLE"
fi

# 3. Determine Python script to run
section "Script Selection"

# First, try auto-detecting preferred scripts (main.py, app.py, myapp.py)
if [ -f "$SCRIPT_PRIMARY" ]; then
    PYTHON_SCRIPT_TO_RUN="$SCRIPT_PRIMARY"
    success "Found '$SCRIPT_PRIMARY'"
elif [ -f "$SCRIPT_SECONDARY" ]; then
    PYTHON_SCRIPT_TO_RUN="$SCRIPT_SECONDARY"
    success "Found '$SCRIPT_SECONDARY'"
elif [ -f "$SCRIPT_TERTIARY" ]; then
    PYTHON_SCRIPT_TO_RUN="$SCRIPT_TERTIARY"
    success "Found '$SCRIPT_TERTIARY'"
else
    info "No default script found."

    # Scan for all .py files in current dir and subdirectories (excluding venv folders)
    # Use %P to get path relative to current directory (removes ./ prefix)
    mapfile -t python_files < <(find . -type f -name "*.py" -not -path "./.venv/*" -not -path "./venv/*" -printf "%P\n" 2>/dev/null | sort)

    if [ ${#python_files[@]} -gt 0 ]; then
        echo ""
        echo -e "\033[1;33mAvailable Python scripts:\033[0m"
        echo ""
        PS3=$'\033[1;37mSelect script number: \033[0m'
        select chosen_script in "${python_files[@]}"; do
            if [[ -n "$chosen_script" ]]; then
                PYTHON_SCRIPT_TO_RUN="$chosen_script"
                break
            else
                echo -e "\033[1;31mInvalid selection.\033[0m" >&2
            fi
        done
    else
        error_exit "No Python scripts found."
    fi

    success "Selected: $PYTHON_SCRIPT_TO_RUN"

    # Ask if user wants to save as default
    read -r -p $'\033[1;37mSave as default? [y/N]: \033[0m' confirm_update
    if [[ "$confirm_update" =~ ^[Yy](es)?$ ]]; then
        temp_file=$(mktemp)
        if [ $? -ne 0 ]; then
            echo -e "\033[1;33m[WARNING] Could not create temp file.\033[0m" >&2
        else
            sed "s|^SCRIPT_PRIMARY=.*|SCRIPT_PRIMARY=\"$PYTHON_SCRIPT_TO_RUN\"|" "$0" > "$temp_file"
            if [ -s "$temp_file" ]; then
                mv "$temp_file" "$0"
                chmod +x "$0"
                success "Saved as default: $PYTHON_SCRIPT_TO_RUN"
            else
                rm -f "$temp_file"
            fi
        fi
    fi
fi

# 4. Run the Python script
section "Execution"
echo -e "\033[1;37mRunning: $PYTHON_SCRIPT_TO_RUN\033[0m"
echo -e "\033[1;37mUsing:   $PYTHON_EXECUTABLE\033[0m"
echo ""
"$PYTHON_EXECUTABLE" "$PYTHON_SCRIPT_TO_RUN" "$@"
exit_code=$?

section "Complete"
if [ $exit_code -eq 0 ]; then
    success "Script finished successfully (exit code: $exit_code)"
else
    error_exit "Script failed with exit code: $exit_code"
fi

exit $exit_code
