#!/bin/bash

# --- Configuration & Defaults ---
# Base name for all resources, derived from USER or BASE_NAME env var
BASE_RESOURCE_NAME="${BASE_NAME:-isaack}"
NUM_SLICES=2 # Default number of logical TPU slices

GKE_CLUSTER_NAME_DEFAULT="${BASE_RESOURCE_NAME}-axlearn"
GCP_REGION="us-east5"
GCP_ZONE="us-east5-b" # Changed from us-east5-a to us-east5-b
CPU_NODE_MACHINE_TYPE="e2-standard-8" # Updated default CPU machine type
CPU_NODE_COUNT_DEFAULT="2" # Default CPU node count
GCP_NETWORK_NAME_DEFAULT="${BASE_RESOURCE_NAME}-net"
GCP_SUBNET_NAME_DEFAULT="${BASE_RESOURCE_NAME}-subnet"
TPU_TOPOLOGY_DEFAULT="4x4" # Fixed topology for each slice
TPU_MACHINE_TYPE_DEFAULT="ct6e-standard-4t" # Fixed machine type for each slice
USE_SPOT_TPU_DEFAULT="true" # Changed to On-Demand VMs for TPUs
NUM_SLICES_DEFAULT="1" # Default number of logical TPU slices (i.e., nodepools)
AXLEARN_CONFIG_PATH_DEFAULT="$HOME/.axlearn.config" # Use $HOME which bash expands
ARTIFACT_REPO_NAME="axlearn"
ARTIFACT_REPO_LOCATION="us"
JOBSET_VERSION="v0.8.1"

# Use environment variables if set, otherwise use defaults
GKE_CLUSTER_NAME="${CLUSTER:-$GKE_CLUSTER_NAME_DEFAULT}"
CPU_NODE_COUNT="${CPU_NODE_COUNT:-$CPU_NODE_COUNT_DEFAULT}" # Allow overriding CPU node count
TPU_TOPOLOGY="${TPU_TOPOLOGY:-$TPU_TOPOLOGY_DEFAULT}" # Allow overriding TPU topology
TPU_MACHINE_TYPE="${TPU_MACHINE_TYPE:-$TPU_MACHINE_TYPE_DEFAULT}" # Allow overriding TPU machine type
USE_SPOT_TPU="${USE_SPOT_TPU:-$USE_SPOT_TPU_DEFAULT}" # Allow overriding Spot usage
NUM_SLICES="${NUM_SLICES:-$NUM_SLICES_DEFAULT}" # Allow overriding number of slices
GCP_NETWORK_NAME="${GCP_NETWORK_NAME:-$GCP_NETWORK_NAME_DEFAULT}" # Allow overriding network name
GCP_SUBNET_NAME="${GCP_SUBNET_NAME:-$GCP_SUBNET_NAME_DEFAULT}" # Allow overriding subnet name
AXLEARN_CONFIG_PATH="${AXLEARN_CONFIG_PATH:-$AXLEARN_CONFIG_PATH_DEFAULT}"

# Pathways Head Nodepool Configuration
PATHWAYS_HEAD_NODEPOOL_NAME="${GKE_CLUSTER_NAME_DEFAULT}-pathways-head"
PATHWAYS_HEAD_MACHINE_TYPE="n2-standard-32"
PATHWAYS_HEAD_MIN_NODES=0
PATHWAYS_HEAD_MAX_NODES=2 # Changed from 10 to 2

# Determine Project ID
if [[ -z "$PROJECT_ID" ]]; then
  echo "PROJECT_ID environment variable not set. Attempting to fetch from gcloud config."
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  if [[ -z "$PROJECT_ID" ]]; then
    echo "Error: Could not determine Project ID. Please set the PROJECT_ID environment variable or configure gcloud."
    exit 1
  fi
  echo "Using Project ID from gcloud config: $PROJECT_ID"
else
  echo "Using Project ID from environment variable: $PROJECT_ID"
fi

# Derived Variables
BUCKET_NAME_NO_PREFIX="${BASE_RESOURCE_NAME}-${GCP_REGION}-${NUM_SLICES}-slice-axlearn-storage"
BUCKET_NAME="gs://${BUCKET_NAME_NO_PREFIX}"
DOCKER_REPO="${ARTIFACT_REPO_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO_NAME}"
CONFIG_SECTION_HEADER="[gcp.\"$PROJECT_ID:$GCP_ZONE\"]"

