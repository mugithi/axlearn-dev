#!/bin/bash
set -euo pipefail

# --- Configuration Variables (with defaults) ---
# These can be overridden by environment variables if needed.

# JobSet and Pod identification
TARGET_JOBSET_NAME="${TARGET_JOBSET_NAME:-isaack}" # Name of the target JobSet
REPLICATED_JOB_NAME_IN_JOBSET="${REPLICATED_JOB_NAME_IN_JOBSET:-worker}" # Name of the ReplicatedJob within the JobSet (often 'worker' or 'train')

# gRPC call details
POD_GRPC_PORT="${POD_GRPC_PORT:-8081}" # The gRPC port exposed by the pod
GRPC_SERVICE="${GRPC_SERVICE:-xla.megascale.runtime.MegascaleDebugService}" # The gRPC service name

# Payload for SetImpairments to drop 50th percentile requests (JSON format for grpcurl)
# User request: 'communication_impairments{delay_profile{points{percentile:50 drop:true}}}'
# JSON equivalent:
DEFAULT_SET_IMPAIRMENTS_PAYLOAD='{"communication_impairments": {"delay_profile": {"points": {"percentile": 50, "drop": true}}}}'
SET_IMPAIRMENTS_PAYLOAD="$DEFAULT_SET_IMPAIRMENTS_PAYLOAD" # Ensures script's JSON payload is used

# GKE cluster credentials configuration
PERFORM_GET_CREDENTIALS="${PERFORM_GET_CREDENTIALS:-true}" # Set to false to skip 'gcloud container clusters get-credentials'
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-your-gke-cluster-name-here}" # REQUIRED: Your GKE cluster name
TARGET_ZONE="${TARGET_ZONE:-your-gke-cluster-zone-here}" # REQUIRED: Your GKE cluster zone, e.g., us-central1-a
# PROJECT_ID will be attempted to be fetched from gcloud config.

# --- End Configuration Variables ---

# --- grpcurl Download Logic (from user provided script) ---
# This section ensures grpcurl is available.
if [ ! -f "$(pwd)/grpcurl" ]; then
  echo "grpcurl not found locally. Attempting to download..."
  GRPCURL_DOWNLOAD_DIR=$(mktemp -d)
  ORIGINAL_PWD=$(pwd) # Save current directory to return to it

  cd "$GRPCURL_DOWNLOAD_DIR" || { echo "ERROR: Failed to cd to temporary download directory. Exiting."; exit 1; }

  # Detect OS and architecture for grpcurl
  OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH_TYPE=$(uname -m)
  GRPCURL_ARCH="" # Initialize GRPCURL_ARCH

  case $ARCH_TYPE in
    x86_64) GRPCURL_ARCH="x86_64" ;;
    aarch64 | arm64) GRPCURL_ARCH="arm64" ;;
    *)
      echo "ERROR: Unsupported architecture '$ARCH_TYPE' for grpcurl download. Exiting."
      cd "$ORIGINAL_PWD" # Go back before exiting
      rm -rf "$GRPCURL_DOWNLOAD_DIR" # Clean up
      exit 1
      ;;
  esac

  GRPCURL_VERSION="1.8.9" # Using a common recent version; can be adjusted.
  GRPCURL_TAR_NAME="grpcurl_${GRPCURL_VERSION}_${OS_TYPE}_${GRPCURL_ARCH}.tar.gz"
  GRPCURL_DOWNLOAD_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${GRPCURL_TAR_NAME}"

  echo "Downloading $GRPCURL_DOWNLOAD_URL..."
  if curl -sSL "$GRPCURL_DOWNLOAD_URL" -o "$GRPCURL_TAR_NAME"; then
    echo "Extracting grpcurl from $GRPCURL_TAR_NAME..."
    tar -xzf "$GRPCURL_TAR_NAME" grpcurl
    if [ -f grpcurl ]; then
      echo "Moving grpcurl to $ORIGINAL_PWD/grpcurl"
      mv grpcurl "$ORIGINAL_PWD/grpcurl"
      chmod +x "$ORIGINAL_PWD/grpcurl"
    else
      echo "ERROR: Failed to download or extract grpcurl (grpcurl binary not found in tarball). Exiting."
      cd "$ORIGINAL_PWD"
      rm -rf "$GRPCURL_DOWNLOAD_DIR"
      exit 1
    fi
  else
    echo "ERROR: Failed to download grpcurl (curl command failed). Exiting."
    cd "$ORIGINAL_PWD"
    rm -rf "$GRPCURL_DOWNLOAD_DIR"
    exit 1
  fi
  echo "grpcurl downloaded and extracted successfully to $ORIGINAL_PWD/grpcurl."
  cd "$ORIGINAL_PWD"
  rm -rf "$GRPCURL_DOWNLOAD_DIR"
