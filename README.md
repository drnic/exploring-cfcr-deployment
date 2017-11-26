# Deploy Cloud Foundry Container Runtime (formerly Kubo)

This project is an alternate set of deployment manifest/operator files/operator scripts than the upstream https://github.com/cloudfoundry-incubator/kubo-deployment and its documentation at https://docs-cfcr.cfapps.io

At the time of writing I found the instructions very coupled an assumption that you start with nothing and bootstrap everything their way. Except, for me, 100% of the time I already have an environment, a BOSH, and possibly a Cloud Foundry. So I wanted a `bosh deploy manifests/cfcr.yml` that did not make assumptions.

At the time of starting this project I do not know Kubernetes and have not attempted to follow step-for-step the upstream instructions at https://docs-cfcr.cfapps.io. For this reason I decided to start with a blank slate and build out a set of manifests incrementally.

To maximize the chance that my templates will replace the upstream templates, I'll will always start with the same `manifests/kubo.yml` file. So, I've got the upstream `kubo-deployment` as a submodule.

```
export BOSH_DEPLOYMENT=cfcr-kubo
export master_host=10.10.1.241
export routing_host=10.10.1.242

git clone https://github.com/drnic/cfcr-deployment
bosh deploy cfcr-deployment/src/kubo-deployment/manifests/kubo.yml \
  -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy.yml \
  -o <(cfcr-deployment/operators/pick-from-cloud-config.sh \
      cfcr-deployment/src/kubo-deployment/manifests/kubo.yml \
    -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy.yml) \
  -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy-vsphere.yml \
  -v worker_haproxy_ip_addresses=$routing_host \
  -v worker_haproxy_tcp_backend_port=32326 \
  -v worker_haproxy_tcp_frontend_port=9200 \
  -o cfcr-deployment/operators/final-releases.yml \
  -o cfcr-deployment/operators/latest-stemcell.yml \
  -o cfcr-deployment/operators/no-disk-types.yml \
  -o cfcr-deployment/operators/some-jobs.yml \
  -o cfcr-deployment/operators/master-ip.yml \
  -v deployment_name=$BOSH_DEPLOYMENT \
  -v deployments_network=default \
  -v kubernetes_master_host=$master_host \
  -v kubernetes_master_port=8443 \
  -v authorization_mode=abac \
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


### Step 4. Install root CA.

In the `curl` above the `-k` flag is to skip validation of HTTPS certificate. It is much better to validate certificates by providing the root cert with the `curl --cacert` flag.

Similarly, subsystems and clients that interact with `https://master.kubo` will want to validate against the root certificate.

The `kubeconfig` job template creates a shared certificate file `/var/vcap/jobs/kubeconfig/config/ca.perm`. To confirm it works with `curl` (within a `bosh ssh master` or `bosh ssh worker/0` instance):

```
curl -v https://master.kubo:8443 --cacert /var/vcap/jobs/kubeconfig/config/ca.pem
```

### Step 5. Running Kubelets

After adding `kubelet` job template back to the `worker` instance group, it initially fails with a variety of errors similar to:

```
==> /var/vcap/sys/log/kubelet/kubelet.stderr.log <==
Unable to register node "10.10.1.20" with API server: nodes is forbidden: User "kubelet" cannot create nodes at the cluster scope
```

There is a `kubo-release` job template `apply-specs` that looks to be an errand; but its not mentioned in `kubo.yml`; rather its in an operator file `kubo-deployments/manifests/ops-files/addons-spec.yml` as a collocated errand (the job template is definitely an errand as it contains `bin/run` and an empty `monit` file). This means that `bosh run-errand apply-specs` will run on all `master` instances. I'm not sure if that's intentional or accidental. Perhaps this could be changed to a [post-start](https://bosh.io/docs/post-start.html) script (rather than an errand). Additional, perhaps place an `<% if spec.bootstrap %>` around it so the commands are only run once per deploy (on `master/0` unnecessarily by all `master` instances). Issue raised https://github.com/cloudfoundry-incubator/kubo-release/issues/133.

So I added back all the job templates, except `cloud-provider`, and redeployed. The cluster seemed to work.

I successfully deployed this example https://github.com/kubernetes/examples/tree/master/staging/elasticsearch

But I do not have an external IP for exposing services:

```
$ kubectl get service elasticsearch
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                         AGE
elasticsearch   LoadBalancer   10.100.200.99   <pending>     9200:31597/TCP,9300:31686/TCP   2m
```

### Step 6. Ingress to Elastic Search

So the default `kubo.yml` manifest doesn't appear to have a default option for an external IP to route traffic. I think it should. Then, if a deployer wants to use `cf` or `iaas` or another routing method they can use an operator file that changes the base manifest.

But again, I don't know kubernetes well.

"The current implementation of HAProxy routing is a single-port TCP pass-through. In order to route traffic to multiple Kubernetes services, use an Ingress controller" (from [kubo docs](https://docs-cfcr.cfapps.io/installing/haproxy/)) - so the `worker-haproxy` only proxies a single TPC port to a single backend port (on all `worker` instances). So its only useful for a single Kubernetes deployment?

Nonetheless, perhaps the default `kubo.yml` should expose one port binding for an initial demo.

Another idea, would be to provide an operator file to run the Cloud Foundry routing within the `kubo.yml` deployment; rather than only via a full CF deployment.

I looked at the assigned port for my elasticsearch cluster and see that port `32326` maps to the elasticsearch http api (port 9200).

```
$ kubectl get service elasticsearch
NAME            TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                         AGE
elasticsearch   LoadBalancer   10.100.200.168   <pending>     9200:32326/TCP,9300:30847/TCP   55s
```

I configured the backend port to `32326` and used the expected `9200` as my frontend port:

```
  -v worker_haproxy_tcp_backend_port=32326 \
  -v worker_haproxy_tcp_frontend_port=9200 \
```

Now I can access my Elastic Search cluster from the new `worker-haproxy` static IP:

```
$ curl http://10.10.1.242:9200/_cluster/health?pretty
{
  "cluster_name" : "myesdb",
  "status" : "green",
  ...
```

But `EXTERNAL-IP` is still not configured. Not sure yet if this is good or bad. I mean, the haproxy works - but its only routing a single ingress route to a single backend port. So, "works" is probably worth "double "double" quotes".

The snippet of `bosh deploy` that uses haproxy is:

```
bosh deploy cfcr-deployment/src/kubo-deployment/manifests/kubo.yml \
  -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy.yml \
  -o <(cfcr-deployment/operators/pick-from-cloud-config.sh \
      cfcr-deployment/src/kubo-deployment/manifests/kubo.yml \
    -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy.yml) \
  -o cfcr-deployment/src/kubo-deployment/manifests/ops-files/worker-haproxy-vsphere.yml \
  -v worker_haproxy_ip_addresses=$routing_host \
  -v worker_haproxy_tcp_backend_port=32326 \
  -v worker_haproxy_tcp_frontend_port=9200 \
  ...
```

## Questions about variables

Why are these variables rather than just using job spec defaults?

* `kubernetes_master_port` - default is `8443`
* `kubernetes_master_port` - why is it a variable rather than a default?
* `authorization_mode` - default is `rbac`; but `project-config.yml` suggests `abac` ("Note: RBAC is not stable as of 0.8.x.")

Why these variables rather than sane defaults?

* `deployment_name` - suggested change to `cfcr`
* `deployments_network` - suggested change to `default`
