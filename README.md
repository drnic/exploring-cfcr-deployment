# Deploy Cloud Foundry Container Runtime (formerly Kubo)

This project is an alternate set of deployment manifest/operator files/operator scripts than the upstream https://github.com/cloudfoundry-incubator/kubo-deployment and its documentation at https://docs-cfcr.cfapps.io

At the time of writing I found the instructions very coupled an assumption that you start with nothing and bootstrap everything their way. Except, for me, 100% of the time I already have an environment, a BOSH, and possibly a Cloud Foundry. So I wanted a `bosh deploy manifests/cfcr.yml` that did not make assumptions.

At the time of starting this project I do not know Kubernetes and have not attempted to follow step-for-step the upstream instructions at https://docs-cfcr.cfapps.io. For this reason I decided to start with a blank slate and build out a set of manifests incrementally.

To maximize the chance that my templates will replace the upstream templates, I'll will always start with the same `manifests/kubo.yml` file. So, I've got the upstream `kubo-deployment` as a submodule.

```
export BOSH_DEPLOYMENT=cfcr-kubo
export master_host=10.10.1.241

git clone https://github.com/drnic/cfcr-deployment
bosh deploy cfcr-deployment/src/kubo-deployment/manifests/kubo.yml \
  -o cfcr-deployment/operators/final-releases.yml \
  -o cfcr-deployment/operators/latest-stemcell.yml \
  -o cfcr-deployment/operators/no-disk-types.yml \
  -o cfcr-deployment/operators/some-jobs.yml \
  -o <(cfcr-deployment/operators/pick-from-cloud-config.sh cfcr-deployment/src/kubo-deployment/manifests/kubo.yml) \
  -o cfcr-deployment/operators/master-ip.yml \
  -v deployment_name=$BOSH_DEPLOYMENT \
  -v kubernetes_master_host=$master_host \
  -n
```

Instructions for setting up `kubctl config`, to create local configuration file `~/.kube/config`.

```
director_name=$BOSH_ENVIRONMENT # probably
deployment_name=$BOSH_DEPLOYMENT
address="https://${master_host}:8443"
admin_password=$(bosh int <(credhub get -n "${director_name}/${deployment_name}/kubo-admin-password" --output-json) --path=/value)
context_name="kubo-${deployment_name}"

tmp_ca_file="$(mktemp)"
bosh int <(credhub get -n "${director_name}/${deployment_name}/tls-kubernetes" --output-json) --path=/value/ca > "${tmp_ca_file}"

kubectl config set-cluster "${deployment_name}" \
  --server="$address" \
  --certificate-authority="${tmp_ca_file}" \
  --embed-certs=true
kubectl config set-credentials "${deployment_name}-admin" --token="${admin_password}"
kubectl config set-context "${context_name}" --cluster="${deployment_name}" --user="${deployment_name}-admin"
kubectl config use-context "${context_name}"
```

Also, the helper `scripts/setup-kubectl.sh` contains the same code.

Hopefully one day `kubectl config set-cluster --certificate-authority=<(bosh int ...) --embed-certs=true` will work as expected. But as of v1.8.4 it is necessary still to create an explicit temporary file to pass in the root certificate.

A quick sanity test of our local configuration:

```
$ kubectl config get-clusters
NAME
cfcr-kubo

$ kubectl get pods
No resources found.

$ kubectl cluster-info
Kubernetes master is running at https://10.10.1.241:8443
```

## In progress thoughts

### Step 1: deploy `master/0` with just etcd running, and no workers.

See git 2438770453c4aa89ed51d2f1bceaf45446a695d3.

Just to get this project doing something simple. I removed jobs + instance groups using operator file `operators/some-jobs.yml`.

The manifest `kubo.yml` does not reference a published URL for `/releases/name=kubo`. So I created `operators/final-releases.yml` to add in the URL/sha1 for v0.9.0. On the plus side, https://github.com/cloudfoundry-incubator/kubo-release/releases includes final release tarballs. On the negative sides, the release notes don't include the `sha1` value; nor is kubo-release being published to https://bosh.io/releases yet (which would publish `sha1`); nor does the current git repo include the v0.9.0 final release files [https://github.com/cloudfoundry-incubator/kubo-release/issues/131]

I personally find hard-coded stemcells in base manifests to be a little tedious for operators: the `bosh` CLI and director have no way to automatically download a required stemcell. Very rarely is there a specific reason to fix a deployment to a specific stemcell. If there is a specific feature, then perhaps document this reason inside the deployment manifest `/stemcells` section. I created `operators/latest-stemcell.yml` but I believe the base manifest should allow any stemcell version by default. Operators can control which stemcell they want to deploy using operator files.