else
  echo "grpcurl already exists locally at $(pwd)/grpcurl."
fi
LOCAL_GRPCURL_PATH="$(pwd)/grpcurl"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")

if [ "$PERFORM_GET_CREDENTIALS" = true ]; then
  if [ -n "$GKE_CLUSTER_NAME" ] && [ -n "$TARGET_ZONE" ] && [ -n "$PROJECT_ID" ]; then
    CLUSTER_REGION=${TARGET_ZONE%-*}
    echo "Attempting to get credentials for GKE cluster '$GKE_CLUSTER_NAME' in region '$CLUSTER_REGION' (derived from zone '$TARGET_ZONE') for project '$PROJECT_ID'..."
    if gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$CLUSTER_REGION" --project "$PROJECT_ID"; then
      echo "Successfully fetched credentials for cluster '$GKE_CLUSTER_NAME'."
    else
      echo "ERROR: Failed to get credentials for cluster '$GKE_CLUSTER_NAME'. Subsequent kubectl commands might fail."
      exit 1
    fi
  elif [ -z "$PROJECT_ID" ]; then
    echo "WARNING: GCP Project ID could not be determined. Skipping get-credentials. Please configure via 'gcloud config set project YOUR_PROJECT_ID'."
  elif [ "$GKE_CLUSTER_NAME" = "your-gke-cluster-name-here" ] || [ "$TARGET_ZONE" = "your-gke-cluster-zone-here" ]; then
    echo "ERROR: GKE_CLUSTER_NAME or TARGET_ZONE is set to a placeholder value."
    echo "Please edit the script to provide actual values for GKE_CLUSTER_NAME ('$GKE_CLUSTER_NAME') and TARGET_ZONE ('$TARGET_ZONE'), or set them as environment variables."
    echo "Skipping get-credentials due to placeholder values."
    # Optionally, exit here if these are strictly required and placeholders are not acceptable for proceeding
    # exit 1
  else
    echo "WARNING: Missing GKE_CLUSTER_NAME ('$GKE_CLUSTER_NAME'), TARGET_ZONE ('$TARGET_ZONE'), or PROJECT_ID ('$PROJECT_ID') is empty. Skipping get-credentials."
    echo "Please ensure these variables are set with valid values if you need to fetch GKE credentials."
  fi
else
  echo "Skipping GKE cluster credentials fetching (PERFORM_GET_CREDENTIALS is not 'true')."
fi

FIRST_K8S_JOB_NAME="${TARGET_JOBSET_NAME}-${REPLICATED_JOB_NAME_IN_JOBSET}-0"
echo "Identifying first pod of Kubernetes Job: $FIRST_K8S_JOB_NAME"

TARGET_POD_NAME=$(kubectl get pods -l job-name="$FIRST_K8S_JOB_NAME" --sort-by=.metadata.name --no-headers=true -o=custom-columns=NAME:.metadata.name | head -n 1)

