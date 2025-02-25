#!/bin/bash

# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################

# To run locally, set AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID

set -o errexit
set -o nounset
set -o pipefail

# Install kubectl and helm
REPO_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
KUBECTL="${REPO_ROOT}/hack/tools/bin/kubectl"
HELM="${REPO_ROOT}/hack/tools/bin/helm"
cd "${REPO_ROOT}" && make "${KUBECTL##*/}"; make "${HELM##*/}"
# export the variables so they are available in bash -c wait_for_nodes below
export KUBECTL
export HELM

# shellcheck source=hack/ensure-go.sh
source "${REPO_ROOT}/hack/ensure-go.sh"
# shellcheck source=hack/ensure-kind.sh
source "${REPO_ROOT}/hack/ensure-kind.sh"
# shellcheck source=hack/ensure-kustomize.sh
source "${REPO_ROOT}/hack/ensure-kustomize.sh"
# shellcheck source=hack/ensure-tags.sh
source "${REPO_ROOT}/hack/ensure-tags.sh"
# shellcheck source=hack/parse-prow-creds.sh
source "${REPO_ROOT}/hack/parse-prow-creds.sh"
# shellcheck source=hack/util.sh
source "${REPO_ROOT}/hack/util.sh"

setup() {
    if [[ -n "${KUBERNETES_VERSION:-}" ]] && [[ -n "${CI_VERSION:-}" ]]; then
        echo "You may not set both \$KUBERNETES_VERSION and \$CI_VERSION, use one or the other to configure the version/build of Kubernetes to use"
        exit 1
    fi
    # setup REGISTRY for custom images.
    : "${REGISTRY:?Environment variable empty or not defined.}"
    "${REPO_ROOT}/hack/ensure-acr-login.sh"
    if [[ -n "${TEST_CCM:-}" ]]; then
        # shellcheck source=scripts/ci-build-azure-ccm.sh
        source "${REPO_ROOT}/scripts/ci-build-azure-ccm.sh"
        echo "Will use the ${IMAGE_REGISTRY}/${CCM_IMAGE_NAME}:${IMAGE_TAG} cloud-controller-manager image for external cloud-provider-cluster"
        echo "Will use the ${IMAGE_REGISTRY}/${CNM_IMAGE_NAME}:${IMAGE_TAG} cloud-node-manager image for external cloud-provider-azure cluster"
    fi

    if [[ -z "${CLUSTER_TEMPLATE:-}" ]]; then
        select_cluster_template
    fi

    export CLUSTER_NAME="${CLUSTER_NAME:-capz-$(head /dev/urandom | LC_ALL=C tr -dc a-z0-9 | head -c 6 ; echo '')}"
    export AZURE_RESOURCE_GROUP="${CLUSTER_NAME}"
    export AZURE_LOCATION="${AZURE_LOCATION:-$(capz::util::get_random_region)}"
    # Need a cluster with at least 2 nodes
    export CONTROL_PLANE_MACHINE_COUNT="${CONTROL_PLANE_MACHINE_COUNT:-1}"
    export WORKER_MACHINE_COUNT="${WORKER_MACHINE_COUNT:-2}"
    export EXP_CLUSTER_RESOURCE_SET="true"

    # this requires k8s 1.22+
    if [[ -n "${TEST_WINDOWS:-}" ]]; then
        export WINDOWS_WORKER_MACHINE_COUNT="${WINDOWS_WORKER_MACHINE_COUNT:-2}"
        export K8S_FEATURE_GATES="WindowsHostProcessContainers=true"
    fi
}

