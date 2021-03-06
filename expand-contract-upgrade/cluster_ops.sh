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

set -euo pipefail

# "---------------------------------------------------------"
# "-                                                       -"
# "-         rolling updates expand contract               -"
# "-                                                       -"
# "-     this poc demonstrates the use of the expand       -"
# "-     and contract pattern for upgrading gke clusters,  -"
# "-     the pattern works by increasing the node pool     -"
# "-     size prior to the upgrade to provide additional   -"
# "-     headroom while upgrading, once the upgrade is     -"
# "-     complete the node pool is restored to its         -"
# "-     original size                                     -"
# "-                                                       -"
# "---------------------------------------------------------"



## source properties file
SCRIPT_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
source "${REPO_HOME}/.env"

if [ -z ${CLUSTER_NAME:+exists} ]; then
  CLUSTER_NAME="expand-contract-upgrade"
  export CLUSTER_NAME
fi

################  functions  ####################


## validate use of this script
usage() {
  echo ""
  echo " Checking valid paramater passed to script ....."
  echo ""
  cat <<-EOM
USAGE: $(basename "$0") <action> [N]
Where the <action> can be:
  auto
  create
  upgrade-control
  upgrade-nodes
  resize <N>
  delete
N - The Number of nodes per zone to set the default node pool during resize
EOM
  exit 1
}

## check dependencies installed
check_dependencies() {
  echo ""
  echo "Checking dependencies are installed ....."
  echo ""
  command -v gcloud >/dev/null 2>&1 || { \
    echo >&2 "I require gcloud but it's not installed.  Aborting."; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { \
    echo >&2 "I require kubectl but it's not installed.  Aborting."; exit 1; }
}


## check project exists
check_project() {
  echo ""
  echo "Checking the project specified for the demo exists ....."
  echo ""
  local EXISTS
  EXISTS=$(gcloud projects list | awk "/${GCLOUD_PROJECT} /" | awk '{print $1}')
  sleep 1
  if [[ "${EXISTS}" != "${GCLOUD_PROJECT}" ]] ; then
    echo ""
    echo "the ${GCLOUD_PROJECT} project does not exists"
    echo "please update properties file with "
    echo "a valid project"
    echo ""
    exit 1
  fi
}


## check api's enabled
check_apis() {
  echo ""
  echo "Checking the appropriate API's are enabled ....."
  echo ""
  COMPUTE_API=$(gcloud services list --project="${GCLOUD_PROJECT}" \
            --format='value(serviceConfig.name)' \
            --filter='serviceConfig.name:compute.googleapis.com' 2>&1)
  if [[ "${COMPUTE_API}" != "compute.googleapis.com" ]]; then
    echo "Enabling the Compute Engine API"
    gcloud services enable compute.googleapis.com --project="${GCLOUD_PROJECT}"
  fi
  CONTAINER_API=$(gcloud services list --project="${GCLOUD_PROJECT}" \
            --format='value(serviceConfig.name)' \
            --filter='serviceConfig.name:container.googleapis.com' 2>&1)
  if [[ "${CONTAINER_API}" != "container.googleapis.com" ]]; then
    echo "Enabling the Kubernetes Engine API"
    gcloud services enable container.googleapis.com --project="${GCLOUD_PROJECT}"
  fi
}


## create cluster
create_cluster() {
  # create cluster
  echo ""
  echo "Building a GKE cluster ....."
  echo ""
  gcloud container clusters create "${CLUSTER_NAME}" \
      --machine-type "${MACHINE_TYPE}" \
      --num-nodes "${NUM_NODES}" \
      --cluster-version "${K8S_VER}" \
      --project "${GCLOUD_PROJECT}" \
      --region "${GCLOUD_REGION}"
  # acquire the kubectl credentials
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --region "${GCLOUD_REGION}" \
    --project "${GCLOUD_PROJECT}"
}


## setup the example application
setup_app() {
  echo ""
  echo "Setting up the application ....."
  echo ""
  kubectl create -f "${REPO_HOME}/manifests/hello-server.yaml"
  kubectl create -f "${REPO_HOME}/manifests/hello-svc.yaml"
}


## increase size of the node pool
resize_node_pool() {
  local SIZE=$1
  echo ""
  echo "Resizing the node pool to $SIZE nodes ....."
  echo ""
  gcloud container clusters resize "${CLUSTER_NAME}" \
    --size "${SIZE}" \
    --region "${GCLOUD_REGION}" \
    --project "${GCLOUD_PROJECT}" \
    --quiet
}


## upgrade the control plane
upgrade_control() {
  echo ""
  echo "Upgrading the K8s control plane ....."
  echo ""
  gcloud container clusters upgrade "${CLUSTER_NAME}" \
    --cluster-version="${NEW_K8S_VER}" \
    --region "${GCLOUD_REGION}" \
    --project "${GCLOUD_PROJECT}" \
    --master \
    --quiet
}


## updgrade the node clusters
upgrade_nodes() {
  echo ""
  echo "Upgrading the K8s nodes ....."
  echo ""
  gcloud container clusters upgrade "${CLUSTER_NAME}" \
    --cluster-version="${NEW_K8S_VER}" \
    --region "${GCLOUD_REGION}" \
    --project "${GCLOUD_PROJECT}" \
    --quiet
}


## tear down the demo
tear_down() {
  echo ""
  echo "Tearing down the infrastructure ....."
  echo ""
  delete_manifests
  delete_cluster
}


# delete es manifests
delete_manifests() {
  kubectl delete --ignore-not-found=true -f "${REPO_HOME}/manifests"
}

# delete cluster
delete_cluster() {
  gcloud container clusters delete $"${CLUSTER_NAME}" \
    --project "${GCLOUD_PROJECT}" \
    --region "${GCLOUD_REGION}" \
    --quiet
}

# After the node pool is expanded, the control plane instances will likely be
# vertically scaled automatically by Kubernetes Engine to handle the increased
# load of more instances.  When the control plane is upgrading, no other cluster
# modifications can occur.
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
      --region "${GCLOUD_REGION}"
  fi
}

auto() {
  create_cluster
  setup_app
  resize_node_pool 2
  # Unfortunate race condition here, a little sleep should be enough
  sleep 10
  wait_for_upgrade
  upgrade_control
  upgrade_nodes
  resize_node_pool 1
  "${SCRIPT_HOME}/validate.sh"
}

################  execution  ####################

# validate script called correctly
if [[ $# -lt 1 ]]; then
  usage
fi

# check dependencies installed
check_dependencies

# check project exist
check_project

# check apis enabled
check_apis

ACTION=$1
case "${ACTION}" in
  auto)
    auto
    ;;
  create)
    create_cluster
    setup_app
    ;;
  resize)
    resize_node_pool "$2"
    ;;
  upgrade-control)
    upgrade_control
    ;;
  upgrade-nodes)
    upgrade_nodes
    ;;
  delete)
    tear_down
    ;;
  *)
    usage
    ;;
esac