echo "--- Ensuring GCP Resources ---"
echo "Project ID:          $PROJECT_ID"
echo "Region:              $GCP_REGION"
echo "Zone:                $GCP_ZONE"
echo "Network:             $GCP_NETWORK_NAME"
echo "Subnet:              $GCP_SUBNET_NAME"
echo "GKE Cluster:         $GKE_CLUSTER_NAME"
echo "CPU Machine Type:    $CPU_NODE_MACHINE_TYPE"
echo "CPU Node Count:      $CPU_NODE_COUNT"
echo "TPU Machine Type:    $TPU_MACHINE_TYPE"
echo "TPU Topology:        $TPU_TOPOLOGY"
echo "TPU Use Spot VMs:    $USE_SPOT_TPU"
echo "GCS Bucket:          $BUCKET_NAME"
echo "Artifact Repo:       $ARTIFACT_REPO_NAME @ $ARTIFACT_REPO_LOCATION"
echo "Docker Repo Path:    $DOCKER_REPO"
echo "Jobset Version:      $JOBSET_VERSION"
echo "AXLearn Config Path: $AXLEARN_CONFIG_PATH"
echo "-----------------------------"

# --- VPC Network & Subnet ---
echo "[Network] Checking for network '$GCP_NETWORK_NAME'..."
if ! gcloud compute networks describe "$GCP_NETWORK_NAME" --project "$PROJECT_ID" &> /dev/null; then
  gcloud compute networks create "$GCP_NETWORK_NAME" \
    --project "$PROJECT_ID" \
    --subnet-mode=custom
  echo "[Network] Network '$GCP_NETWORK_NAME' created."
else
  echo "[Network] Network '$GCP_NETWORK_NAME' already exists."
fi

echo "[Subnet] Checking for subnet '$GCP_SUBNET_NAME' in network '$GCP_NETWORK_NAME' region '$GCP_REGION'..."
if ! gcloud compute networks subnets describe "$GCP_SUBNET_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" &> /dev/null; then
  gcloud compute networks subnets create "$GCP_SUBNET_NAME" \
    --project "$PROJECT_ID" \
    --network "$GCP_NETWORK_NAME" \
    --region "$GCP_REGION" \
    --range=10.1.0.0/20 # Default range, adjust if needed
  echo "[Subnet] Subnet '$GCP_SUBNET_NAME' created."
else
  echo "[Subnet] Subnet '$GCP_SUBNET_NAME' already exists."
fi

# --- Firewall Rules ---
FIREWALL_RULE_NAME="${GCP_NETWORK_NAME}-allow-internal-ssh"
echo "[Firewall] Checking for firewall rule '$FIREWALL_RULE_NAME'..."
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" --project "$PROJECT_ID" &> /dev/null; then
  gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --project "$PROJECT_ID" \
    --network "$GCP_NETWORK_NAME" \
    --allow tcp:22,tcp:3389,icmp,tcp:0-65535,udp:0-65535 \
    --source-ranges 10.1.0.0/20 \
    --description="Allow internal traffic and SSH/RDP/ICMP within the GKE network."
  echo "[Firewall] Firewall rule '$FIREWALL_RULE_NAME' created."
else
  echo "[Firewall] Firewall rule '$FIREWALL_RULE_NAME' already exists."
fi

# --- GKE Cluster & Nodepools ---
echo "[GKE] Checking for cluster '$GKE_CLUSTER_NAME' in region '$GCP_REGION'..."
if ! gcloud container clusters describe "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" &> /dev/null; then
  gcloud container clusters create "$GKE_CLUSTER_NAME" \
    --project "$PROJECT_ID" \
    --region "$GCP_REGION" \
    --machine-type "$CPU_NODE_MACHINE_TYPE" \
    --num-nodes="$CPU_NODE_COUNT" \
    --node-locations "$GCP_ZONE" \
    --network "$GCP_NETWORK_NAME" \
    --subnetwork "$GCP_SUBNET_NAME" \
    --default-max-pods-per-node 31 \
    --enable-ip-alias \
    --enable-dataplane-v2 --enable-ip-alias --enable-multi-networking \
    --scopes "https://www.googleapis.com/auth/cloud-platform" \
    --cluster-version=1.32.4-gke.1415000
  echo "[GKE] Cluster '$GKE_CLUSTER_NAME' created."