if [ -z "$TARGET_POD_NAME" ]; then
  echo "ERROR: No pods found for Kubernetes Job '$FIRST_K8S_JOB_NAME'."
  echo "This job might not have started, might have already completed/failed, or TARGET_JOBSET_NAME/REPLICATED_JOB_NAME_IN_JOBSET might be incorrect."
  echo "Please check the status of JobSet '$TARGET_JOBSET_NAME' and its jobs using 'kubectl get jobset $TARGET_JOBSET_NAME' and 'kubectl get jobs -l jobset.sigs.k8s.io/jobset-name=$TARGET_JOBSET_NAME'."
  exit 1
fi

echo "Targeting specific pod: $TARGET_POD_NAME (from K8s Job $FIRST_K8S_JOB_NAME)"

TARGET_LOCAL_PORT=10000

command_sequence_for_pod() {
  local local_pod_name=$1
  local local_target_local_port=$2
  local local_pod_grpc_port=$3
  local local_grpcurl_path=$4
  local local_grpc_service=$5
  local local_set_impairments_payload=$6

  echo
  echo "--- Processing pod: $local_pod_name ---"
  echo "Setting up port-forward: localhost:$local_target_local_port -> pod $local_pod_name (port $local_pod_grpc_port)..."

  kubectl port-forward "pod/$local_pod_name" "$local_target_local_port:$local_pod_grpc_port" &
  local port_forward_pid=$!

  trap "echo 'Cleaning up port-forward PID $port_forward_pid for $local_pod_name...'; kill $port_forward_pid 2>/dev/null; wait $port_forward_pid 2>/dev/null || true; trap - EXIT INT TERM" EXIT INT TERM

  echo "Waiting for port-forward (PID $port_forward_pid) to establish (giving it 5 seconds)..."
  sleep 5

  if ! ps -p $port_forward_pid > /dev/null; then
    echo "ERROR: Port-forwarding failed to start or exited prematurely for pod $local_pod_name."
    exit 1
  fi
  echo "Port-forward established."

  echo "[Pod: $local_pod_name] Calling GetDebugInfo (before SetImpairments) via localhost:$local_target_local_port..."
  "$local_grpcurl_path" -plaintext -emit-defaults "localhost:$local_target_local_port" "${local_grpc_service}.GetDebugInfo" || echo "WARNING: GetDebugInfo (before) failed for $local_pod_name. Continuing..."

  echo "[Pod: $local_pod_name] Calling SetImpairments via localhost:$local_target_local_port..."
  # Added debug line below
  echo "DEBUG: Using payload: '$local_set_impairments_payload' with grpcurl: '$local_grpcurl_path'"
  echo "Payload: $local_set_impairments_payload" # This line was already in user's provided script
  "$local_grpcurl_path" -plaintext -d "$local_set_impairments_payload" "localhost:$local_target_local_port" "${local_grpc_service}.SetImpairments" || echo "WARNING: SetImpairments failed for $local_pod_name. Continuing..."

  echo "[Pod: $local_pod_name] SetImpairments call completed. Waiting for ~5 minutes as requested..."
  sleep 300

  echo "[Pod: $local_pod_name] Calling GetDebugInfo (after SetImpairments and 5 min wait) via localhost:$local_target_local_port..."
  "$local_grpcurl_path" -plaintext -emit-defaults "localhost:$local_target_local_port" "${local_grpc_service}.GetDebugInfo" || echo "WARNING: GetDebugInfo (after) failed for $local_pod_name."

  echo "Operations complete for $local_pod_name. Killing port-forward PID $port_forward_pid..."
  kill "$port_forward_pid" 2>/dev/null
  wait "$port_forward_pid" 2>/dev/null || true
  trap - EXIT INT TERM
  echo "--- Finished processing pod: $local_pod_name ---"
}

( command_sequence_for_pod "$TARGET_POD_NAME" "$TARGET_LOCAL_PORT" "$POD_GRPC_PORT" "$LOCAL_GRPCURL_PATH" "$GRPC_SERVICE" "$SET_IMPAIRMENTS_PAYLOAD" )

echo
echo "Script finished."
