#!/bin/bash
set -e
set -o pipefail

# --- Configuration ---
# Script Behavior
PERFORM_GET_CREDENTIALS=true     # Set to true to fetch GKE cluster credentials

# GKE Cluster Details (for get-credentials)
GKE_CLUSTER_NAME="isaack-axlearn" # Name of your GKE cluster
TARGET_ZONE="us-east5-b"          # Zone of your GKE cluster (used to derive region)

# Pod Selection (for targeting the gRPC calls)
TARGET_JOBSET_NAME="isaack"                 # Name of your JobSet
REPLICATED_JOB_NAME_IN_JOBSET="job"         # The 'Name' of the ReplicatedJob within the JobSet spec
# The script will find the first pod of the K8s job: ${TARGET_JOBSET_NAME}-${REPLICATED_JOB_NAME_IN_JOBSET}-0

# gRPC Call Details
GRPCURL_VERSION="1.9.1"
POD_GRPC_PORT="8081" # Port on the pod where the gRPC service is listening
GRPC_SERVICE="xla.megascale.runtime.MegascaleDebugService"
# Payload for SetImpairments - ensure quotes are handled correctly for shell
# SET_IMPAIRMENTS_PAYLOAD='{ "communication_impairments": { "delay_profile": { "points": { "percentile": 50, "drop": true } } } }'
SET_IMPAIRMENTS_PAYLOAD='{ "communication_impairments": { "d2h_impairment": {"drop_all": true}}}'

# --- Script ---

echo "Starting script to perform gRPC calls on a specific pod via kubectl port-forward..."

# 1. Install grpcurl locally if not already present
echo "Setting up grpcurl..."
mkdir -p "$HOME/grpcurl-${GRPCURL_VERSION}"
cd "$HOME/grpcurl-${GRPCURL_VERSION}"

if [ ! -f ./grpcurl ]; then
  echo "grpcurl not found locally, downloading..."
  wget "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" -O "grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"
  tar -zxvf "grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" grpcurl
  if [ ! -f ./grpcurl ]; then
    echo "ERROR: Failed to download or extract grpcurl. Exiting."
    exit 1
  fi
  echo "grpcurl downloaded and extracted."
else
  echo "grpcurl already exists locally."
fi
LOCAL_GRPCURL_PATH="$(pwd)/grpcurl"
cd - > /dev/null # Go back to the original directory, suppress output

# Attempt to get Project ID from gcloud config - needed for get-credentials
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

# --- Get GKE Cluster Credentials (if enabled) ---
if [ "$PERFORM_GET_CREDENTIALS" = true ]; then
  if [ -n "$GKE_CLUSTER_NAME" ] && [ -n "$TARGET_ZONE" ] && [ -n "$PROJECT_ID" ]; then
    CLUSTER_REGION=${TARGET_ZONE%-*} # Derive region from zone (e.g., us-east5-b -> us-east5)
    echo "Attempting to get credentials for GKE cluster '$GKE_CLUSTER_NAME' in region '$CLUSTER_REGION' (derived from zone '$TARGET_ZONE') for project '$PROJECT_ID'..."
    gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$CLUSTER_REGION" --project "$PROJECT_ID"
    if [ $? -eq 0 ]; then
      echo "Successfully fetched credentials for cluster '$GKE_CLUSTER_NAME'."
    else
      echo "ERROR: Failed to get credentials for cluster '$GKE_CLUSTER_NAME'. Subsequent kubectl commands might fail."
      # set -e will cause exit
    fi
  elif [ -z "$PROJECT_ID" ]; then
    echo "WARNING: GCP Project ID could not be determined. Skipping get-credentials. Please configure via 'gcloud config set project YOUR_PROJECT_ID'."
  else
    echo "WARNING: Missing GKE_CLUSTER_NAME ('$GKE_CLUSTER_NAME'), TARGET_ZONE ('$TARGET_ZONE'), or PROJECT_ID. Skipping get-credentials."
  fi
else
  echo "Skipping GKE cluster credentials fetching (PERFORM_GET_CREDENTIALS is not true)."
fi
# --- End Get GKE Cluster Credentials ---

