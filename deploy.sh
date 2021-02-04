#!/bin/bash
#
# ./deploy.sh NAMESPACE

set -e

NAMESPACE="$1"
export NAMESPACE=${NAMESPACE:="archivesspace-acc"}

# De naam van de backend pod
tmp=$(/usr/local/bin/kubectl get pods -n "$NAMESPACE"|grep archivesspace-backend)
read -r pod_backend dummy <<< "$tmp"

# De naam van de frontend pod
tmp=$(/usr/local/bin/kubectl get pods -n "$NAMESPACE"|grep archivesspace-frontend)
read -r pod_frontend dummy <<< "$tmp"

# De naam van solr
tmp=$(/usr/local/bin/kubectl get pods -n "$NAMESPACE"|grep solr-)
read -r pod_solr dummy <<< "$tmp"

echo "namespace: ${NAMESPACE}"
echo "pod_backend=${pod_backend}"
echo "pod_frontend=${pod_frontend}"
echo "pod_solr=${pod_solr}"

# kopieer en herstart wat nodig is
for cmd in \
  "/usr/local/bin/kubectl cp iisg/ ${pod_backend}:/archivesspace/plugins/ -n ${NAMESPACE}" \
  "/usr/local/bin/kubectl cp reports/custom/ ${pod_backend}:/archivesspace/reports/ -n ${NAMESPACE}" \
  "/usr/local/bin/kubectl delete pod ${pod_backend} -n ${NAMESPACE}"
do
  /bin/echo "$cmd" && eval "$cmd"
done