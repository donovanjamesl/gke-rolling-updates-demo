#!/usr/bin/env bash
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck source=.env

# cluster_ops.sh - a runner script to create, upgrade, and delete gke clusters
# with the help of kubectl, and gcloud

# Stop immediately if something goes wrong
set -euo pipefail

# The absolute path to the root of the repository
SCRIPT_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

fail() {
  echo "ERROR: ${*}"
  exit 2
}

# Validate that this workstation has access to the required executables
command -v kubectl >/dev/null || fail "kubectl is not installed!"
command -v gcloud >/dev/null || fail "gcloud is not installed!"
command -v jq >/dev/null || fail "jq is not installed!"

usage() {
  cat <<-EOM
USAGE: $(basename "$0") <action>
Where the <action> can be:
  auto
  create
  upgrade-control
  new-node-pool
  drain-default-pool
  delete-default-pool
  delete
EOM
  exit 1
}

# Validate the number of command line arguments
if [[ $# -lt 1 ]]; then
  usage
fi

# Source the properties file
if [ -f "${REPO_HOME}/.env" ] ; then
  source "${REPO_HOME}/.env"
else
  echo "ERROR: Define a properties file '.env'"
  exit 1
fi

CLOUDSDK_CORE_DISABLE_PROMPTS=0
export CLOUDSDK_CORE_DISABLE_PROMPTS

# Set GCLOUD_REGION to default if it has not yet been set
if [ -z ${GCLOUD_REGION:+exists} ]; then
  GCLOUD_REGION=$(gcloud config get-value compute/region)
  export GCLOUD_REGION
  if [ "${GCLOUD_REGION}" == "(unset)" ]; then
    fail "GCLOUD_REGION is not set"
  fi
fi

# Set GCLOUD_PROJECT to default if it has not yet been set
if [ -z ${GCLOUD_PROJECT:+exists} ]; then
  GCLOUD_PROJECT=$(gcloud config get-value core/project)
  export GCLOUD_PROJECT
  if [ "${GCLOUD_PROJECT}" == "(unset)" ]; then
    fail "GCLOUD_PROJECT is not set"
  fi
fi

if [ -z ${CLUSTER_NAME:+exists} ]; then
  CLUSTER_NAME="blue-green-test"
  export CLUSTER_NAME
fi

# Check that the K8S_VER variable has been set
if [ -z ${K8S_VER:+exists} ]; then
  echo "ERROR: Set the K8S_VER environment variable"
  exit 1
fi

# Check that the NEW_K8S_VER variable has been set
if [ -z ${NEW_K8S_VER:+exists} ]; then
  echo "ERROR: Set the NEW_K8S_VER environment variable"
  exit 1
fi

# Validate the number of command line arguments
if [[ $# -lt 1 ]]; then
  usage
fi

# Installs the hello appF
install_app() {
  echo "Installing Hello App"
  kubectl create -f "${REPO_HOME}/manifests/hello-server.yaml"
  kubectl create -f "${REPO_HOME}/manifests/hello-svc.yaml"
}

create_cluster() {
  echo "Building a GKE cluster using the following values: "
  echo "GCLOUD_REGION = ${GCLOUD_REGION}"
  echo "GCLOUD_PROJECT = ${GCLOUD_PROJECT}"
  echo "GKE Version = ${K8S_VER}"

  gcloud container clusters create "${CLUSTER_NAME}" \
    --project "${GCLOUD_PROJECT}" \
    --region "${GCLOUD_REGION}" \
    --cluster-version "${K8S_VER}" \
    --machine-type "${MACHINE_TYPE}" \
    --node-labels "nodepool=${K8S_VER}" \
    --num-nodes "${NUM_NODES}"

  # Acquire the kubectl credentials
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}" \
    --project "${GCLOUD_PROJECT}"

  # Bind the cluster-admin ClusterRole to your user account
  kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole cluster-admin \
    --user "$(gcloud config get-value account)"

  # Deploy the example application
  install_app
}

# Upgrades the control plane to the new version
upgrade_control() {
  echo "Upgrading control plane to version ${NEW_K8S_VER}"
  gcloud container clusters upgrade "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}" \
    --cluster-version "${NEW_K8S_VER}" \
    --project "${GCLOUD_PROJECT}" \
    --master
}

# Accepts a single parameter - a label of the format 'key=value' to use as a
# node selector.  All nodes with the matching label are drained.
drain_node_label() {
  LABEL=$1
  OLD_NODES=$(kubectl get nodes -l "${LABEL}" -o name)
  echo "Found nodes to drain:"
  echo "${OLD_NODES}"
  # Check if we are disabling prompts
  if ! [[ "${CLOUDSDK_CORE_DISABLE_PROMPTS}" -eq 1 ]]; then
    echo "Proceed to drain all? (Y/N)"
    read -r ANSWER
    # If answer is not y || Y, exit
    if ! [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      exit 0
    fi
  fi
  for NODE in ${OLD_NODES}; do
    # remove the 'node/' prefix from the output
    NODE=${NODE%%"node/"}
    kubectl drain "${NODE}" --ignore-daemonsets --delete-local-data --force
  done
}

# Accepts a single parameter - a label of the format 'key=value' to use as a
# node selector.  All nodes with the matching label are cordoned.
cordon_node_label() {
  LABEL=$1
  OLD_NODES=$(kubectl get nodes -l "${LABEL}" -o name)
  for NODE in ${OLD_NODES}; do
    kubectl cordon "${NODE}"
  done
}

# Creates the new node pool then cordons all nodes in the default node pool.
new_node_pool() {
  # Find default pool machine type
  MACHINE_TYPE=$(gcloud container node-pools describe default-pool \
    --project "${GCLOUD_PROJECT}" \
    --cluster "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}" \
    --format='value(config.machineType)')

  # echo "Creating new node pool with kubernetes version ${NEW_K8S_VER}"
  gcloud container node-pools create "new-pool" \
    --project "${GCLOUD_PROJECT}" \
    --cluster "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}" \
    --num-nodes "${NUM_NODES}" \
    --machine-type "${MACHINE_TYPE}" \
    --node-labels="nodepool=${NEW_K8S_VER}"

  echo "Cordoning nodes in old node pool"
  cordon_node_label "nodepool=${K8S_VER}"
}

# Delete the node pool named "default-pool".
delete_default_pool() {
  echo "Deleting the default node pool"
  gcloud container node-pools delete default-pool \
    --project "${GCLOUD_PROJECT}" \
    --cluster "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}"
}

# Deletes the GKE cluster created by this example
tear_down() {
  echo "Deleting the GKE cluster ${CLUSTER_NAME}"
  gcloud container clusters delete "${CLUSTER_NAME}" \
    --project "${GCLOUD_PROJECT}" \
    --region "${GCLOUD_REGION}"
}

# After the new node pool is created, the control plane instances get upgraded
# and all other cluster operations will fail until the upgrade has completed.
wait_for_upgrade() {
  echo "Checking for master upgrade"
  OP_ID=$(gcloud container operations list \
    --project "${GCLOUD_PROJECT}" \
    --region "${GCLOUD_REGION}" \
    --filter 'TYPE=UPGRADE_MASTER' \
    --filter 'STATUS=RUNNING' \
    --format 'value(name)' \
    | head -n1 )
  if [[ "${OP_ID}" =~ ^operation-.* ]]; then
    echo "Master upgrade in process.  Waiting until complete..."
    gcloud container operations wait "${OP_ID}" \
      --region "${GCLOUD_REGION}" \
      --project "${GCLOUD_PROJECT}"
  fi
}

# Run a fully automated create, upgrade, migrate, and validate.
auto() {
  create_cluster
  upgrade_control
  new_node_pool
  drain_node_label "nodepool=${K8S_VER}"
  wait_for_upgrade
  delete_default_pool
  "${SCRIPT_HOME}/validate.sh"
}

ACTION=$1
case "${ACTION}" in
  auto)
    CLOUDSDK_CORE_DISABLE_PROMPTS=1
    export CLOUDSDK_CORE_DISABLE_PROMPTS
    auto
    unset CLOUDSDK_CORE_DISABLE_PROMPTS
    ;;
  create)
    create_cluster
    ;;
  upgrade-control)
    upgrade_control
    ;;
  new-node-pool)
    new_node_pool
    ;;
  cordon-default-pool)
    cordon_node_label "nodepool=${K8S_VER}"
    ;;
  drain-default-pool)
    drain_node_label "nodepool=${K8S_VER}"
    ;;
  delete-default-pool)
    delete_default_pool
    ;;
  install-app)
    install_app
    ;;
  delete)
    tear_down
    ;;
  *)
    usage
    ;;
esac