# Construct the name of the Kubernetes Job (0-indexed)
# Convention: jobsetname-replicatedjobname-0
TARGET_K8S_JOB_NAME="${TARGET_JOBSET_NAME}-${REPLICATED_JOB_NAME_IN_JOBSET}-0"
echo "Identifying second pod of Kubernetes Job: $TARGET_K8S_JOB_NAME"

# Fetch the name of the second pod for this specific Kubernetes Job
# Pods created by a Job have a 'job-name' label matching the K8s Job name.
# We sort by name and then select the second pod (e.g., the one with index 1 like '...-0-1-...').
TARGET_POD_NAME=$(kubectl get pods -l job-name="$TARGET_K8S_JOB_NAME" --sort-by=.metadata.name --no-headers=true -o=custom-columns=NAME:.metadata.name | sed -n '2p')

if [ -z "$TARGET_POD_NAME" ]; then
  echo "ERROR: No second pod found for Kubernetes Job '$TARGET_K8S_JOB_NAME'. This job might not have started, might have already completed/failed, or might not have a second pod."
  echo "Please check the status of JobSet '$TARGET_JOBSET_NAME' and its jobs, and ensure at least two pods exist for Job '$TARGET_K8S_JOB_NAME'."
  exit 1
fi

echo "Targeting specific pod: $TARGET_POD_NAME (from K8s Job $TARGET_K8S_JOB_NAME)"

# Define a fixed local port for the single target pod
TARGET_LOCAL_PORT=10000

command_sequence_for_pod() {
  local_pod_name=$1
  local_target_local_port=$2
  local_pod_grpc_port=$3
  local_grpcurl_path=$4
  local_grpc_service=$5
  local_set_impairments_payload=$6

  echo "--- Processing pod: $local_pod_name ---"
  echo "Setting up port-forward: localhost:$local_target_local_port -> pod $local_pod_name (port $local_pod_grpc_port)..."
  kubectl port-forward "pod/$local_pod_name" "$local_target_local_port:$local_pod_grpc_port" &
  port_forward_pid=$!
  # Ensure port-forward is killed when this function/subshell exits or on interrupt
  trap "echo 'Cleaning up port-forward PID $port_forward_pid for $local_pod_name...'; kill $port_forward_pid 2>/dev/null; wait $port_forward_pid 2>/dev/null || true" EXIT INT TERM

  echo "Waiting for port-forward to establish (3 seconds)..."
  sleep 3

  echo "[Pod: $local_pod_name] Calling GetDebugInfo (before SetImpairments) via localhost:$local_target_local_port..."
  "$local_grpcurl_path" -plaintext -emit-defaults "localhost:$local_target_local_port" "${local_grpc_service}.GetDebugInfo" || echo "WARNING: GetDebugInfo (before) failed for $local_pod_name"

  echo "[Pod: $local_pod_name] Calling SetImpairments via localhost:$local_target_local_port..."
  "$local_grpcurl_path" -plaintext -d "$local_set_impairments_payload" "localhost:$local_target_local_port" "${local_grpc_service}.SetImpairments" || echo "WARNING: SetImpairments failed for $local_pod_name"
  sleep 360

  echo "[Pod: $local_pod_name] Calling GetDebugInfo (after SetImpairments) via localhost:$local_target_local_port..."
  "$local_grpcurl_path" -plaintext -emit-defaults "localhost:$local_target_local_port" "${local_grpc_service}.GetDebugInfo" || echo "WARNING: GetDebugInfo (after) failed for $local_pod_name"
  # Trap will handle killing the port_forward_pid
  kill "$port_forward_pid" 2>/dev/null # Attempt to kill, trap will also run
  wait "$port_forward_pid" 2>/dev/null || true # Wait briefly
  trap - EXIT INT TERM # Clear trap for this subshell
  echo "--- Finished processing pod: $local_pod_name ---"
}

# Run the command sequence for the single target pod in a subshell
( command_sequence_for_pod "$TARGET_POD_NAME" "$TARGET_LOCAL_PORT" "$POD_GRPC_PORT" "$LOCAL_GRPCURL_PATH" "$GRPC_SERVICE" "$SET_IMPAIRMENTS_PAYLOAD" )

echo "Script finished."
