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

# The ORBAX variable and if/else are removed as the python config now handles the checkpointer type.
# The --init_module flag is commented out as the checkpointer type and local_ckpt_dir
# should be handled by the python configuration when using the -orbaxem suffix.

# axlearn gcp launch start --cluster=$CLUSTER \
#         --runner_name gke_tpu_single \
#         --name=$JOBSET_NAME \
#         --queue=multislice-queue \
#         --instance_type=tpu-v6e-16 \
#         --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
#         --num_replicas=${NUM_REPLICAS} \
#         --bundler_spec=allow_dirty=True \
#         --bundler_type=artifactregistry --bundler_spec=image=tpu \
#         --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
#         -- python3 -m axlearn.common.launch_trainer_main \
#           # --init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints \
#           --module=text.gpt.c4_trainer \
#           --config=fuji-7B-v2-flash-orbaxem \
#           --trainer_dir=$TRAINER_DIR \
#           --data_dir=gs://axlearn-public/tensorflow_datasets  \
#           --jax_backend=tpu \
#           --mesh_selector=tpu-v6e-16 \
#           --trace_at_steps=3

axlearn gcp launch run --cluster=$CLUSTER \
        --runner_name gke_tpu_single \
        --name=$JOBSET_NAME \
        --queue=multislice-queue \
        --instance_type=tpu-v6e-16 \
        --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
        --num_replicas=${NUM_REPLICAS} \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        -- python3 -m axlearn.common.launch_trainer_main \
          # --init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints \
          --module=text.gpt.c4_trainer \
          --config=fuji-7B-v2-flash-orbaxem \
          --trainer_dir=$TRAINER_DIR \
          --data_dir=gs://axlearn-public/tensorflow_datasets  \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-16 \
          --trace_at_steps=3
# fi

# fuji-70B-v3-flash-orbaxem
