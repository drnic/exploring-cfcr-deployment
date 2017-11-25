# Deploy Cloud Foundry Container Runtime (formerly Kubo)

This project is an alternate set of deployment manifest/operator files/operator scripts than the upstream https://github.com/cloudfoundry-incubator/kubo-deployment and its documentation at https://docs-cfcr.cfapps.io

At the time of writing I found the instructions very coupled an assumption that you start with nothing and bootstrap everything their way. Except, for me, 100% of the time I already have an environment, a BOSH, and possibly a Cloud Foundry. So I wanted a `bosh deploy manifests/cfcr.yml` that did not make assumptions.

At the time of starting this project I do not know Kubernetes and have not attempted to follow step-for-step the upstream instructions at https://docs-cfcr.cfapps.io. For this reason I decided to start with a blank slate and build out a set of manifests incrementally.

To maximize the chance that my templates will replace the upstream templates, I'll will always start with the same `manifests/kubo.yml` file. So, I've got the upstream `kubo-deployment` as a submodule.

```
export BOSH_DEPLOYMENT=cfcr-kubo
git clone https://github.com/drnic/drnic-cfcr-kubo-deployment
bosh deploy drnic-cfcr-kubo-deployment/src/kubo-deployment/manifests/kubo.yml \
  -o drnic-cfcr-kubo-deployment/operators/final-releases.yml \
  -o drnic-cfcr-kubo-deployment/operators/latest-stemcell.yml \
  -o drnic-cfcr-kubo-deployment/operators/no-disk-types.yml \
  -o drnic-cfcr-kubo-deployment/operators/some-jobs.yml \
  -o <(drnic-cfcr-kubo-deployment/operators/pick-from-cloud-config.sh drnic-cfcr-kubo-deployment/src/kubo-deployment/manifests/kubo.yml) \
  -o drnic-cfcr-kubo-deployment/operators/master-ip.yml \
  -v deployment_name=$BOSH_DEPLOYMENT \
  -v kubernetes_master_host=10.10.1.241 \
  -n
```
