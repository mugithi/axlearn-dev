#!/bin/bash
export RUN=$(date +%Y%m%d-%H%M%S)
export USER="isaack"
# Set environment variables
export CLUSTER=${CLUSTER:-$USER-axlearn}
export PROJECT_ID=$(gcloud config get project)
export TRAINER_DIR=gs://$PROJECT_ID-axlearn-$USER/$RUN
export BASTION_TIER=disabled
# export LIBTPU_LOGS=$TRAINER_DIR
export LIBTPU_LOGS=$TRAINER_DIR

# export UPLOAD_INTERVAL=5
# Ensure USER is set for the job name (e.g., isaack)
# If you want to use a specific user name for the job, uncomment and set it here:
# export USER=isaack

# Execute the axlearn command
# Using "start" action to ensure bundling occurs.


# axlearn gcp launch start --cluster=$CLUSTER \
### This will will build and upload the Docker image to Artifact Registry, which is necessary for running the job on GKE with TPU support.

# axlearn gcp launch run --cluster=$CLUSTER \
### Will run  the job on the specified cluster using the previously built image.


axlearn gcp launch start --cluster=$CLUSTER \
        --runner_name gke_tpu_single \
        --name=$USER \
        --instance_type=tpu-v6e-16 \
        --num_replicas=2 \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
        -- python3 -m axlearn.common.launch_trainer_main \
          --module=text.gpt.c4_trainer --config=fuji-7B-v2-flash \
          --trainer_dir=$TRAINER_DIR \
          --data_dir=gs://axlearn-public/tensorflow_datasets \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-16 \
          --trace_at_steps=3 \
          --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
          --init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints

#           # --recorder_type=axlearn.cloud.gcp.measurement:goodput \
#           # --recorder_spec=name=goodput_$RUN \
#           # --recorder_spec=upload_dir=$OUTPUT_DIR/$RUN/summaries \
#           # --recorder_spec=upload_interval=$UPLOAD_INTERVAL

axlearn gcp launch run --cluster=$CLUSTER \
        --runner_name gke_tpu_single \
        --name=$USER \
        --instance_type=tpu-v6e-16 \
        --num_replicas=2 \
        --bundler_spec=allow_dirty=True \
        --bundler_type=artifactregistry --bundler_spec=image=tpu \
        --bundler_spec=dockerfile=Dockerfile --bundler_spec=target=tpu \
        --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
        -- python3 -m axlearn.common.launch_trainer_main \
          --module=text.gpt.c4_trainer --config=fuji-7B-v2-flash \
          --trainer_dir=$TRAINER_DIR \
          --data_dir=gs://axlearn-public/tensorflow_datasets \
          --jax_backend=tpu \
          --mesh_selector=tpu-v6e-16 \
          --trace_at_steps=3 \
          --host_mount_spec=name=tmp,host_path=/tmp,mount_path=/host-tmp \
          --init_module=axlearn.common.checkpointer_orbax_emergency:local_ckpt_dir=/host-tmp/checkpoints

        # -- env LIBTPU_LOGS="$LIBTPU_LOGS" python3 -m axlearn.common.launch_trainer_main \