#!/bin/bash

set -euxo pipefail

HELM_VERSION="v3.17.3"
HELM_SHA256_amd64="ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd"
HELM_SHA256_arm64="7944e3defd386c76fd92d9e6fec5c2d65a323f6fadc19bfb5e704e3eee10348e"

KUBECTL_VERSION="v1.35.3"
KUBECTL_SHA256_amd64="fd31c7d7129260e608f6faf92d5984c3267ad0b5ead3bced2fe125686e286ad6"
KUBECTL_SHA256_arm64="6f0cd088a82dde5d5807122056069e2fac4ed447cc518efc055547ae46525f14"

INSTALL_RKE2_VERSION="v1.35.3+rke2r1"

# Path where harvester-csi-driver expects the Harvester cloud-config (chart default
# cloudConfig.hostPath), and the hostPath used for the CSI socket.
HARVESTER_CLOUD_CONFIG_DIR="/var/lib/rancher/rke2/etc/config-files"
HARVESTER_CSI_SOCKET="/var/lib/kubelet/harvester-plugins/driver.harvesterhci.io/csi.sock"

function isSUSE(){
    grep -qi "suse" /etc/os-release
}

function verifyPolicyPresence() {
    local pkgs=("harvester-selinux" "rke2-selinux")
    local types=(
        "rke2_service_t"
        "harvester_csi_container_t"
    )

    for p in "${pkgs[@]}"; do
        rpm -q "$p" >/dev/null 2>&1 || { echo "ERROR: RPM $p not installed"; return 1; }
        local m="${p%-selinux}"
        semodule -l | grep -w "$m" || { echo "ERROR: Module $m not loaded"; return 1; }
    done

    for t in "${types[@]}"; do
        seinfo -t "$t" >/dev/null 2>&1 || { echo "ERROR: Type $t unknown"; return 1; }
    done

    echo "SELinux policies verified successfully."
    return 0
}

function getSuseRepoPath() {
    if grep -qi "microos" /etc/os-release; then
        echo "microos"
    else
        echo "slemicro"
    fi
}

function enforceSELinux(){
    echo "> Check SELinux status"
    getenforce | grep -q Enforcing

    if isSUSE; then
        local SUSE_REPO_PATH
        SUSE_REPO_PATH=$(getSuseRepoPath)

        echo "> Configuring Rancher Common RPM repository for target: ${SUSE_REPO_PATH}"
        cat << EOF | sudo tee /etc/zypp/repos.d/rancher-rke2-common-latest.repo
[rancher-rke2-common-latest]
name=Rancher RKE2 Common Latest
baseurl=https://rpm.rancher.io/rke2/latest/common/${SUSE_REPO_PATH}/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
EOF

        sudo zypper --gpg-auto-import-keys refresh
        # 1. Install harvester-selinux on its own, as users would: container-selinux is pulled in
        #    as a dependency in the same transaction, so scriptlet ordering issues are caught.
        sudo zypper -n --gpg-auto-import-keys install --allow-unsigned-rpm /tmp/harvester-selinux.rpm
        # 2. Install rke2-selinux in a separate transaction
        sudo zypper -n --gpg-auto-import-keys install rke2-selinux
    else
        sudo dnf install "kernel-modules-extra-$(uname -r)" -y
        sudo dnf install -y container-selinux selinux-policy --best --allowerasing
        sudo dnf install -y /tmp/harvester-selinux.rpm
    fi
    # The spec scriptlets exit 0 on failure, so check the module was actually loaded.
    semodule -l | grep -qw harvester || { echo "ERROR: harvester module not loaded after install"; exit 1; }
    # Rebuild policy store and remove dontaudits for debugging
    sudo semodule -DB
}

