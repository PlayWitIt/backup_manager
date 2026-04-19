#!/bin/bash
# shellcheck shell=bash

# HOW TO MAKE IT EXECUTABLE:
# --------------------------
# 1. Save this script to a file, for example, `py_bootstrap.sh`.
# 2. Open your terminal and navigate to the directory where you saved the file.
# 3. Run the command: `chmod +x py_bootstrap.sh`
# 4. Now you can execute the script by running: `./py_bootstrap.sh`
#
# SCRIPT PURPOSE:
# ---------------
# This script automates the setup of a Python project environment,
# supporting pyenv, conda, or standard system Python with venv.
# It optionally initializes a Git repository.
# 1. Cleans up old local virtual environment (.venv).
# 2. Determines Python environment strategy (pyenv+venv, conda, or system+venv).
# 3. Creates/configures the chosen Python environment.
# 4. Activates the environment, sanitizes and installs dependencies from requirements.txt.
# 5. Optional Git repository initialization and .gitignore creation.
#
# ROBUSTNESS FEATURES:
# --------------------
# - `set -e`, `set -o pipefail`, `set -u`
# - Command existence checks.
# - Detailed messages and user interaction.
# - Attempts to detect and work around common Conda issues.
# - Self-heals a corrupted or incomplete requirements.txt file if it exists.

# Use a specific environment variable to avoid infinite loops when re-launching in terminal.
# shellcheck disable=SC2034
if [ "${_IN_TERMINAL_ALREADY:-false}" != "true" ]; then
    if ! [ -t 0 ]; then
        echo "Script not launched in a terminal. Attempting to re-launch in a new terminal..."
        SCRIPT_PATH_FOR_RELAUNCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
        TERMINAL_LAUNCH_CMD=()

        CONDA_INIT_SNIPPET=""
        if command -v conda &> /dev/null; then
            CONDA_PATH=$(command -v conda)
            CONDA_ROOT=$(dirname $(dirname "$CONDA_PATH"))
            if [ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]; then
                CONDA_INIT_SNIPPET="source '$CONDA_ROOT/etc/profile.d/conda.sh';"
            fi
        fi

        INNER_COMMAND_STRING="$CONDA_INIT_SNIPPET export _IN_TERMINAL_ALREADY=true; \"\$0\" \"\$@\"; RES=\$?; echo; echo \"--- Script execution finished (Exit Code: \$RES) ---\"; read -rsp $'Press any key to close this terminal window...\n' -n1 key; exit \$RES"

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
            echo "Using: ${TERMINAL_LAUNCH_CMD[0]} to re-launch..."
            "${TERMINAL_LAUNCH_CMD[@]}" "$SCRIPT_PATH_FOR_RELAUNCH" "$@"
            exit_status=$?
            if [ $exit_status -ne 0 ]; then
                echo "Failed to launch in new terminal (exit code: $exit_status)." >&2
            fi
            exit "$exit_status"
        else
            echo "ERROR: No suitable terminal emulator found. Please run from an existing terminal." >&2
            exit 1
        fi
    fi
fi

set -euo pipefail

trap 'echo -e "\n\033[1;33mCancelled by user\033[0m"; exit 130' INT

# --- Helper Functions ---
section() {
    echo ""
    echo -e "\033[1;34m=== $1 ===\033[0m"
}

