#!/bin/bash

director_name=${BOSH_ENVIRONMENT:?required} # probably
deployment_name=${BOSH_DEPLOYMENT:?required}
address="https://${TCP_ROUTING_HOSTNAME:?required}:8443"

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

kubectl config get-clusters
