# oke-weka — troubleshooting & hard-won gotchas

Real failure modes hit while getting this one-click stack working end-to-end, with root causes and
fixes. Symptoms mostly surface the same way — **`helm_release.weka_operator … context deadline
exceeded`** — because the operator can't go Ready until nodes join, so almost anything upstream shows
up as a Helm timeout. Diagnose by looking at *nodes first*, not Helm.

Quick triage:

```bash
# after `terraform output -raw create_kubeconfig_command | bash` (or oci ce ... create-kubeconfig)
kubectl get nodes                      # 0 nodes? → worker bootstrap problem (§1)
kubectl -n weka-operator-system get pods
kubectl get events -A --sort-by=.lastTimestamp | tail
```

---

## 1. Self-managed (instance-pool / non-production) workers never join → 0 nodes

**Symptom:** `flavor = non-production`: cluster ACTIVE, worker VMs RUNNING, but `kubectl get nodes` is
empty; operator + even coredns stuck `Pending` ("no nodes available"); Helm times out. Production
(node-pool) is fine.

**Root cause:** the worker cloud-init used to fetch the OKE bootstrap from IMDS
(`curl .../opc/v2/instance/metadata/oke_init_script | bash`). That metadata key is **only served to
managed node-pool instances** — on **self-managed instance-pool** workers it returns **404**, so the
bootstrap never ran. kubelet then came up with its default container-runtime endpoint
(`/run/containerd/containerd.sock`) and crash-looped, because **the OKE OL8 image for k8s ≥ 1.34 uses
CRI-O, not containerd** (`/run/crio/crio.sock`). No runtime → node never registers.

**Fix (v1.6.6):** set `disable_default_cloud_init = false` so `terraform-oci-oke` runs its own native
bootstrap (`cloudinit-oke.sh` + the `/etc/oke/oke-apiserver` and `/etc/kubernetes/ca.crt` files it
writes, driven by the image's `oke-init.service`). That path joins **both** pool modes. WEKA node
tuning (hugepages, static CPU-manager policy) now rides along as a *supplementary* `cloud_init` MIME
part — and because the module prepends custom parts **before** its bootstrap part, that script must
self-wait for kubelet to be configured before touching it.

> The earlier "kubelet CPU-manager checkpoint" fix (v1.6.2) was a red herring — the bootstrap script
> was empty (404), so that code never ran. It's harmless but not what fixes node join.

## 2. `helm … context deadline exceeded` right after the cluster comes up

**Symptom:** first apply of a fresh cluster fails with
`Kubernetes cluster unreachable: dial tcp <public-ip>:6443: i/o timeout`, but the endpoint is
reachable a minute later.

**Root cause:** OKE reports the cluster `ACTIVE` before the **public API endpoint IP is actually
routable**, and the `kubernetes`/`helm` providers do not retry a connection timeout.

**Fix (v1.6.4):** `null_resource.wait_for_kube_api` polls `https://<host>/version` until it answers;
the operator namespace + `helm_release` depend on it.

## 3. `terraform destroy` fails at `localhost:80`

**Symptom:** `Error: … Get "http://localhost/api/v1/namespaces/weka-operator-system": dial tcp
[::1]:80: connection refused` — destroy dies on the first Kubernetes resource, before touching any OCI
infra.

**Root cause:** the k8s/helm/kubectl providers derived `host`/CA from a **kube-config data source**
keyed on `module.oke.cluster_id`. Terraform can't read that data source during destroy (its dependency
is in the destroy set), so `host` resolves empty → provider falls back to `localhost`.

**Fix (v1.6.5):** freeze endpoint + CA (from `module.oke.cluster_endpoints` / `cluster_ca_cert`, which
require `output_detail = true`) into a `terraform_data` resource; providers read
`terraform_data.kube_connect.output`. Resource attributes are served from state during destroy, so the
k8s resources delete cleanly before the cluster.

## 4. `terraform destroy` of a *live* cluster hangs, then times out on the namespace