error_exit() {
    echo "" >&2
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
    if [ -n "${2:-}" ]; then
        echo -e "    \033[90mHint:\033[0m $2" >&2
    fi
    if [ -n "${CONDA_SHLVL:-}" ] && [ "$CONDA_SHLVL" -gt 0 ] && [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        echo -e "    \033[90mActive Conda environment: $CONDA_DEFAULT_ENV\033[0m" >&2
    elif [ -n "${VIRTUAL_ENV:-}" ]; then
        echo -e "    \033[90mActive virtual environment: $VIRTUAL_ENV\033[0m" >&2
    fi
    exit 1
}

warning_message() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

info_message() {
    echo -e "\033[1;36m[INFO]\033[0m $1"
}

success_message() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

command_exists() {
    command -v "$1" &>/dev/null
}

create_gitignore_if_needed() {
    local venv_dir_to_ignore="$1" # Pass .venv path if venv is used, empty otherwise
    local create_gitignore_answer_local create_gitignore_answer_lower_local

    if [ -e ".gitignore" ]; then
        info_message "'.gitignore' file already exists. No action taken regarding creation."
        return 0
    fi

    read -r -p "A '.gitignore' file is not present. Do you want to create a basic one? [y/N]: " create_gitignore_answer_local
    create_gitignore_answer_lower_local=$(echo "$create_gitignore_answer_local" | tr '[:upper:]' '[:lower:]')

    if [[ "$create_gitignore_answer_lower_local" == "y" || "$create_gitignore_answer_lower_local" == "yes" ]]; then
        info_message "Creating '.gitignore' file..."
        cat << EOF > .gitignore
# Python
__pycache__/
*.py[cod]
*.egg-info/
dist/
build/
EOF
        if [ -n "$venv_dir_to_ignore" ]; then
        cat << EOF >> .gitignore

# Virtual environment (local venv)
$venv_dir_to_ignore/
EOF
        fi
        cat << EOF >> .gitignore

# Environment variables
*.env
*.env.*
!*.env.example

# OS-specific
.DS_Store
Thumbs.db
desktop.ini

# IDE / Editor specific
.vscode/
.idea/
*.swp
*~

# Generated helper scripts (if you choose not to commit them)
# activate_project_env.sh
EOF
        info_message "'.gitignore' created. Consider adding it to Git: git add .gitignore && git commit -m \"Add .gitignore\""
    else
        info_message "Skipping '.gitignore' creation by user choice."
    fi
}

# --- Main Script Logic ---
section "Project Setup"

# --- Clean up old local virtual environment ---
section "Virtual Environment Cleanup"
readonly VENV_DIR_NAME=".venv"
info_message "Cleaning up old local virtual environment ('$VENV_DIR_NAME')..."
if [ -d "$VENV_DIR_NAME" ]; then
  info_message "Removing existing '$VENV_DIR_NAME'..."
  if ! rm -rf "$VENV_DIR_NAME"; then error_exit "Failed to remove '$VENV_DIR_NAME'. Check permissions."; fi
  info_message "Successfully removed '$VENV_DIR_NAME'."
elif [ -d "venv" ]; then # Legacy check
  info_message "Removing legacy 'venv' directory..."
  if ! rm -rf "venv"; then error_exit "Failed to remove 'venv'. Check permissions."; fi
  info_message "Successfully removed 'venv'."
else
  info_message "No existing '$VENV_DIR_NAME' or 'venv' directory found. Skipping cleanup."
fi
echo

section "Python Environment Setup"
info_message "Determining Python environment type and creating it..."
PYTHON_EXECUTABLE_FOR_VENV_CREATION=""
CHOSEN_PYTHON_FOR_DISPLAY=""
ENV_SETUP_METHOD="none" # "venv" or "conda"
ACTIVATION_COMMAND_FOR_USER=""
VENV_PATH_FOR_SCRIPT="$VENV_DIR_NAME" # For standard venv
CONDA_ENV_NAME=""
DEFAULT_PYTHON_VERSION_FALLBACK="3.9" # Fallback if no .python-version and user doesn't specify for Conda
CONDA_NEEDS_OPENSSL_FIX=false # Flag for OpenSSL issue
CONDA_CMD_PREFIX="" # Prefix for Conda commands if OpenSSL fix is needed

# Read .python-version if it exists
PYTHON_VERSION_FROM_FILE=""
if [ -f ".python-version" ]; then
  PYTHON_VERSION_FROM_FILE=$(tr -d '[:space:]' < ".python-version")
  info_message "'.python-version' file found, specifies Python version: '$PYTHON_VERSION_FROM_FILE'"
fi

# --- Attempt 1: pyenv + venv (if .python-version is specific and pyenv is available) ---
if [ -n "$PYTHON_VERSION_FROM_FILE" ] && [ "$PYTHON_VERSION_FROM_FILE" != "system" ] && command_exists "pyenv"; then
  info_message "pyenv is installed and .python-version specifies '$PYTHON_VERSION_FROM_FILE'."
  pyenv_versions_output=$(pyenv versions --bare)
  if ! echo "$pyenv_versions_output" | grep -Fxq "$PYTHON_VERSION_FROM_FILE"; then
    pyenv_install_log_file="pyenv_install_python.log"
    info_message "Python '$PYTHON_VERSION_FROM_FILE' not installed via pyenv. Attempting install (log: '$pyenv_install_log_file')..."
    if ! pyenv install "$PYTHON_VERSION_FROM_FILE" > "$pyenv_install_log_file" 2>&1; then
      pyenv_install_exit_code=$?
      pyenv_failure_hint="pyenv failed to install Python '$PYTHON_VERSION_FROM_FILE' (exit code $pyenv_install_exit_code).
Detailed build logs from pyenv have been saved to '$pyenv_install_log_file' in the current directory. Please review this file.
Also check 'pyenv install --list' or pyenv's internal logs (often in ~/.pyenv/versions/...).
Ensure build dependencies for Python itself are met. For example:
Debian/Ubuntu: sudo apt-get install -y build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev libffi-dev liblzma-dev python3-openssl git
Fedora: sudo dnf groupinstall -y \"Development Tools\" && sudo dnf install -y zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
Arch Linux: sudo pacman -S --noconfirm base-devel openssl zlib bzip2 readline sqlite tk ncurses xz"
      error_exit "pyenv failed to install Python '$PYTHON_VERSION_FROM_FILE'." "$pyenv_failure_hint"
    else
      rm -f "$pyenv_install_log_file"
      info_message "Successfully installed Python '$PYTHON_VERSION_FROM_FILE' with pyenv."
    fi
  else
    info_message "Python version '$PYTHON_VERSION_FROM_FILE' is already installed via pyenv."
  fi

  PYENV_ROOT=$(pyenv root)
  CANDIDATE_PYTHON_PATH="$PYENV_ROOT/versions/$PYTHON_VERSION_FROM_FILE/bin/python"
  if [ -x "$CANDIDATE_PYTHON_PATH" ]; then
    PYTHON_EXECUTABLE_FOR_VENV_CREATION="$CANDIDATE_PYTHON_PATH"

    info_message "Ensuring pyenv local version for this directory is set to '$PYTHON_VERSION_FROM_FILE'..."
    if pyenv local "$PYTHON_VERSION_FROM_FILE"; then
        info_message "Successfully set/confirmed pyenv local version to '$PYTHON_VERSION_FROM_FILE'. '.python-version' file updated/created."
    else
        warning_message "Failed to set pyenv local version to '$PYTHON_VERSION_FROM_FILE'. You may need to do this manually if not already set."
    fi

    info_message "Using pyenv-managed Python to create a standard venv: $PYTHON_EXECUTABLE_FOR_VENV_CREATION"
    if ! "$PYTHON_EXECUTABLE_FOR_VENV_CREATION" -m venv "$VENV_PATH_FOR_SCRIPT"; then
      error_exit "Failed to create venv using pyenv's Python ($PYTHON_EXECUTABLE_FOR_VENV_CREATION)." \
                 "Check if '$PYTHON_EXECUTABLE_FOR_VENV_CREATION' is valid and the 'venv' module is available."
    fi
    ENV_SETUP_METHOD="venv"
    CHOSEN_PYTHON_FOR_DISPLAY="$PYTHON_EXECUTABLE_FOR_VENV_CREATION (via pyenv)"
    ACTIVATION_COMMAND_FOR_USER="source \"$VENV_PATH_FOR_SCRIPT/bin/activate\""
  else
    warning_message "pyenv Python '$PYTHON_VERSION_FROM_FILE' not found at '$CANDIDATE_PYTHON_PATH'. Will try other methods."
  fi
elif [ -n "$PYTHON_VERSION_FROM_FILE" ] && [ "$PYTHON_VERSION_FROM_FILE" != "system" ] && ! command_exists "pyenv"; then
    warning_message "'.python-version' specifies '$PYTHON_VERSION_FROM_FILE', but 'pyenv' command is not installed or not in PATH. Will try other methods."
fi

# --- Attempt 2: conda (if pyenv was not used for a specific version, and conda is available) ---
if [ "$ENV_SETUP_METHOD" == "none" ] && command_exists "conda"; then
  CONDA_WORKS_PROPERLY=true # Assume it works until a test fails
  CONDA_TEST_OUTPUT_FILE=$(mktemp) # Use mktemp for temporary file

  info_message "Conda command found by 'command_exists'. Testing its functionality..."

  # Run conda --version and capture all output (stdout and stderr)
  set +e # Allow command to fail for this test
  conda --version > "$CONDA_TEST_OUTPUT_FILE" 2>&1
  conda_test_exit_code=$?
  set -e # Re-enable exit on error

  # Check for the OpenSSL error string in the combined output first
  if grep -q "OpenSSL 3.0's legacy provider failed to load" "$CONDA_TEST_OUTPUT_FILE"; then
    CONDA_NEEDS_OPENSSL_FIX=true
    warning_message "Initial Conda test showed an OpenSSL 3.0 legacy provider issue."
    info_message "Attempting to run Conda commands for this script session with CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1."
    info_message "If this script succeeds with Conda, you should consider setting this variable permanently in your shell environment for reliable Conda use."
    info_message "Example for bash: echo 'export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1' >> ~/.bashrc && source ~/.bashrc"

    CONDA_CMD_PREFIX="CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 " # Set prefix for subsequent Conda commands

    # Re-test with the fix to ensure it *actually* helps and conda is viable
    set +e
    CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 conda --version > "$CONDA_TEST_OUTPUT_FILE" 2>&1
    conda_test_exit_code_with_fix=$?
    set -e

    if [ $conda_test_exit_code_with_fix -ne 0 ]; then
      CONDA_WORKS_PROPERLY=false # Still failing even with the attempted fix
      warning_message "Conda still failed (exit code $conda_test_exit_code_with_fix) even when attempting OpenSSL fix. Conda might be broken or not initialized correctly for the shell."
      cat "$CONDA_TEST_OUTPUT_FILE" >&2
    else
      # Conda --version (with fix) exited successfully.
      # It might still print the OpenSSL error to stderr from a sub-component but the main command works.
      if grep -q "OpenSSL 3.0's legacy provider failed to load" "$CONDA_TEST_OUTPUT_FILE"; then
         info_message "Conda test with OpenSSL fix still showed the OpenSSL message in output but command exited successfully. Proceeding with Conda."
      else
         info_message "Conda test with OpenSSL fix was successful (command succeeded, OpenSSL message may or may not be present). Proceeding with Conda."
      fi
    fi
  elif [ $conda_test_exit_code -ne 0 ]; then
    # If no OpenSSL error string was found, but `conda --version` still had a non-zero exit code
    CONDA_WORKS_PROPERLY=false
    warning_message "Initial Conda test failed with an unknown error (exit code $conda_test_exit_code) and no specific OpenSSL message detected. Conda might be broken or not properly initialized for the shell."
    cat "$CONDA_TEST_OUTPUT_FILE" >&2
  else
    # `conda --version` exited 0 and no OpenSSL error string found in output
    info_message "Conda test successful (command exited 0, no OpenSSL error detected)."
  fi
  rm -f "$CONDA_TEST_OUTPUT_FILE" # Clean up temp file

  if ! $CONDA_WORKS_PROPERLY; then
    warning_message "Conda is not functioning correctly enough for this script to use. Skipping Conda setup option."
  else
    # --- Conda is deemed viable, proceed with user prompt and setup ---
    read -r -p "Conda detected and seems usable (possibly with an OpenSSL workaround by the script). Would you like to use a Conda environment for this project? [Y/n]: " use_conda_answer
    use_conda_answer_lower=$(echo "$use_conda_answer" | tr '[:upper:]' '[:lower:]')

    if [[ "$use_conda_answer_lower" == "y" || "$use_conda_answer_lower" == "yes" || -z "$use_conda_answer_lower" ]]; then
      user_conda_env_name=""
      SANITIZED_PROJECT_NAME_FOR_CONDA=$(basename "$(pwd)" | sed 's/[^a-zA-Z0-9_-]//g')
      CONDA_ENV_NAME_SUGGESTION="${SANITIZED_PROJECT_NAME_FOR_CONDA}_env"
      if [ -z "$CONDA_ENV_NAME_SUGGESTION" ]; then CONDA_ENV_NAME_SUGGESTION="myproject_env"; fi

      read -r -p "Enter Conda environment name (default: myenv, suggestion: $CONDA_ENV_NAME_SUGGESTION): " user_conda_env_name
      CONDA_ENV_NAME="${user_conda_env_name:-myenv}"
      if [ -z "$CONDA_ENV_NAME" ]; then CONDA_ENV_NAME="myenv"; fi
      info_message "Using Conda environment name: '$CONDA_ENV_NAME'"

      PYTHON_VERSION_FOR_CONDA="$DEFAULT_PYTHON_VERSION_FALLBACK"
      if [ -n "$PYTHON_VERSION_FROM_FILE" ] && [ "$PYTHON_VERSION_FROM_FILE" != "system" ]; then
          PYTHON_VERSION_FOR_CONDA="$PYTHON_VERSION_FROM_FILE"
          info_message "Using Python version '$PYTHON_VERSION_FOR_CONDA' from .python-version file for Conda."
      else
          read -r -p "Enter Python version for Conda environment '$CONDA_ENV_NAME' (e.g., 3.9, 3.10, default: $DEFAULT_PYTHON_VERSION_FALLBACK): " user_py_ver_conda
          PYTHON_VERSION_FOR_CONDA="${user_py_ver_conda:-$DEFAULT_PYTHON_VERSION_FALLBACK}"
      fi
      info_message "Target Python version for Conda: $PYTHON_VERSION_FOR_CONDA"

      CONDA_BASE_PATH_FOR_HOOK=""
      set +e
      CONDA_BASE_PATH_FOR_HOOK=$(${CONDA_CMD_PREFIX}conda info --base 2>/dev/null)
      set -e
      if [ -z "$CONDA_BASE_PATH_FOR_HOOK" ]; then
          warning_message "Could not determine Conda base path (even with potential OpenSSL fix). Shell hook initialization might fail or be incomplete."
      fi

      if [ -n "$CONDA_BASE_PATH_FOR_HOOK" ] && [ -f "$CONDA_BASE_PATH_FOR_HOOK/etc/profile.d/conda.sh" ]; then
          # shellcheck source=/dev/null
          source "$CONDA_BASE_PATH_FOR_HOOK/etc/profile.d/conda.sh"
          info_message "Sourced conda.sh from $CONDA_BASE_PATH_FOR_HOOK."
      elif command_exists conda ; then
          info_message "Attempting to initialize conda shell hooks for current script session using '${CONDA_CMD_PREFIX}conda shell.bash hook'..."
          eval "$(${CONDA_CMD_PREFIX}conda shell.bash hook)"
          info_message "Conda shell hooks evaluated."
      else
           warning_message "Could not source conda.sh or evaluate conda shell hooks. Subsequent Conda operations like 'activate' might fail within this script."
      fi

      conda_env_exists=false
      conda_env_list_output_file=$(mktemp)
      set +e
      # shellcheck disable=SC2091
      $(echo "${CONDA_CMD_PREFIX}conda env list" | bash) > "$conda_env_list_output_file" 2>&1
      conda_env_list_exit_code=$?
      set -e

      if grep -Eq "^${CONDA_ENV_NAME}[[:space:]]+" "$conda_env_list_output_file"; then
          conda_env_exists=true
      fi
      rm -f "$conda_env_list_output_file"

      if [ $conda_env_list_exit_code -ne 0 ] && ! $conda_env_exists ; then
           warning_message "'${CONDA_CMD_PREFIX}conda env list' failed (exit code $conda_env_list_exit_code) or did not find the environment. This could be an OpenSSL issue or other Conda problem."
      fi

      if $conda_env_exists; then
        read -r -p "Conda environment '$CONDA_ENV_NAME' already exists. Use it? (Answering 'n' will let you choose a different name or try system Python) [Y/n]: " use_existing_conda_answer
        use_existing_conda_answer_lower=$(echo "$use_existing_conda_answer" | tr '[:upper:]' '[:lower:]')
        if [[ "$use_existing_conda_answer_lower" == "n" || "$use_existing_conda_answer_lower" == "no" ]]; then
          info_message "Skipping Conda setup with name '$CONDA_ENV_NAME'. Will try fallback methods if applicable."
        else
          info_message "Will attempt to use existing Conda environment '$CONDA_ENV_NAME'."
          ENV_SETUP_METHOD="conda"
        fi
      else
        info_message "Creating new Conda environment '$CONDA_ENV_NAME' with Python $PYTHON_VERSION_FOR_CONDA..."
        create_cmd_status=0
        create_cmd_output_file=$(mktemp)
        set +e
        # shellcheck disable=SC2091
        $(echo "${CONDA_CMD_PREFIX}conda create -y -n \"$CONDA_ENV_NAME\" python=\"$PYTHON_VERSION_FOR_CONDA\"" | bash) > "$create_cmd_output_file" 2>&1
        create_cmd_status=$?
        set -e

        if [ $create_cmd_status -ne 0 ]; then
          cat "$create_cmd_output_file" >&2
          rm -f "$create_cmd_output_file"
          error_exit "Failed to create Conda environment '$CONDA_ENV_NAME' (exit code $create_cmd_status)." \
                     "Check Conda installation, network, Python version '$PYTHON_VERSION_FOR_CONDA', and review OpenSSL warnings or other errors above."
        fi
        rm -f "$create_cmd_output_file"
        info_message "Conda environment '$CONDA_ENV_NAME' created."
        ENV_SETUP_METHOD="conda"
      fi

      if [ "$ENV_SETUP_METHOD" == "conda" ]; then
          CHOSEN_PYTHON_FOR_DISPLAY="Python $PYTHON_VERSION_FOR_CONDA (in Conda env '$CONDA_ENV_NAME')"
          HELPER_ACTIVATION_SCRIPT_NAME="activate_project_env.sh"
          info_message "Creating helper activation script: '$HELPER_ACTIVATION_SCRIPT_NAME'"
          echo "#!/bin/bash" > "$HELPER_ACTIVATION_SCRIPT_NAME"
          echo "# This script activates the Conda environment '$CONDA_ENV_NAME' for this project." >> "$HELPER_ACTIVATION_SCRIPT_NAME"
          echo "# To use it in your current shell: source ./$HELPER_ACTIVATION_SCRIPT_NAME" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
          if [ "$CONDA_NEEDS_OPENSSL_FIX" = true ]; then
            echo "" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
            echo "# Note: Your Conda installation might require CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
            echo "# If 'conda activate' (directly or via this script) fails due to OpenSSL errors," >> "$HELPER_ACTIVATION_SCRIPT_NAME"
            echo "# try running this in your terminal first before sourcing/activating:" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
            echo "# export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
            echo "" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
          fi
          echo "conda activate \"$CONDA_ENV_NAME\"" >> "$HELPER_ACTIVATION_SCRIPT_NAME"
          chmod +x "$HELPER_ACTIVATION_SCRIPT_NAME"
          ACTIVATION_COMMAND_FOR_USER="source ./$HELPER_ACTIVATION_SCRIPT_NAME  (or directly: conda activate \"$CONDA_ENV_NAME\")"
          if [ "$CONDA_NEEDS_OPENSSL_FIX" = true ]; then
            ACTIVATION_COMMAND_FOR_USER="$ACTIVATION_COMMAND_FOR_USER (NOTE: Your Conda may need 'export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1' in your shell for activation to work reliably)"
          fi
      fi
    else
      info_message "Skipping Conda setup by user choice."
    fi
  fi
fi


# --- Attempt 3: system python + venv (fallback) ---
if [ "$ENV_SETUP_METHOD" == "none" ]; then
  info_message "Using system Python to create a standard venv."
  if [ -n "$PYTHON_VERSION_FROM_FILE" ] && [ "$PYTHON_VERSION_FROM_FILE" == "system" ]; then
      info_message "'.python-version' specifies 'system'."
  elif [ -n "$PYTHON_VERSION_FROM_FILE" ]; then
      warning_message "'.python-version' specified '$PYTHON_VERSION_FROM_FILE' but pyenv/conda was not used/successful. Falling back to system Python search."
  fi

  if command_exists "python3"; then
    PYTHON_EXECUTABLE_FOR_VENV_CREATION=$(command -v python3)
  elif command_exists "python"; then
    PYTHON_EXECUTABLE_FOR_VENV_CREATION=$(command -v python)
    SYSTEM_PYTHON_VERSION=$("$PYTHON_EXECUTABLE_FOR_VENV_CREATION" -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo "unknown")
    if [ "$SYSTEM_PYTHON_VERSION" -eq 2 ]; then warning_message "System 'python' is Python 2. Modern projects usually require Python 3."; fi
  else
    error_exit "No system Python (python3 or python) found in your system's PATH." "Please install Python 3, or ensure 'python3' or 'python' is accessible."
  fi

  info_message "Using system Python: $PYTHON_EXECUTABLE_FOR_VENV_CREATION"
  if ! "$PYTHON_EXECUTABLE_FOR_VENV_CREATION" -m venv "$VENV_PATH_FOR_SCRIPT"; then
    error_exit "Failed to create venv using system Python ($PYTHON_EXECUTABLE_FOR_VENV_CREATION)." \
               "Ensure 'venv' module is available for this Python (e.g., install 'python3-venv' on Debian/Ubuntu, or 'python3-virtualenv' on some systems)."
  fi
  ENV_SETUP_METHOD="venv"
  CHOSEN_PYTHON_FOR_DISPLAY="$PYTHON_EXECUTABLE_FOR_VENV_CREATION (system)"
  ACTIVATION_COMMAND_FOR_USER="source \"$VENV_PATH_FOR_SCRIPT/bin/activate\""
fi

if [ "$ENV_SETUP_METHOD" == "none" ]; then
    error_exit "Failed to set up any Python environment (pyenv, conda, or system venv). Critical error."
fi
info_message "Python environment setup method: $ENV_SETUP_METHOD"
if [ "$ENV_SETUP_METHOD" == "conda" ]; then
    info_message "Conda environment name: '$CONDA_ENV_NAME'"
else
    info_message "Local venv directory: '$VENV_PATH_FOR_SCRIPT'"
fi
info_message "Effective Python for environment: $CHOSEN_PYTHON_FOR_DISPLAY"
echo

# --- Activate environment and install dependencies ---
section "Dependency Installation"

if [ "$ENV_SETUP_METHOD" == "conda" ]; then
    if [ "$CONDA_NEEDS_OPENSSL_FIX" = true ]; then
        export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1
        info_message "CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 has been exported for this script session to aid Conda activation."
    fi

    CONDA_BASE_PATH_FOR_ACTIVATION=""
    set +e
    CONDA_BASE_PATH_FOR_ACTIVATION=$(${CONDA_CMD_PREFIX}conda info --base 2>/dev/null)
    set -e
    if [ -z "$CONDA_BASE_PATH_FOR_ACTIVATION" ]; then
        warning_message "Could not determine Conda base path for activation (even with potential OpenSSL fix). Shell hook may fail or be incomplete."
    fi

    if [ -n "$CONDA_BASE_PATH_FOR_ACTIVATION" ] && [ -f "$CONDA_BASE_PATH_FOR_ACTIVATION/etc/profile.d/conda.sh" ]; then
        # shellcheck source=/dev/null
        source "$CONDA_BASE_PATH_FOR_ACTIVATION/etc/profile.d/conda.sh"
    elif command_exists conda ; then
        eval "$(${CONDA_CMD_PREFIX}conda shell.bash hook)"
    else
        error_exit "Cannot find conda.sh or generate conda shell hooks. Conda activation will likely fail for the script."
    fi

    if ! conda activate "$CONDA_ENV_NAME"; then
        error_exit "Failed to execute 'conda activate \"$CONDA_ENV_NAME\"' for this script's session." \
                   "Ensure Conda is initialized for your shell ('conda init <your_shell>'). If OpenSSL issue persisted, try setting CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 manually in your terminal and re-run this script."
    fi

    if [ -z "${CONDA_PREFIX:-}" ] || [ "${CONDA_SHLVL:-0}" -lt 1 ]; then
        error_exit "Conda environment '$CONDA_ENV_NAME' did not activate properly for the script. CONDA_PREFIX is not set or SHLVL is < 1."
    fi
    current_active_conda_env_name=$(basename "${CONDA_PREFIX:-unknown_prefix}")

    if [ "$current_active_conda_env_name" != "$CONDA_ENV_NAME" ]; then
        actual_conda_base_dir_for_check=$(${CONDA_CMD_PREFIX}conda info --base 2>/dev/null || echo "unknown_base")
        if ! ([ "$CONDA_ENV_NAME" == "base" ] && [ "$CONDA_PREFIX" == "$actual_conda_base_dir_for_check" ]); then
            warning_message "Activated Conda environment name ('$current_active_conda_env_name') or path does not strictly match expected ('$CONDA_ENV_NAME'). Prefix: ${CONDA_PREFIX:-not set}. This might be okay if using a custom envs_dirs path or if '$CONDA_ENV_NAME' is base."
        fi
    fi
    info_message "Conda environment '$CONDA_ENV_NAME' activated for this script's session (CONDA_PREFIX: $CONDA_PREFIX)."

elif [ "$ENV_SETUP_METHOD" == "venv" ]; then
    if [ ! -f "$VENV_PATH_FOR_SCRIPT/bin/activate" ]; then
        error_exit "venv activation script not found at '$VENV_PATH_FOR_SCRIPT/bin/activate'. Creation might have failed."
    fi
    # shellcheck source=/dev/null
    source "$VENV_PATH_FOR_SCRIPT/bin/activate"
    if [ -z "${VIRTUAL_ENV:-}" ]; then
        error_exit "Failed to activate venv. 'VIRTUAL_ENV' variable was not set after sourcing activate script."
    fi
    info_message "venv environment activated (VIRTUAL_ENV is '$VIRTUAL_ENV')."
fi

if ! command_exists "pip"; then
    error_exit "'pip' command not found after activating environment. Environment might be corrupted or PATH is incorrect."
fi
info_message "'pip' command is available in the active environment: $(command -v pip)"

pip_upgrade_log_file="pip_upgrade.log"
info_message "Upgrading pip in the active environment (details/errors will be logged to '$pip_upgrade_log_file')..."
if ! python -m pip install --upgrade pip 2> "$pip_upgrade_log_file"; then
  warning_message "Failed to upgrade pip. Continuing with the current version of pip. Check '$pip_upgrade_log_file' for details if issues persist."
else
  significant_output=false
  if [ -s "$pip_upgrade_log_file" ]; then
      if [ "$(grep -Evc 'Requirement already satisfied|Requirement already up-to-date' "$pip_upgrade_log_file")" -gt 0 ]; then
          significant_output=true
      fi
  fi

  if $significant_output; then
    info_message "pip upgrade completed. Some messages from pip were logged to '$pip_upgrade_log_file'."
  else
    rm -f "$pip_upgrade_log_file"
    info_message "pip is up to date or upgrade completed successfully without significant output."
  fi
fi

readonly REQUIREMENTS_FILE="requirements.txt"

info_message "Validating and sanitizing '$REQUIREMENTS_FILE'..."

if [ -f "$REQUIREMENTS_FILE" ]; then
    temp_req_file=$(mktemp)
    grep -E '(^#.*$)|(^\s*$)|(^[a-zA-Z0-9_.-]+)' "$REQUIREMENTS_FILE" > "$temp_req_file"

    if ! diff -q "$REQUIREMENTS_FILE" "$temp_req_file" &>/dev/null; then
        info_message "Original '$REQUIREMENTS_FILE' was invalid or incomplete. It has been sanitized and updated."
        mv "$temp_req_file" "$REQUIREMENTS_FILE"
    else
        rm "$temp_req_file"
    fi
fi

# Install from requirements.txt if it has content
if [ -s "$REQUIREMENTS_FILE" ]; then
  pip_req_install_log_file="pip_requirements_install.log"
  info_message "Installing dependencies from '$REQUIREMENTS_FILE' (details/errors will be logged to '$pip_req_install_log_file')..."
  dependency_failure_hint="Detailed error output from pip has been saved to '$pip_req_install_log_file'.
Common reasons: typos in '$REQUIREMENTS_FILE', network issues, package not found on PyPI, or missing system build dependencies (like compilers or dev headers for packages that build from source)."
  if ! python -m pip install -r "$REQUIREMENTS_FILE" 2> "$pip_req_install_log_file"; then
    error_exit "Failed to install dependencies from '$REQUIREMENTS_FILE'." "$dependency_failure_hint"
  else
    rm -f "$pip_req_install_log_file"
    info_message "Dependencies installed successfully from '$REQUIREMENTS_FILE'."
  fi
else
  info_message "'$REQUIREMENTS_FILE' is empty or not found."
  read -r -p "Do you want to auto-detect dependencies using pipreqs? (yes/no): " yn_pipreqs >&2
  if [[ "$yn_pipreqs" =~ ^[Yy](es)?$ ]]; then
    info_message "Installing pipreqs..."
    if ! python -m pip install pipreqs 2>/dev/null; then
      warning_message "Failed to install pipreqs. Skipping dependency detection."
    else
      info_message "Generating requirements.txt from your code..."
      pipreqs . --force --ignore .venv,venv,tests,docs,build,dist,.git,.idea,.vscode,__pycache__ 2>&1 | tee pipreqs.log
      if [ -s "$REQUIREMENTS_FILE" ]; then
        info_message "Generated '$REQUIREMENTS_FILE' successfully."
        cat "$REQUIREMENTS_FILE"
        info_message "Installing detected dependencies..."
        pip_req_install_log_file="pip_requirements_install.log"
        if ! python -m pip install -r "$REQUIREMENTS_FILE" 2> "$pip_req_install_log_file"; then
          warning_message "Some dependencies may have failed to install. Check '$pip_req_install_log_file' for details."
        else
          info_message "Dependencies installed successfully."
        fi
      else
        warning_message "pipreqs could not detect any dependencies."
      fi
    fi
  fi
fi
echo


# --- Optional Git Repository Initialization and .gitignore creation ---
section "Git Setup"
GIT_INITIALIZED_BY_SCRIPT=false
current_branch_name=""
gitignore_venv_dir_param=""
if [ "$ENV_SETUP_METHOD" == "venv" ]; then
    gitignore_venv_dir_param="$VENV_PATH_FOR_SCRIPT"
fi

if ! command_exists "git"; then
    warning_message "'git' command not found. Skipping Git repository initialization and .gitignore creation."
else
    if [ -d ".git" ]; then
        info_message "This directory is already a Git repository ('.git' folder found)."
        create_gitignore_if_needed "$gitignore_venv_dir_param"
    else
        git_init_answer=""
        read -r -p "Do you want to initialize a Git repository in this directory? [y/N]: " git_init_answer
        git_init_answer_lower=$(echo "$git_init_answer" | tr '[:upper:]' '[:lower:]')

        if [[ "$git_init_answer_lower" == "y" || "$git_init_answer_lower" == "yes" ]]; then
            info_message "Initializing Git repository..."
            if git init; then
                info_message "Git repository initialized."
                GIT_INITIALIZED_BY_SCRIPT=true

                info_message "Attempting to set default branch to 'main'..."
                if ! current_branch_name=$(git symbolic-ref --short HEAD 2>/dev/null); then
                    if git checkout -b main &>/dev/null; then
                        info_message "Created and switched to new branch 'main'."
                    else
                        warning_message "Could not determine initial branch name automatically, nor create 'main'. Default branch may not be 'main'."
                    fi
                elif [ "$current_branch_name" != "main" ]; then
                    info_message "Initial branch is '$current_branch_name'. Renaming to 'main'..."
                    if git branch -m "$current_branch_name" main; then
                        info_message "Successfully renamed initial branch to 'main'."
                    else
                        warning_message "Failed to rename initial branch to 'main'. Manual check needed: git branch -m $current_branch_name main"
                    fi
                else
                    info_message "Initial branch is already 'main'."
                fi

                create_gitignore_if_needed "$gitignore_venv_dir_param"
            else
                error_exit "Failed to initialize Git repository." \
                           "Check 'git' configuration or directory permissions."
            fi
        else
            info_message "Skipping Git repository initialization by user choice."
        fi
    fi
fi
echo

# --- Completion Summary ---
section "Complete"
success_message "Project setup complete!"
echo ""
info_message "Environment setup method: $ENV_SETUP_METHOD"
if [ "$ENV_SETUP_METHOD" == "conda" ]; then
    info_message "Conda environment name: '$CONDA_ENV_NAME'"
    if [ "$CONDA_NEEDS_OPENSSL_FIX" = true ]; then
        warning_message "NOTE: Your Conda installation showed signs of the OpenSSL 3.0 legacy provider issue."
        warning_message "This script attempted to work around it for its own execution."
        warning_message "For reliable Conda use outside this script, you may need to permanently set:"
        warning_message "export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1"
        warning_message "in your shell's startup file (e.g., ~/.bashrc or ~/.zshrc) and open a new terminal."
    fi
else
    info_message "Local venv directory: '$VENV_PATH_FOR_SCRIPT'"
fi
info_message "Effective Python for environment: $CHOSEN_PYTHON_FOR_DISPLAY"

if [ -f "$REQUIREMENTS_FILE" ] && [ -s "$REQUIREMENTS_FILE" ]; then info_message "Dependencies from '$REQUIREMENTS_FILE' were installed.";
elif [ -f "$REQUIREMENTS_FILE" ]; then info_message "'$REQUIREMENTS_FILE' empty, no dependencies installed from it.";
else info_message "No '$REQUIREMENTS_FILE' found, no dependencies installed from it."; fi

if $GIT_INITIALIZED_BY_SCRIPT; then info_message "New Git repository initialized.";
elif [ -d ".git" ]; then info_message "Project is already a Git repository.";
elif command_exists "git"; then info_message "Git repository not initialized by script.";
else info_message "'git' not found; Git operations skipped."; fi

echo ""
info_message "To activate the environment in your current terminal session for development, run:"
info_message "$ACTIVATION_COMMAND_FOR_USER"

exit 0
