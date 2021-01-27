#!/bin/bash
#
# ./deploy.sh NAMESPACE

set -e

NAMESPACE="$1"
export NAMESPACE=${NAMESPACE:="archivesspace-acc"}


tmp=$(/usr/local/bin/kubectl get pods -n "$NAMESPACE"|grep archivesspace-backend)
read -r pod dummy <<< "$tmp"

for cmd in "/usr/local/bin/kubectl logs -f ${pod} -n ${NAMESPACE}"
do
  /bin/echo "$cmd" && eval "$cmd"
done
