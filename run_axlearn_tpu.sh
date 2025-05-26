#!/bin/bash

export USER="isaack"
# Set environment variables
export CLUSTER=${CLUSTER:-$USER-axlearn}
export PROJECT_ID=$(gcloud config get project)
export OUTPUT_DIR=gs://$PROJECT_ID-axlearn/$USER-v6e-7b-1/$RUN
export BASTION_TIER=disabled
export LIBTPU=$OUTPUT_DIR/libtpu_logs/
export LIBTPU_INIT_ARGS="--megascale_rapideye_error_digest_log_path=${LIBTPU} --megascale_debug_port=8081"
export RUN=$(date +%Y%m%d-%H%M%S)
# export UPLOAD_INTERVAL=5
# Ensure USER is set for the job name (e.g., isaack)
# If you want to use a specific user name for the job, uncomment and set it here:
# export USER=isaack

# Execute the axlearn command
axlearn gcp launch run --cluster=$CLUSTER \
        --name=$USER \
        --instance_type=tpu-v6e-16 \
        --num_replicas=2 \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        -- python3 -m axlearn.common.launch_trainer_main \
        --module=text.gpt.c4_trainer --config=fuji-7B-v2-flash \
          --trainer_dir=$OUTPUT_DIR \
          --data_dir=gs://axlearn-public/tensorflow_datasets \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-16 \
          --trace_at_steps=3 \
          # --recorder_type=axlearn.cloud.gcp.measurement:goodput \
          # --recorder_spec=name=goodput_$RUN \
          # --recorder_spec=upload_dir=$OUTPUT_DIR/$RUN/summaries \
          # --recorder_spec=upload_interval=$UPLOAD_INTERVAL