else
  echo "[GKE] Cluster '$GKE_CLUSTER_NAME' already exists."
fi

# --- GKE TPU Nodepools (Multiple Slices) ---
# Each slice is a distinct nodepool with a fixed 4x4 topology and 4 VMs
for i in $(seq 0 $((NUM_SLICES - 1))); do
  CURRENT_TPU_NODEPOOL_NAME="${GKE_CLUSTER_NAME_DEFAULT}-tpu-slice-${i}"
  TPU_NODES_PER_SLICE=4 # 4 VMs for a 4x4 topology

  echo "[GKE] Checking for TPU nodepool '$CURRENT_TPU_NODEPOOL_NAME' in cluster '$GKE_CLUSTER_NAME'..."
  if ! gcloud container node-pools describe "$CURRENT_TPU_NODEPOOL_NAME" --cluster "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" &> /dev/null; then
    echo "[GKE] Creating TPU nodepool '$CURRENT_TPU_NODEPOOL_NAME' (Slice $((i+1)) of $NUM_SLICES)..."
    GCLOUD_NODEPOOL_CREATE_ARGS=(
      "$CURRENT_TPU_NODEPOOL_NAME"
      --project "$PROJECT_ID"
      --cluster "$GKE_CLUSTER_NAME"
      --location "$GCP_REGION"
      --node-locations "$GCP_ZONE"
      --num-nodes "$TPU_NODES_PER_SLICE"
      --machine-type "$TPU_MACHINE_TYPE"
      --tpu-topology "$TPU_TOPOLOGY"
      --enable-gvnic # Recommended for TPUs
      --scopes "https://www.googleapis.com/auth/cloud-platform"
    )
    if [[ "$USE_SPOT_TPU" == "true" ]]; then
      echo "[GKE] Using Spot VMs for TPU nodepool."
      GCLOUD_NODEPOOL_CREATE_ARGS+=(--spot)
    else
       echo "[GKE] Using On-Demand VMs for TPU nodepool."
    fi

    gcloud container node-pools create "${GCLOUD_NODEPOOL_CREATE_ARGS[@]}"
    echo "[GKE] TPU nodepool '$CURRENT_TPU_NODEPOOL_NAME' created."
  else
    echo "[GKE] TPU nodepool '$CURRENT_TPU_NODEPOOL_NAME' already exists."
  fi
done

echo "[GKE] Checking for Pathways Head nodepool '$PATHWAYS_HEAD_NODEPOOL_NAME' in cluster '$GKE_CLUSTER_NAME'..."
# Check if nodepool exists, suppressing output
gcloud container node-pools describe "$PATHWAYS_HEAD_NODEPOOL_NAME" --cluster "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" &> /dev/null
# Create nodepool if the describe command failed (exit status != 0)
if [[ $? -ne 0 ]]; then
  echo "[GKE] Creating Pathways Head nodepool '$PATHWAYS_HEAD_NODEPOOL_NAME'..."
  gcloud container node-pools create "$PATHWAYS_HEAD_NODEPOOL_NAME" \
    --project "$PROJECT_ID" \
    --cluster "$GKE_CLUSTER_NAME" \
    --location "$GCP_REGION" \
    --node-locations "$GCP_ZONE" \
    --machine-type "$PATHWAYS_HEAD_MACHINE_TYPE" \
    --enable-autoscaling \
    --min-nodes "$PATHWAYS_HEAD_MIN_NODES" \
    --max-nodes "$PATHWAYS_HEAD_MAX_NODES" \
    --scopes "https://www.googleapis.com/auth/cloud-platform" \
    --node-labels=axlearn/nodepool_type=workload
  echo "[GKE] Pathways Head nodepool '$PATHWAYS_HEAD_NODEPOOL_NAME' created."
else
  echo "[GKE] Pathways Head nodepool '$PATHWAYS_HEAD_NODEPOOL_NAME' already exists."