Base manifests would be more awesome if they avoided any guesses about cloud-config. This is easy for `persistent_disk_type` - use `persistent_disk` instead which does not require matching cloud-config and each CPI has useful default `cloud_properties`. I created `operators/no-disk-types.yml` to make this switch.

The `kubo.yml` manifest has some extraneous default variables. I don't think we need variables for `name: (deployment_name)` and `networks: [name: &network-name ((deployments_network))]`. Give them default values (e.g. `cfcr` and `default` respectively). Operators can use operator files to adjust them.

The two `instance_groups` specify `vm_type` values that would not be found on any default cloud-config (`vm_type: master` and `vm_type: worker` for the two instance_groups). Instead, perhaps use `vm_type: default` as a solid "probably will work" default; and then an operator can use an operator file to change them to a specific value that matches their known cloud-config. I also added `-o <(operators/pick-from-cloud-config.yml)` to automatically pick the first `vm_type` and first `network` as a handy script for operators.

`/releases/name=haproxy` is included in `kubo.yml` but not used at all; perhaps its used by subsequent operator files. Instead, remove it from base manifest and the subsequent operator files can add `haproxy` back in themselve.s

### Step 2: run `docker` on the `workers`.

See git a89968a097547f3a99c176ef679b48351a5ddd5b.

Since `{name: docker, release: docker}` job had `properties.flannel: true` I also needed to add the `{name: flanneld, release: kubo}` job.

We also now need to generate the certificates into credhub. The generated variable `tls-kubernetes` includes the `((kubernetes_master_host))` variable, which is the static IP/hostname of the `master/0` instance (or perhaps a load balancer in front; see `haproxy` above).

So I assigned a static IP to `master/0` using an operator file `operators/master-ip.yml`. It still uses the `((kubernetes_master_host))` variable name which is the convention in other parts of the base manifest `kubo.yml`.

I now had `kubectl config` setup instructions working. I was sad to discovery I could not use process substitution to pass in the root certificate (I borrowed the `kube-deployment/bin/set_kubeconfig` examples and created a temporary file). I created a ticket https://github.com/kubernetes/kubernetes/issues/56372

I now noticed that the `kubo-deployment/bin` scripts assume that `bosh` is installed as `bosh-cli`. This is not the convention. The new `bosh-cli` project is normally installed as an executable `bosh` (BTW https://apt.starkandwayne.com/ `bosh-cli` package installs the CLI as both `bosh` and `bosh2`).

At this point, my deployment of `master/0` and three `worker` instances contained the following job templates:

```

Instance                                     Process                   Process State  AZ  IPs
master/4616497e-a195-41fe-b4d2-b347969c4b04  -                         running        z1  10.10.1.241
~                                            etcd                      running        -   -
~                                            etcd_consistency_checker  running        -   -
~                                            kubernetes-api            running        -   -
worker/38196375-c65d-4484-beb6-20be672da742  -                         running        z1  10.10.1.21
~                                            docker                    running        -   -
~                                            flanneld                  running        -   -
...
```

I've started reading the `kubo-release` job template scripts and see references to `master.kubo` hostname. Also, during `bosh deploy` of the system above I get the following warning four times:

```
Task 778 | 06:25:54 | Warning: DNS address not available for the link provider instance: master/4616497e-a195-41fe-b4d2-b347969c4b04
```

Whilst `kubectl get pod` doesn't fail, we haven't wired up the workers to the API, so other commands fail:

```
$ kubectl top node
Error from server (NotFound): the server could not find the requested resource (get services http:heapster:)
$ kubectl top pod
Error from server (NotFound): the server could not find the requested resource (get services http:heapster:)
```

### Step 3. Enabling DNS.

It looks like `kubo-release` is using [BOSH DNS](https://bosh.io/docs/dns.html) which requires two changes to a BOSH env:

* Update `bosh create-env` with `-o src/bosh-deployment/src/local-dns.yml` operator file
* Add a runtime config to add `bosh-dns` to all instances:

    ```
    bosh update-runtime-config src/bosh-deployment/runtime-configs/dns.yml
    ```

I also added back the `kubo-dns-aliases` job templates to each instance group which sets up the `master.kubo` DNS hostname.

Now when I `bosh ssh master`, the hostname `master.kubo` maps to the master API:

    ```
    curl -v https://master.kubo:8443 -k
    ```
