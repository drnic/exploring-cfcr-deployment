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
```