**Symptom:** `kubernetes_namespace_v1.operator: Still destroying … [5m elapsed] → context deadline
exceeded`. The namespace is stuck `Terminating` with nothing visibly left in it.

**Root cause:** the running operator creates `wekacontainers.weka.weka.io` CRs carrying
`weka.weka.io/finalizer`. Deleting the operator namespace removes the operator **before** it can clear
those finalizers → deadlock.

**Manual unstick:**

```bash
for c in $(kubectl get wekacontainers -n weka-operator-system -o name); do
  kubectl patch -n weka-operator-system "$c" --type=merge -p '{"metadata":{"finalizers":null}}'
done
kubectl get ns weka-operator-system -o json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);d['spec']['finalizers']=[];print(json.dumps(d))" \
  | kubectl replace --raw /api/v1/namespaces/weka-operator-system/finalize -f -
# then re-run terraform destroy
```

**Fix (v1.6.7):** a `when = destroy` provisioner clears WEKA CR finalizers before the operator is
removed (see `weka.tf`).

## 5. Stack deployed to the wrong region (Phoenix)

**Root cause:** `var.region` defaulted to `us-phoenix-1` while being a *hidden* ORM input, so a stack
created in another region silently deployed to Phoenix.

**Fix (v1.6.5):** removed the default. ORM auto-populates the reserved `region` variable with the
stack's own region; local runs set it in tfvars.

## 6. DenseIO out-of-host-capacity (production)

Expected OCI availability constraint, not a bug — the production DenseIO shapes
(`VM.DenseIO.E5.Flex`, `BM.DenseIO.E4/E5.128`) are scarce. The stack's `capacity.tf` preflight
fails fast at apply. Retry, choose a smaller `production_tier` capacity, pin ADs via `worker_placement_ads`,
try another region, or use the dev (non-production) zip (Standard shapes, abundant quota).

## 7. Workers never join because the WEKA tuning part blocked cloud-init (`enable --now`)

**Symptom:** identical to §1 — cluster ACTIVE, worker VMs RUNNING, `kubectl get nodes` empty, operator
pod `Pending`, Helm `context deadline exceeded`. But this bites **both** flavors, *after* the §1 fix.
Serial console of a worker shows kubelet crash-looping on `/run/containerd/containerd.sock` in
`"Standalone mode, no API client"`, **plus** `[FAILED] Failed to start Execute cloud user/final
scripts` and cloud-init `modules:final` finishing tens of minutes late.

**Root cause:** the WEKA CPU-manager oneshot was started from the cloud-config `runcmd` with
`systemctl enable --now weka-cpu-tuning.service`. `runcmd` runs in cloud-init's **scripts-user (final)**
stage, and `--now` starts the unit **synchronously**, so `cloud-final` blocks on the oneshot's
`ExecStart` — which self-waits **up to ~15 min** for the kubelet config. The module kicks off its own
`oke-init.service` later in that same final stage, so blocking `cloud-final` **starves the bootstrap**:
kubelet never gets its CRI-O + API-server config, keeps crash-looping on the default containerd
socket, and the node never registers. (The `--now` reintroduces exactly the blocking the systemd-unit
design in §1 was meant to avoid.)

**Fix (v1.6.8):** start the oneshot **asynchronously** — `systemctl enable weka-cpu-tuning.service`
(persistence) followed by `systemctl start --no-block weka-cpu-tuning.service`. `--no-block` enqueues
the start and returns immediately, so `cloud-final` completes, `oke-init.service` runs, the node joins,
and the tuning unit still runs in the background ordered `After=kubelet.service`.

## 8. Self-managed workers rejected with 403 "node not authorized" (missing CLUSTER_JOIN IAM)

**Symptom:** only after §7 is fixed and the bootstrap actually runs. `flavor = non-production`
(instance-pool): worker VMs boot, `oke-init` runs, but the node's bootstrap request is refused and it
never registers. Serial console of a worker shows the `oke[...]` process retrying:

```
GET https://10.0.0.10:12250/workerNodeBootstrap
Http Status Code: 403 … Error Code: Forbidden … Message: node not authorized
```