fi

# --- Jobset Controller Installation ---
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID"

echo "[Jobset] Checking for Jobset CRD..."
if ! kubectl get crd jobsets.jobset.x-k8s.io &> /dev/null; then
  kubectl apply --server-side -f https://github.com/kubernetes-sigs/jobset/releases/download/$JOBSET_VERSION/manifests.yaml
  echo "[Jobset] Jobset controller installed."
else
  echo "[Jobset] Jobset CRD already exists."
fi

# --- GCS Bucket Creation ---
echo "[GCS] Checking for bucket '$BUCKET_NAME'..."
if ! gsutil ls "$BUCKET_NAME" &> /dev/null; then
  gsutil mb -p "$PROJECT_ID" -l "$GCP_REGION" "$BUCKET_NAME"
  echo "[GCS] Bucket '$BUCKET_NAME' created."
else
  echo "[GCS] Bucket '$BUCKET_NAME' already exists."
fi

# --- Artifact Registry Repository Creation ---
echo "[Artifact Registry] Checking for repository '$ARTIFACT_REPO_NAME' in location '$ARTIFACT_REPO_LOCATION'..."
if ! gcloud artifacts repositories describe "$ARTIFACT_REPO_NAME" --location="$ARTIFACT_REPO_LOCATION" --project "$PROJECT_ID" &> /dev/null; then
  gcloud artifacts repositories create "$ARTIFACT_REPO_NAME" \
    --repository-format=docker \
    --location="$ARTIFACT_REPO_LOCATION" \
    --project="$PROJECT_ID"
  echo "[Artifact Registry] Repository '$ARTIFACT_REPO_NAME' created."
else
  echo "[Artifact Registry] Repository '$ARTIFACT_REPO_NAME' already exists."
fi

# --- AXLearn Configuration File Update ---
echo "[AXLearn Config] Ensuring configuration in '$AXLEARN_CONFIG_PATH'..."

# Define the config block content using printf
# TODO ensure label matches actual tpu type used
AXLEARN_CONFIG_BLOCK=$(printf "%s\n" \
  "$CONFIG_SECTION_HEADER" \
  "project = \"$PROJECT_ID\"" \
  "region = \"$GCP_REGION\"" \
  "zone = \"$GCP_ZONE\"" \
  "gke_cluster = \"$GKE_CLUSTER_NAME\"" \
  "cluster = \"$GKE_CLUSTER_NAME\"" \
  "labels = \"tpu-v6e\"" \
  "docker_repo = \"$DOCKER_REPO\"" \
  "default_dockerfile = \"Dockerfile\"" \
  "permanent_bucket = \"$BUCKET_NAME_NO_PREFIX\"" \
  "private_bucket = \"$BUCKET_NAME_NO_PREFIX\"" \
  "ttl_bucket = \"$BUCKET_NAME_NO_PREFIX\""
)

# Ensure the directory exists (though $HOME should exist)
mkdir -p "$(dirname "$AXLEARN_CONFIG_PATH")"

if [[ -f "$AXLEARN_CONFIG_PATH" ]]; then
  echo "[AXLearn Config] File exists. Checking for section '$CONFIG_SECTION_HEADER'..."
  # Use grep -F for fixed string matching and -q for quiet mode
  if grep -Fq "$CONFIG_SECTION_HEADER" "$AXLEARN_CONFIG_PATH"; then
    echo "[AXLearn Config] Warning: Section '$CONFIG_SECTION_HEADER' already exists in '$AXLEARN_CONFIG_PATH'. Skipping modification. Please review manually."
  else
    # Add a newline before appending if the file doesn't end with one
    [[ $(tail -c1 "$AXLEARN_CONFIG_PATH" | wc -l) -eq 0 ]] && echo "" >> "$AXLEARN_CONFIG_PATH"
    echo "" >> "$AXLEARN_CONFIG_PATH" # Add a blank line for separation
    echo "$AXLEARN_CONFIG_BLOCK" >> "$AXLEARN_CONFIG_PATH"
    echo "[AXLearn Config] Configuration appended."
  fi
