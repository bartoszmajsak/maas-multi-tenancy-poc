#!/bin/bash

set -euo pipefail

bold='\033[1m'
normal='\033[0m'
underline='\033[4m'

# Track created params.env files for cleanup
CREATED_PARAMS_FILES=()

# Copy params.env.example files to params.env for CI validation
setup_params_env() {
    local project_root="$1"
    
    while IFS= read -r -d '' example_file; do
        local params_file="${example_file%.example}"
        if [[ ! -f "$params_file" ]]; then
            cp "$example_file" "$params_file"
            CREATED_PARAMS_FILES+=("$params_file")
        fi
    done < <(find "$project_root" -name "params.env.example" -type f -print0)
}

# Clean up generated params.env files
cleanup_params_env() {
    for params_file in "${CREATED_PARAMS_FILES[@]}"; do
        rm -f "$params_file"
    done
}

is_kustomize_component() {
    local kustomization_file="$1"
    grep -q "^kind: Component" "$kustomization_file" 2>/dev/null
}

validate_kustomization() {
    local kustomization_file="$1"
    local project_root="${2:-$(git rev-parse --show-toplevel)}"
    
    local dir=$(dirname "$kustomization_file")
    local relative_path=${kustomization_file#"$project_root/"}
    local message="${bold}Validating${normal} ${underline}$relative_path${normal}"
    
    # Skip Component files - they can't be built standalone, they must be included via 'components:' in another Kustomization
    if is_kustomize_component "$kustomization_file"; then
        echo -e "⏭️  ${bold}Skipping${normal} ${underline}$relative_path${normal} (Component - cannot be validated standalone)"
        return 0
    fi
    
    echo -n -e "⏳ ${message}"
    if output=$(kustomize build --stack-trace "$dir" 2>&1); then
        echo -e "\r✅ ${message}"
        return 0
    else
        echo -e "\r❌ ${message}"
        echo "$output"
        return 1
    fi
}

validate_all() {
    local project_root="${1:-$(git rev-parse --show-toplevel)}"
    local exit_code=0
    
    while IFS= read -r -d '' kustomization_file; do
        if ! validate_kustomization "$kustomization_file" "$project_root"; then
            exit_code=1
        fi
    done < <(find "$project_root" -name "kustomization.yaml" -type f -print0)
    
    return $exit_code
}

# When script is not sourced, but directly invoked, validate all manifests in the project
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    PROJECT_ROOT=$(git rev-parse --show-toplevel)
    
    # Setup params.env from .example files for CI validation
    setup_params_env "$PROJECT_ROOT"
    trap cleanup_params_env EXIT
    
    validate_all "$PROJECT_ROOT"
    exit $?
fi
