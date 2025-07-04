#!/usr/bin/env bash

set -xe

# Default values
CHECKPOINTER="regular"
ENABLE_GCSFUSE=false
ENABLE_GOODPUT=false
GOODPUT_UPLOAD_INTERVAL=30
GOODPUT_STEP_DEVIATION_INTERVAL=30

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --checkpointer) CHECKPOINTER="$2"; shift ;;
        --gcsfuse) ENABLE_GCSFUSE=true ;;
        --goodput) ENABLE_GOODPUT=true ;;
        --goodput-interval) GOODPUT_UPLOAD_INTERVAL="$2"; shift ;;
        --goodput-step-interval) GOODPUT_STEP_DEVIATION_INTERVAL="$2"; shift ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --checkpointer TYPE        Set checkpointer type (regular|emergency)"
            echo "  --gcsfuse                  Enable GCSfuse mounting"
            echo "  --goodput                  Enable goodput recording"
            echo "  --goodput-interval SEC     Set goodput upload interval (default: 30)"
            echo "  --goodput-step-interval SEC Set step deviation interval (default: 30)"
            echo "  --help                     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --goodput                                    # Enable goodput with defaults"
            echo "  $0 --checkpointer emergency --goodput           # Emergency checkpointer + goodput"
            echo "  $0 --goodput --goodput-interval 60              # Custom upload interval"
            echo "  $0 --gcsfuse --goodput                          # GCSfuse + goodput"
            exit 0
            ;;
        *) echo "Unknown parameter passed: $1. Use --help for usage information."; exit 1 ;;
    esac
    shift
done

export NUM_REPLICAS=${NUM_REPLICAS:-2}
export JOBSET_NAME="isaack-1"
export BASTION_TIER=disabled
export GKE_CLUSTER="isaack-axlearn"
export INSTANCE_TYPE="tpu-v6e-16"
export MESH_SELECTOR=${MESH:-"tpu-v6e-16"}
export CONFIG=${CONFIG:-"fuji-7B-v2-flash-orbax"}
### KeyError: 'Unrecognized config fuji-70B-v2-flash-orbax; did you mean [fuji-70B-v2-flash-orbaxem, fuji-70B-v1-flash-orbaxem, fuji-70B-v3-flash-orbaxem, fuji-70B-v3-tiktoken-flash-orbaxem, fuji-7B-v2-flash-orbaxem, fuji-7B-v2-flash-orbaxem-single-host, fuji-test-v2-flash-orbaxem, fuji-70B-v2-flash, fuji-7B-v1-flash-orbaxem, fuji-7B-v1-flash-orbaxem-single-host, fuji-7B-v3-flash-orbaxem, fuji-7B-v3-flash-orbaxem-single-host, fuji-1B-v3-flash-orbaxem, fuji-1B-v3-flash-orbaxem-single-host, fuji-1B-v3-tiktoken-flash-orbaxem, fuji-1B-v3-tiktoken-flash-orbaxem-single-host, fuji-3B-v3-flash-orbaxem, fuji-3B-v3-flash-orbaxem-single-host, fuji-3B-v3-tiktoken-flash-orbaxem, fuji-3B-v3-tiktoken-flash-orbaxem-single-host, fuji-70B-v2-orbaxem, fuji-8B-v3-tiktoken-flash-orbaxem, fuji-8B-v3-tiktoken-flash-orbaxem-single-host, fuji-7B-v2-flash-single-host, fuji-test-v1-flash-orbaxem, fuji-test-v3-flash-orbaxem, fuji-test-v3-tiktoken-flash-orbaxem, fuji-70B-v1-flash, fuji-70B-v1-orbaxem, fuji-70B-v3-flash, fuji-70B-v3-orbaxem, fuji-70B-v3-tiktoken-flash, fuji-70B-v3-tiktoken-orbaxem, fuji-7B-v2-flash, fuji-7B-v2-orbaxem, fuji-7B-v2-orbaxem-single-host]'
export PROJECT_ID="tpu-prod-env-one-vm"
export REGION="us-east5"
export TRAINER_DIR_FINAL="gs://tpu-prod-env-one-vm-axlearn-isaack"
export DATA_DIR_FINAL="gs://tess-dataset-southamerica-west1"

gcloud container clusters get-credentials $GKE_CLUSTER --region $REGION --project $PROJECT_ID