select_cluster_template() {
    if [[ "$(capz::util::should_build_kubernetes)" == "true" ]]; then
        # shellcheck source=scripts/ci-build-kubernetes.sh
        source "${REPO_ROOT}/scripts/ci-build-kubernetes.sh"
        export CLUSTER_TEMPLATE="test/dev/cluster-template-custom-builds.yaml"
    elif [[ "${KUBERNETES_VERSION:-}" =~ "latest" ]] || [[ -n "${CI_VERSION:-}" ]]; then
        # export cluster template which contains the manifests needed for creating the Azure cluster to run the tests
        export CLUSTER_TEMPLATE="test/ci/cluster-template-prow-ci-version.yaml"
        if [[ "${KUBERNETES_VERSION:-}" =~ "latest" ]]; then
            CI_VERSION_URL="https://dl.k8s.io/ci/${KUBERNETES_VERSION}.txt"
        fi
    else
        export CLUSTER_TEMPLATE="test/ci/cluster-template-prow.yaml"
    fi
    if [[ -n "${CI_VERSION:-}" ]] || [[ -n "${CI_VERSION_URL:-}" ]]; then
        export CI_VERSION="${CI_VERSION:-$(curl -sSL "${CI_VERSION_URL}")}"
        echo "using CI_VERSION ${CI_VERSION}"
        export KUBERNETES_VERSION="${CI_VERSION}"
        echo "using KUBERNETES_VERSION ${KUBERNETES_VERSION}"
    fi

    if [[ -n "${TEST_CCM:-}" ]]; then
        # replace 'prow' with 'prow-external-cloud-provider' in the template name if testing out-of-tree
        export CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE/prow/prow-external-cloud-provider}"
    fi

    if [[ "${EXP_MACHINE_POOL:-}" == "true" ]]; then
        if [[ "${CLUSTER_TEMPLATE}" =~ "prow" ]]; then
            export CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE/prow/prow-machine-pool}"
        elif [[ "${CLUSTER_TEMPLATE}" =~ "custom-builds" ]]; then
            export CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE/custom-builds/custom-builds-machine-pool}"
        fi
    fi

    echo "Using cluster template: ${CLUSTER_TEMPLATE}"
}

create_cluster() {
    "${REPO_ROOT}/hack/create-dev-cluster.sh"
}

wait_for_nodes() {
    echo "Waiting for ${CONTROL_PLANE_MACHINE_COUNT} control plane machine(s), ${WORKER_MACHINE_COUNT} worker machine(s), and ${WINDOWS_WORKER_MACHINE_COUNT} windows machine(s) to become Ready"

    # Ensure that all nodes are registered with the API server before checking for readiness
    local total_nodes="$((CONTROL_PLANE_MACHINE_COUNT + WORKER_MACHINE_COUNT + WINDOWS_WORKER_MACHINE_COUNT))"
    while [[ $("${KUBECTL}" get nodes -ojson | jq '.items | length') -ne "${total_nodes}" ]]; do
        sleep 10
    done

    "${KUBECTL}" wait --for=condition=Ready node --all --timeout=5m
    "${KUBECTL}" get nodes -owide
}

# cleanup all resources we use
cleanup() {
    timeout 1800 "${KUBECTL}" delete cluster "${CLUSTER_NAME}" || true
    make kind-reset || true
}

on_exit() {
    unset KUBECONFIG
    "${REPO_ROOT}/hack/log/log-dump.sh" || true
    # cleanup
    if [[ -z "${SKIP_CLEANUP:-}" ]]; then
        cleanup
    fi
}

# setup all required variables and images
setup

trap on_exit EXIT
export ARTIFACTS="${ARTIFACTS:-${PWD}/_artifacts}"

# create cluster
create_cluster

# export the target cluster KUBECONFIG if not already set
export KUBECONFIG="${KUBECONFIG:-${PWD}/kubeconfig}"

# install cloud-provider-azure components, if using out-of-tree
if [[ -n "${TEST_CCM:-}" ]]; then
    echo "Installing cloud-provider-azure components via helm"
    "${HELM}" install --repo https://raw.githubusercontent.com/kubernetes-sigs/cloud-provider-azure/master/helm/repo cloud-provider-azure --generate-name --set infra.clusterName="${CLUSTER_NAME}" --set cloudControllerManager.imageRepository="${IMAGE_REGISTRY}" \
--set cloudNodeManager.imageRepository="${IMAGE_REGISTRY}" \
--set cloudControllerManager.imageName="${CCM_IMAGE_NAME}" \
--set cloudNodeManager.imageName="${CNM_IMAGE_NAME}" \
--set cloudControllerManager.imageTag="${IMAGE_TAG}" \
--set cloudNodeManager.imageTag="${IMAGE_TAG}"
fi

export -f wait_for_nodes
timeout --foreground 1800 bash -c wait_for_nodes

if [[ "${#}" -gt 0 ]]; then
    # disable error exit so we can run post-command cleanup
    set +o errexit
    "${@}"
    EXIT_VALUE="${?}"
    exit ${EXIT_VALUE}
fi