else
  echo "$AXLEARN_CONFIG_BLOCK" > "$AXLEARN_CONFIG_PATH"
  echo "[AXLearn Config] Configuration file created."
fi

# --- Resource Deletion Function ---
function delete_resources() {
  local only_nodepools=false
  if [[ "$1" == "--only-nodepools" ]]; then
    only_nodepools=true
    echo "--- Deleting only Nodepools ---"
  else
    echo "--- Deleting All GCP Resources ---"
  fi

  echo "Project ID:          $PROJECT_ID"
  echo "Region:              $GCP_REGION"
  echo "Zone:                $GCP_ZONE"
  echo "GKE Cluster:         $GKE_CLUSTER_NAME"
  echo "TPU Nodepool:        $TPU_NODEPOOL_NAME"
  echo "Pathways Head Nodepool: $PATHWAYS_HEAD_NODEPOOL_NAME"
  if [[ "$only_nodepools" == "false" ]]; then
    echo "Network:             $GCP_NETWORK_NAME"
    echo "Subnet:              $GCP_SUBNET_NAME"
    echo "GCS Bucket:          $BUCKET_NAME"
    echo "Artifact Repo:       $ARTIFACT_REPO_NAME @ $ARTIFACT_REPO_LOCATION"
  fi
  echo "-----------------------------"

  # Delete TPU Nodepools (Multiple Slices)
  for i in $(seq 0 $((NUM_SLICES - 1))); do
    CURRENT_TPU_NODEPOOL_NAME="${GKE_CLUSTER_NAME_DEFAULT}-tpu-slice-${i}"
    echo "[GKE] Deleting TPU nodepool '$CURRENT_TPU_NODEPOOL_NAME' from cluster '$GKE_CLUSTER_NAME'..."
    gcloud container node-pools delete "$CURRENT_TPU_NODEPOOL_NAME" --cluster "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" --quiet || true
  done

  # Delete Pathways Head Nodepool
  echo "[GKE] Deleting Pathways Head nodepool '$PATHWAYS_HEAD_NODEPOOL_NAME' from cluster '$GKE_CLUSTER_NAME'..."
  gcloud container node-pools delete "$PATHWAYS_HEAD_NODEPOOL_NAME" --cluster "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" --quiet || true

  if [[ "$only_nodepools" == "false" ]]; then
    # Delete GKE Cluster
    echo "[GKE] Deleting cluster '$GKE_CLUSTER_NAME' in region '$GCP_REGION'..."
    gcloud container clusters delete "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" --quiet || true

    # Delete Firewall Rule
    FIREWALL_RULE_NAME="${GCP_NETWORK_NAME}-allow-internal-ssh"
    echo "[Firewall] Deleting firewall rule '$FIREWALL_RULE_NAME'..."
    gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" --project "$PROJECT_ID" --quiet || true

    # Delete Subnet
    echo "[Subnet] Deleting subnet '$GCP_SUBNET_NAME' in region '$GCP_REGION'..."
    gcloud compute networks subnets delete "$GCP_SUBNET_NAME" --region "$GCP_REGION" --project "$PROJECT_ID" --quiet || true

    # Delete Network
    echo "[Network] Deleting network '$GCP_NETWORK_NAME'..."
    gcloud compute networks delete "$GCP_NETWORK_NAME" --project "$PROJECT_ID" --quiet || true

    # Delete GCS Bucket
    echo "[GCS] Deleting bucket '$BUCKET_NAME'..."
    gsutil rm -r "$BUCKET_NAME" || true

    # Delete Artifact Registry Repository
    echo "[Artifact Registry] Deleting repository '$ARTIFACT_REPO_NAME' in location '$ARTIFACT_REPO_LOCATION'..."
    gcloud artifacts repositories delete "$ARTIFACT_REPO_NAME" --location="$ARTIFACT_REPO_LOCATION" --project "$PROJECT_ID" --quiet || true
  fi

  echo "--- Resource Deletion Complete ---"
}

# --- Main Script Logic ---
if [[ "$1" == "--delete" ]]; then
  if [[ "$2" == "--only-nodepools" ]]; then
    delete_resources "--only-nodepools"
  else
    delete_resources
  fi
else
  echo "--- Resource Check Complete ---"
  echo "Script finished successfully."
fi
