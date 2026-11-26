# harvester-selinux

`harvester-selinux` contains a set of SELinux policies designed to grant the necessary privileges to various Harvester components running on Linux systems with SELinux enabled. These policies enhance security by defining dedicated types for containers and assigning them the least privileges possible.

## Installation

Pick the repository path for your OS from the [support matrix](#support-matrix).

**RHEL / CentOS / Rocky / Fedora**

```bash
cat << EOF > /etc/yum.repos.d/harvester.repo
[harvester]
name=Harvester
baseurl=https://rpm.rancher.io/harvester/production/<repo-path>/noarch
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
EOF

dnf install -y harvester-selinux
```

**openSUSE / SLE / SLE Micro**

```bash
cat << EOF > /etc/zypp/repos.d/harvester.repo
[harvester]
name=Harvester
baseurl=https://rpm.rancher.io/harvester/production/<repo-path>/noarch
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
EOF

zypper --gpg-auto-import-keys refresh
zypper install -y harvester-selinux
```

On transactional systems (SLE Micro, MicroOS), use `transactional-update pkg install harvester-selinux` and reboot.

Verify the modules are loaded:

```bash
semodule -l | grep harvester
```

Installing the RPM is not enough on its own: charts must be configured to run in the provided SELinux types. For `harvester-csi-driver` (>= 0.1.33), set:

```bash
--set podSecurityContext.seLinuxOptions.type=harvester_csi_container_t \
--set podSecurityContext.seLinuxOptions.level=s0
```

The `level` is required: when only `type` is set, containerd assigns each container in the pod a different MCS category pair, and the sidecars can no longer access the pod's shared volumes (e.g. the projected service account token).

## Support Matrix

| Operating System                | Version | Build target | Repo path   | RPM extension |
| :------------------------------ | :------ | :----------- | :---------- | :------------ |
| openSUSE Leap / SLE / SLE Micro | 16 / 6  | `sle`        | `sle/16`    | `.sle`        |
| openSUSE MicroOS / Tumbleweed   | Rolling | `microos`    | `microos`   | `.microos`    |
| RHEL / CentOS / Rocky           | 9       | `centos9`    | `centos/9`  | `.el9`        |
| RHEL / CentOS / Rocky           | 10      | `centos10`   | `centos/10` | `.el10`       |
| Fedora                          | 43      | `fedora43`   | `fedora/43` | `.fc43`       |

All distributions are built from a single [policy] (`policy/harvester.te`). Per-distribution packaging details (RPM extension, minimum `selinux-policy` and `container-selinux` versions, SUSE-specific dependencies) live in `policy/harvester-selinux.spec`.

All distributions are covered by end-to-end tests in CI.

## Coverage

| Component            | Container                                                         | SELinux type                | Status      |
| :------------------- | :---------------------------------------------------------------- | :-------------------------- | :---------- |
| Harvester CSI Driver | [csi-controllers] (provisioner, attacher, resizer, snapshotter)   | `harvester_csi_container_t` | Development |

> **Note:** Only the components listed above get a dedicated SELinux type. Other Harvester components and workloads use the default `container_t` type from `container-selinux`.

## Development

Requires Docker (or set `RUNNER=podman`). End-to-end tests require [Lima](https://lima-vm.io).

| Command               | Description                                                |
| :-------------------- | :--------------------------------------------------------- |
| `make build`          | Build the RPM for all distributions                        |
| `make <distro>-build` | Build the RPM for one distribution (e.g. `make sle-build`) |
| `make e2e-<distro>`   | Run end-to-end tests in a VM (e.g. `make e2e-sle`)         |

Artefacts are written to `build/<distro>/`.

The e2e tests run a single-node RKE2 cluster and install `harvester-csi-driver` with its controllers in `harvester_csi_container_t`. As there is no Harvester cluster, the CSI plugin is given a stand-in cloud-config pointing at the local RKE2 API server, which is enough for it to serve the CSI socket used by the sidecars.

### Adding a new distribution

1. Add a `%if "%{distro}" == "<name>"` block to `policy/harvester-selinux.spec` with its RPM extension and minimum package versions.
2. Add a matching `<name>` build stage to the `Dockerfile` and add `<name>` to `POLICIES` in the `Makefile`.
3. Add `hack/e2e/<name>.yaml` (Lima template) and the distro to `.github/workflows/e2e.yml`.
4. Map the policy to its repo path in `hack/upload`.
5. Update the support matrix above.

## Releasing

Tags follow the format `v{version}.{channel}.{release}`, which maps directly to RPM naming:

- `version`: harvester-selinux version, e.g. `0.1`, `0.2`
- `channel`: `testing` or `production`
- `release`: RPM release, starting at `1`

Testing RPMs are published to `https://rpm-testing.rancher.io/harvester/testing/<repo-path>/noarch`.

| Tag                     | Output RPM                                        | Channel    |
| :---------------------- | :------------------------------------------------ | :--------- |
| `main` (no tag)         | `harvester-selinux-0.0~0d52f7d8-0.el9.noarch.rpm` | Testing    |
| `v0.2-alpha1.testing.1` | `harvester-selinux-0.2~alpha1-1.el9.noarch.rpm`   | Testing    |
| `v0.2-rc1.testing.1`    | `harvester-selinux-0.2~rc1-1.el9.noarch.rpm`      | Testing    |
| `v0.2.testing.1`        | `harvester-selinux-0.2-1.el9.noarch.rpm`          | Testing    |
| `v0.2.production.1`     | `harvester-selinux-0.2-1.el9.noarch.rpm`          | Production |

[policy]: https://github.com/harvester/harvester-selinux/tree/main/policy
[csi-controllers]: https://github.com/harvester/charts/blob/master/charts/harvester-csi-driver/templates/deployment.yaml