# Set CONFIG based on checkpointer type
if [ "$CHECKPOINTER" == "emergency" ]; then
  export CONFIG=${CONFIG:-"fuji-70B-v3-flash-orbaxem"}
fi

# Example for v6e-256
# MESH_SELECTOR=tpu-v6e-256-4 INSTANCE_TYPE=tpu-v6e-256 ./test-orbax.sh

# The bundle step is needed if you run on cloudtop
# uncomment if you use cloudtop
# axlearn gcp bundle --name=$JOBSET_NAME \
#          --bundler_spec=allow_dirty=True \
#          --bundler_type=artifactregistry \
#          --bundler_spec=dockerfile=Dockerfile \
#          --bundler_spec=image=tpu \
#          --bundler_spec=target=tpu

# Only enable kueue when running on scale testing cluster
# --queue=multislice-queue \
# --priority_class=very-high \
# --trainer_dir=gs://tess-checkpoints-us-west1/${JOBSET_NAME}-nr-${NUM_REPLICAS}/ \
#

if [ "$CHECKPOINTER" == "emergency" ]; then
  echo "Running with Orbax emergency checkpointer."
  CMD="python3 -c 'import jax; jax.devices()'; python3 -m axlearn.common.launch_trainer_main"
  CMD_ARGS="--init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints \
         --config_module=text.gpt.c4_trainer \
         --config=${CONFIG} \
         --trainer_dir=${TRAINER_DIR_FINAL} \
         --data_dir=${DATA_DIR_FINAL}  \
         --jax_backend=tpu \
         --mesh_selector=${MESH_SELECTOR} \
         --initialization_timeout=1200 \
         --trace_at_steps=29,59,89,119,149,179,209,239,269,299,329,359,389,419,449,479,509,539,569,599,629,659,689,719"
  HOST_MOUNT_SPEC="--host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp"
else
  echo "Running Orbax regular checkpointer or AXLearn native."
  CMD="ulimit -n 1048576; ulimit -c 0; python3 -c 'import jax; jax.devices()'; python3 -m axlearn.common.launch_trainer_main"
  CMD_ARGS="--config_module=text.gpt.c4_trainer \
          --config=${CONFIG} \
          --trainer_dir=${TRAINER_DIR_FINAL} \
          --data_dir=${DATA_DIR_FINAL}  \
          --jax_backend=tpu \
          --mesh_selector=${MESH_SELECTOR} \
          --initialization_timeout=1200 \
          --trace_at_steps=29,59,89,119,149,179,209,239,269,299,329,359,389,419,449,479,509,539,569,599,629,659,689,719"
  HOST_MOUNT_SPEC=""
fi

# Add goodput recording if enabled
if [ "$ENABLE_GOODPUT" == "true" ]; then
  echo "Goodput recording enabled."
  GOODPUT_ARGS="--recorder_type=axlearn.cloud.gcp.measurement:goodput \
         --recorder_spec=name=${JOBSET_NAME} \
         --recorder_spec=upload_dir=${TRAINER_DIR_FINAL}/summaries \
         --recorder_spec=upload_interval=${GOODPUT_UPLOAD_INTERVAL} \
         --recorder_spec=step_deviation_interval_seconds=${GOODPUT_STEP_DEVIATION_INTERVAL}"
  CMD_ARGS="$CMD_ARGS $GOODPUT_ARGS"
fi

if [ "$ENABLE_GCSFUSE" == "true" ]; then
  echo "GCSfuse enabled."
  GCSFUSE_MOUNT_SPEC="--gcsfuse_mount_spec=gcs_path=${DATA_DIR_FINAL}"
  CMD_ARGS=$(echo "$CMD_ARGS" | sed "s|--trainer_dir=gs.*|--trainer_dir=/tmp/dataset/|' | sed 's|--data_dir=gs.*|--data_dir=/tmp/dataset|")
else
  GCSFUSE_MOUNT_SPEC=""
fi

axlearn gcp launch run --cluster=$GKE_CLUSTER \
      --runner_name gke_tpu_single \
      --name=$JOBSET_NAME \
      --instance_type=${INSTANCE_TYPE} \
      --num_replicas=${NUM_REPLICAS} \
      --bundler_spec=allow_dirty=True \
      --bundler_type=artifactregistry --bundler_spec=image=tpu \
      --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
      $HOST_MOUNT_SPEC \
      $GCSFUSE_MOUNT_SPEC \
      -- "$CMD" $CMD_ARGS
