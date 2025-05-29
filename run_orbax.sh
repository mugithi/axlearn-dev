#!/usr/bin/env bash

set -xe

export RUN=$(date +%Y%m%d-%H%M%S)
export USER="isaack" # As defined in run_axlearn_tpu.sh
export PROJECT_ID=$(gcloud config get project)
export TRAINER_DIR=gs://$PROJECT_ID-axlearn-$USER/$RUN
export BASTION_TIER=disabled
export LIBTPU_LOGS=$TRAINER_DIR

export NUM_REPLICAS=${NUM_REPLICAS:-2}
export JOBSET_NAME=${JOBSET_NAME:-$USER} # USER is now defined above
export ORBAX=${ORBAX:-true} # Corrected typo

if [ $ORBAX = true ]; then
axlearn gcp launch run --cluster=bodaborg-v6e-256-tt-c \
        --runner_name gke_tpu_single \
        --name=$JOBSET_NAME \
        --queue=multislice-queue \
        --instance_type=tpu-v6e-256 \
        --priority_class=very-high \
        --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
        --num_replicas=${NUM_REPLICAS} \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        -- python3 -m axlearn.common.launch_trainer_main \
          --init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints \
          --module=text.gpt.c4_trainer \
          --config=fuji-70B-v2-flash-orbaxem \
          --trainer_dir=gs://tess-checkpoints-us-west1/stoelinga-axlearn-v6e-4k-orbax-1/ \
          --data_dir=gs://axlearn-public/tensorflow_datasets  \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-256-4 \
          --trace_at_steps=3
else
axlearn gcp launch run --cluster=bodaborg-v6e-256-tt-c \
        --runner_name gke_tpu_single \
        --name=$JOBSET_NAME \
        --queue=multislice-queue \
        --instance_type=tpu-v6e-256 \
        --priority_class=very-high \
        --num_replicas=${NUM_REPLICAS} \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        -- python3 -m axlearn.common.launch_trainer_main \
          --module=text.gpt.c4_trainer \
          --config=fuji-70B-v2-flash \
          --trainer_dir=gs://tess-checkpoints-us-west1/stoelinga-axlearn-v6e-4k-orbax-1/ \
          --data_dir=gs://axlearn-public/tensorflow_datasets  \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-256-4 \
          --trace_at_steps=3
fi

# fuji-70B-v3-flash-orbaxem