Production (managed node-pool) is unaffected — OKE authorizes managed-nodepool nodes internally.

**Root cause:** **self-managed** (instance-pool) nodes authorize to the cluster via **instance
principal**: the worker instances must be in a **dynamic group** that holds an
`Allow dynamic-group <grp> to {CLUSTER_JOIN} in compartment id <c> where target.cluster.id = '<id>'`
policy. terraform-oci-oke creates both (module `iam` → `group-workers.tf`), but only when
`create_iam_resources = true`. This stack set `create_iam_resources = false` ("minimal, low-permission
dev cluster"), which is fine for managed node-pools but leaves self-managed nodes with **no
CLUSTER_JOIN grant → 403**. `create_iam_worker_policy` already defaults to `"auto"` (true for
instance-pool) and the module feeds it `cluster_id`, so the grant materializes the moment
`create_iam_resources` is on.

**Fix (v1.6.8):** make it mode-conditional in `main.tf` —
`create_iam_resources = local.worker_mode == "instance-pool"`. Production stays IAM-free; non-production
gets exactly the worker dynamic-group + CLUSTER_JOIN policy (operator/autoscaler/kms/karpenter policies
stay `auto`=false with this config; `use_defined_tags` is off, so no tag-namespace either).
**Requires** the deploying principal to be able to create dynamic groups + policies in the tenancy root.

Manual unstick for an already-running cluster (no redeploy) — create the grant, then recycle the pool
instances so a fresh bootstrap attempt picks it up (the bootstrap agent gives up after a few minutes):

```bash
oci iam dynamic-group create --name oke-workers-fix \
  --matching-rule "ANY {instance.compartment.id = '$WORKER_COMPARTMENT'}" \
  --description "self-managed OKE workers"
oci iam policy create --compartment-id "$WORKER_COMPARTMENT" --name oke-workers-cluster-join \
  --statements "[\"Allow dynamic-group oke-workers-fix to {CLUSTER_JOIN} in compartment id $WORKER_COMPARTMENT where target.cluster.id = '$CLUSTER_ID'\"]"
# then terminate the pool's instances; the pool relaunches them and they authorize + join
```

---

## Debugging private workers without SSH or a bastion

Worker nodes have no public IP and this stack provisions no bastion. **OCI Run Command** (Oracle Cloud
Agent) *would* run a script on the node over the agent with no network path — **but only if the
instance's agent has the "Compute Instance Run Command" plugin enabled.** These workers launch with
`agent-config.plugins-config = null` (no plugins enabled), so a `command create` sits at
`delivery-state = VISIBLE` forever and never runs. Enable the plugin in the pool's instance
configuration first, or fall back to the **serial console** (works regardless of agent state):

```bash
CH=$(oci compute console-history capture --instance-id "$IID" --region "$REGION" \
  --query 'data.id' --raw-output)
oci compute console-history get-content --instance-console-history-id "$CH" --region "$REGION" \
  --file - --length 400000 | grep -iE 'oke-init|kubelet|crio|containerd|cloud-init|final scripts|error'
```

If the plugin *is* enabled, Run Command works like this:

```bash
cat > /tmp/diag.json <<'JSON'
{"source":{"sourceType":"TEXT","text":"systemctl is-active crio kubelet; ls -l /run/crio/crio.sock; journalctl -u kubelet --no-pager | tail -40; tail -120 /var/log/cloud-init-output.log"},"output":{"outputType":"TEXT"}}
JSON
CMD=$(oci instance-agent command create --compartment-id "$COMP" --timeout-in-seconds 90 \
  --target "{\"instanceId\":\"$IID\"}" --content file:///tmp/diag.json \
  --region "$REGION" --query 'data.id' --raw-output)
oci instance-agent command-execution get --command-id "$CMD" --instance-id "$IID" \
  --region "$REGION" --query 'data.content.text' --raw-output
```

Serial console logs are also available via `oci compute console-history capture` then `get-content`.