function installDependencies(){
    echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
    echo 'export TERM=xterm' >> ~/.bashrc

    if isSUSE; then
        sudo zypper -n install jq git setools-console
    else
        sudo dnf install -y jq git setools policycoreutils-python-utils
    fi

    ARCH=$(uname -m)
    [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"
    [[ "${ARCH}" == "x86_64" ]] && ARCH="amd64"

    echo "> Installing Helm ${HELM_VERSION}"
    local HELM_SHA256_VAR="HELM_SHA256_${ARCH}"
    local HELM_SHA256="${!HELM_SHA256_VAR}"
    local HELM_FILE="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    curl -fsSLO "https://get.helm.sh/${HELM_FILE}"
    echo "${HELM_SHA256}  ${HELM_FILE}" | sha256sum -c - --strict
    tar xzf "${HELM_FILE}"
    install -o root -g root -m 0755 linux-${ARCH}/helm /usr/local/bin/helm
    rm -rf linux-${ARCH} "${HELM_FILE}"
    helm version

    echo "> Installing kubectl ${KUBECTL_VERSION} for ${ARCH}"
    local KUBECTL_SHA256_VAR="KUBECTL_SHA256_${ARCH}"
    local KUBECTL_SHA256="${!KUBECTL_SHA256_VAR}"
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
    echo "${KUBECTL_SHA256}  kubectl" | sha256sum -c - --strict
    install -o root -g root -m 0755 kubectl /usr/bin/kubectl
    rm -f kubectl
    kubectl version --client=true
}

function installRKE2(){
    echo "> Installing RKE2 ${INSTALL_RKE2_VERSION} for ${ARCH}"
    curl -sfL https://get.rke2.io -o install.sh
    INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" sh install.sh
    rm -f install.sh
    # Verify SELinux policies presence before triggering the rest of e2e.
    verifyPolicyPresence
    # RKE2 does not enable SELinux in containerd by default: without this, seLinuxOptions are
    # ignored and every container runs in the runtime's domain, making the AVC checks vacuous.
    mkdir -p /etc/rancher/rke2
    echo "selinux: true" >> /etc/rancher/rke2/config.yaml
    systemctl enable --now rke2-server.service

    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> ~/.bashrc
    # Making the kubeconfig world-readable, as this is for test purposes only.
    chmod +r /etc/rancher/rke2/rke2.yaml

    kubectl wait --for=create node/$(hostname) --timeout=240s
    kubectl wait "$(kubectl get node -o name | head -n1)" --for=condition=ready --timeout=240s
    kubectl wait --timeout=240s --for=condition=ready -n kube-system pod -l app.kubernetes.io/instance=rke2-coredns
    kubectl wait --timeout=240s --for=condition=ready -n kube-system pod -l app.kubernetes.io/component=controller
}

# configureHarvesterCloudConfig provides a stand-in Harvester cloud-config.
#
# There is no Harvester cluster in e2e, so the harvester-csi-driver plugin (DaemonSet) is pointed
# at the local RKE2 API server instead. This is enough for the plugin to start and serve the CSI
# socket, which is what the csi-controllers sidecars (running as harvester_csi_container_t)
# need to connect to. The plugin pod is not on the host network, so the node IP is used instead
# of 127.0.0.1.
function configureHarvesterCloudConfig(){
    local NODE_IP
    # Dual-stack nodes report several InternalIPs (e.g. on microos); use the first IPv4 one.
    NODE_IP=$(kubectl get node "$(hostname)" \
        -o jsonpath='{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}' \
        | awk '!/:/ {print; exit}')
    if [[ -z "${NODE_IP}" ]]; then
        echo "ERROR: no IPv4 InternalIP found for node $(hostname)"
        exit 1
    fi

    echo "> Writing stand-in Harvester cloud-config pointing at https://${NODE_IP}:6443"
    mkdir -p "${HARVESTER_CLOUD_CONFIG_DIR}"
    sed "s#https://127.0.0.1:6443#https://${NODE_IP}:6443#" /etc/rancher/rke2/rke2.yaml \
        > "${HARVESTER_CLOUD_CONFIG_DIR}/cloud-provider-config"
    chmod 0600 "${HARVESTER_CLOUD_CONFIG_DIR}/cloud-provider-config"

    # The chart ships a VolumeSnapshotClass, which requires RKE2's snapshot CRDs to be established.
    kubectl wait --for=create crd/volumesnapshotclasses.snapshot.storage.k8s.io --timeout=240s
    kubectl wait --for=condition=established crd/volumesnapshotclasses.snapshot.storage.k8s.io --timeout=120s

    # Before serving the CSI socket, the plugin reads the Harvester server-version Setting and lists
    # KubeVirt VMIs (to map the node to its VM). Neither exists on a plain RKE2 cluster, so provide
    # minimal stubs. An empty VMI list makes the plugin fall back to the hostname as node ID.
    echo "> Creating stub Harvester/KubeVirt CRDs required by harvester-csi-driver at startup"
    kubectl apply -f - << 'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: settings.harvesterhci.io
spec:
  group: harvesterhci.io
  scope: Cluster
  names: {kind: Setting, plural: settings, singular: setting}
  versions:
  - name: v1beta1
    served: true
    storage: true
    schema:
      openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: virtualmachineinstances.kubevirt.io
spec:
  group: kubevirt.io
  scope: Namespaced
  names: {kind: VirtualMachineInstance, plural: virtualmachineinstances, singular: virtualmachineinstance, shortNames: [vmi]}
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
    kubectl wait --for=condition=established crd/settings.harvesterhci.io crd/virtualmachineinstances.kubevirt.io --timeout=60s
    kubectl apply -f - << 'EOF'
apiVersion: harvesterhci.io/v1beta1
kind: Setting
metadata:
  name: server-version
value: v1.8.0
EOF
}

# installChart installs a Harvester chart and waits for its workloads to be ready.
#
# Positional arguments:
#   $1  CHART_NAME         Helm release name.
#   $2  NAMESPACE          Target namespace.
#   $3  WORKLOAD_KIND      "daemonset" or "deployment".
#   $4  WORKLOAD_NAMES     Comma-separated list of workload names owned by this chart.
#   $5  POD_LABEL_SELECTOR Comma-separated list of label selectors used to wait for pod readiness.
#   $6  CHART_REF          Helm chart reference, e.g. "harvester/harvester-csi-driver".
#   $7+ EXTRA_HELM_ARGS    Additional arguments forwarded to `helm upgrade --install`.
#                          MUST set the SELinux type for the workload under test.
function installChart() {
    local CHART_NAME="$1"
    local NAMESPACE="$2"
    local WORKLOAD_KIND="$3"
    local WORKLOAD_NAMES="$4"
    local POD_LABEL_SELECTOR="$5"
    local CHART_REF="$6"
    local EXTRA_HELM_ARGS="${@:7}"

    helm repo add harvester https://charts.harvesterhci.io >/dev/null 2>&1 || true
    helm repo update harvester

    echo "> Installing chart ${CHART_NAME} (${CHART_REF})"
    helm upgrade --install=true \
        --namespace="${NAMESPACE}" --timeout=20m0s --wait=true \
        --create-namespace \
        "${CHART_NAME}" "${CHART_REF}" \
        ${EXTRA_HELM_ARGS}

    local IFS_BAK="$IFS"; IFS=','
    for w in ${WORKLOAD_NAMES}; do
        kubectl wait --for=create -n "${NAMESPACE}" "${WORKLOAD_KIND}/${w}" --timeout=240s
        kubectl rollout status -n "${NAMESPACE}" "${WORKLOAD_KIND}/${w}" --timeout=300s
    done
    for sel in ${POD_LABEL_SELECTOR}; do
        kubectl wait --for=condition=ready -n "${NAMESPACE}" pod -l "${sel}" --timeout=300s
    done
    IFS="$IFS_BAK"
}

# verifyCSISocket ensures the CSI plugin created its socket, so the sidecars actually exercise
# the policy (connecting to the socket) rather than passing the AVC check vacuously.
function verifyCSISocket(){
    echo "> Waiting for CSI socket ${HARVESTER_CSI_SOCKET}"
    kubectl wait --for=condition=ready -n kube-system pod -l component=csi-driver --timeout=300s
    timeout 120 bash -c "until [ -S ${HARVESTER_CSI_SOCKET} ]; do sleep 2; done"
    ls -lZ "${HARVESTER_CSI_SOCKET}"

    # The sidecars may have started (and gone into back-off) before the socket existed, and a pod
    # can briefly report Ready before crash-looping. Restart them now that the plugin is serving,
    # then confirm they stay Ready once connected.
    echo "> Restarting csi-controllers now that the CSI socket is available"
    kubectl rollout restart -n kube-system deployment/harvester-csi-driver-controllers
    kubectl rollout status -n kube-system deployment/harvester-csi-driver-controllers --timeout=300s
    kubectl wait --for=condition=ready -n kube-system pod -l component=csi-controllers --timeout=300s
    # Give the sidecars time to connect to the CSI socket and the API server.
    sleep 30
    kubectl wait --for=condition=ready -n kube-system pod -l component=csi-controllers --timeout=10s
    kubectl get pods -n kube-system -l app.kubernetes.io/name=harvester-csi-driver -o wide
}

# Example: e2eSELinuxVerification "harvester-csi-driver-controllers" "csi-provisioner" "kube-system" "harvester_csi_container_t".
function e2eSELinuxVerification(){
    local POD_NAME_PREFIX="$1"
    local CONTAINER_RUNNING_NAME="$2"
    local POD_NAMESPACE="$3"
    local POD_NAME=$(kubectl get pods -n ${POD_NAMESPACE} -o custom-columns=NAME:.metadata.name | grep "${POD_NAME_PREFIX}" | head -n1)
    local CONTAINER_EXPECTED_SLTYPE="$4"
    local CONTAINER_RUNNING_SLTYPE=""

    echo "> Verify the presence of ${CONTAINER_EXPECTED_SLTYPE}"
    if [[ "$(seinfo -t ${CONTAINER_EXPECTED_SLTYPE} | grep -o ${CONTAINER_EXPECTED_SLTYPE})" == "${CONTAINER_EXPECTED_SLTYPE}" ]]; then
        echo "SELinux type is present: ${CONTAINER_EXPECTED_SLTYPE}"
    else
        echo "SELinux type is not present: ${CONTAINER_EXPECTED_SLTYPE}"
    fi

    echo "> Verify expected SELinux context type ${CONTAINER_EXPECTED_SLTYPE} for container ${CONTAINER_RUNNING_NAME} in pod ${POD_NAME}"
    # Get SELinux type from Pod-level securityContext, falling back to Container-level if empty
    CONTAINER_RUNNING_SLTYPE=$(kubectl get pod ${POD_NAME} -n ${POD_NAMESPACE} -o json | jq -r ".spec.securityContext.seLinuxOptions.type // (.spec.containers[] | select(.name==\"${CONTAINER_RUNNING_NAME}\") | .securityContext.seLinuxOptions.type)")
    if [[ "${CONTAINER_RUNNING_SLTYPE}" == "${CONTAINER_EXPECTED_SLTYPE}" ]]; then
        echo "SELinux type is correct: ${CONTAINER_RUNNING_SLTYPE}"
    else
        echo "SELinux type is incorrect or not set: ${CONTAINER_RUNNING_SLTYPE}"
        exit 1
    fi

    echo "> Verify running processes are confined to ${CONTAINER_EXPECTED_SLTYPE}"
    ps -eZ | grep "${CONTAINER_EXPECTED_SLTYPE}" || { echo "No process running as ${CONTAINER_EXPECTED_SLTYPE}"; exit 1; }

    echo "> Look for any AVCs related to ${CONTAINER_RUNNING_SLTYPE}"
    if ausearch -m AVC,USER_AVC | grep "${CONTAINER_RUNNING_SLTYPE}" > /dev/null; then
        echo "AVCs found for ${CONTAINER_RUNNING_SLTYPE}"
        ausearch -m AVC,USER_AVC | grep "${CONTAINER_RUNNING_SLTYPE}"
        exit 1
    else
        echo "No AVCs found for ${CONTAINER_RUNNING_SLTYPE}"
    fi
}

function main(){
    enforceSELinux
    installDependencies
    installRKE2
    configureHarvesterCloudConfig

    # Note: Append this list with new components to install and test the harvester-selinux policy.
    #
    # Per-component layout (space-separated):
    #   NAMESPACE WORKLOAD_KIND WORKLOAD_NAMES POD_LABELS VERIFY_TRIPLETS CHART_REF EXTRA_HELM_ARGS
    #
    # - WORKLOAD_KIND:   daemonset|deployment
    # - WORKLOAD_NAMES:  comma-separated list of workload names owned by the chart.
    # - POD_LABELS:      comma-separated list of label selectors used for readiness waits.
    # - VERIFY_TRIPLETS: ';'-separated list of 'podNamePrefix:containerName:expected_selinux_type'
    # - CHART_REF:       "harvester/<name>" (https://charts.harvesterhci.io)
    # - EXTRA_HELM_ARGS: forwarded verbatim to `helm upgrade --install`. MUST set the SELinux type.
    #
    # harvester-csi-driver: seLinuxOptions.level=s0 is required. With type only, containerd gives
    # each container its own MCS categories and the sidecars get denied on the pod's shared
    # projected volume (service account token).
    declare -A COMPONENTS=(
        [harvester-csi-driver]="kube-system deployment harvester-csi-driver-controllers component=csi-controllers harvester-csi-driver-controllers:csi-provisioner:harvester_csi_container_t;harvester-csi-driver-controllers:csi-attacher:harvester_csi_container_t;harvester-csi-driver-controllers:csi-resizer:harvester_csi_container_t;harvester-csi-driver-controllers:csi-snapshotter:harvester_csi_container_t harvester/harvester-csi-driver --version 0.1.33 --set replicasCount=1 --set podSecurityContext.seLinuxOptions.type=harvester_csi_container_t --set podSecurityContext.seLinuxOptions.level=s0"
    )

    for CHART_NAME in "${!COMPONENTS[@]}"; do
        # Read the space-separated values into individual variables.
        read -r NAMESPACE WORKLOAD_KIND WORKLOAD_NAMES POD_LABELS VERIFY_TRIPLETS CHART_REF EXTRA_HELM_ARGS <<< "${COMPONENTS[${CHART_NAME}]}"

        echo "> Installing and testing Chart: ${CHART_NAME} in Namespace: ${NAMESPACE}"

        # 1. Install the chart.
        installChart \
            "${CHART_NAME}" \
            "${NAMESPACE}" \
            "${WORKLOAD_KIND}" \
            "${WORKLOAD_NAMES}" \
            "${POD_LABELS}" \
            "${CHART_REF}" \
            "${EXTRA_HELM_ARGS}"

        verifyCSISocket

        # 2. Run E2E SELinux verification for every (podPrefix,container,type) triplet.
        IFS_BAK="$IFS"; IFS=';'
        for triplet in ${VERIFY_TRIPLETS}; do
            IFS=':' read -r POD_PREFIX C_NAME C_TYPE <<< "${triplet}"
            echo "> Verifying pod ${POD_PREFIX} / container ${C_NAME} against SELinux type ${C_TYPE}"
            e2eSELinuxVerification "${POD_PREFIX}" "${C_NAME}" "${NAMESPACE}" "${C_TYPE}"
        done
        IFS="$IFS_BAK"
    done

    # No uninstall step: the chart lives in kube-system and the VM is discarded after the run.
}

# Rocky does not include this in the PATH by default, which is required for Helm.
export PATH=$PATH:/usr/local/bin

main
