#!/bin/bash
DIRNAME=`dirname $0`

if [ -z ${ARGOCD_NS+x} ];then
  ARGOCD_NS='argocd'
fi

if [ -f $1 ]; then
  echo "INFO: Using values file $1"
  VALUES_FILE=$1
else
  echo "ERROR: No Override file provided $1"
  exit 1
fi
echo "INFO: Installing Vanilla ArgoCD in $ARGOCD_NS to get CRDs before actual setup"
helm install argocd ./argo-cd \
  --namespace=$ARGOCD_NS \
  --create-namespace \
  --wait
echo "INFO: Creating Repositories Credentials"
kubectl apply -f ../argocd-repositories/demo-repository.yaml -n $ARGOCD_NS
echo "INFO: Argocd installation will be upgraded on $ARGOCD_NS namespace with values file $VALUES_FILE"
helm upgrade --install argocd ./argo-cd \
  --namespace=$ARGOCD_NS \
  --create-namespace \
  -f $VALUES_FILE \
  --wait
