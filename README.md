# Argo-CD Deployment
This document makes the assumption you deployed a google cloud infrastructure using the IaC provided [here](https://github.com/runderwoodcr14/provisions-google-cloud-infrastructure.git)

Installation Steps

- Install sops-secret-operator
- Modify manifests and applications
- Install Argo-CD

## Install sops-secret-operator

We first need to encrypt our credentials, there are several solutions out there to perform this, all of them have their pros and cons, I've choosen sops-secret-operator because as it names mentioned is based on [sops](https://github.com/mozilla/sops) which is a really easy to use encryption tool and have support for GCP, AWS, Azure and GPG, you can find more details about [sops-secrets-operator here](https://github.com/isindir/sops-secrets-operator.git), now there are some limitations about it, the more significant at the moment is that you can't use `Workload Identity` to authenticate against `GCP`, you can check this [open issue](https://github.com/mozilla/sops/issues/675), so we need to provide json key in plain text.

We will use the `values.override.yaml` for sops-secrets-operator with the json key then we will encrypt this file with sops itself so we can push it to our repository.
So make sure you modify the file to suit your key:
```yaml
gcp:
    # -- Node labels for operator pod assignment
    enabled: true
    # -- Name of the secret to create - will override default secret name if specified
    svcAccSecretCustomName: ""
    # -- If `gcp.enabled` is `true`, this value must be specified as GCP service account secret json payload
    svcAccSecret: |-
        {
          "type": "service_account",
          "project_id": "",
          "private_key_id": "",
          "private_key": "",
          "client_email": "account@project_id.iam.gserviceaccount.com",
          "client_id": "",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token",
          "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
          "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/{account}%40{project_id}.iam.gserviceaccount.com"
        }
    # -- Name of a pre-existing secret containing GCP service account secret json payload
    existingSecretName: ""
```
Once we have the key in place, then is time to install the chart in your cluster:
`helm upgrade --install sops chart/sops-secrets-operator --namespace sops -f values.override.yaml --create-namespace --wait`

Once it has been succesfully installed we proceed to encrypt our `values.override.yaml` using sops

`sops --encrypt --gcp-kms projects/{project_id}}/locations/{location}}/keyRings/{encryption_ring}/cryptoKeys/{key} -i values.override.yaml`
And then we can safely push this into our repository.

## Modify manifests and applications
Before proceeding with Argo-CD installation, we first need to adjust the applications and manifest to use the resources created in GKE, for that, lets start with atlantis, lets move into `applications/atlantis/overlays/common/resources` and edit the following files:
- `ingress-external.yaml`: Make sure the `host` contains a valid public dns entry, this file comes already with a whitelist for github hooks and api.
- `ingress-internal.yaml`: Because we are using external-dns, just make sure the `host` is actually set to a value that includes your internal dns zone.
- `secrets.yaml` You have to fill the values:
  ```yaml
  webhook-secret:
  gh_token:
  gh_user:
  gh_repository: github.com/{account}/*
  ```
  After you this values to valid ones, proceed to encrypt the file with this command: `sops --encrypt --gcp-kms projects/{project_id}}/locations/{location}}/keyRings/{encryption_ring}/cryptoKeys/{key} --encrypted-suffix='Templates' -i secrets.yaml`
- `service-account.yaml`: Replace `{global_account}@host_project_id.iam.gserviceaccount.com` with the global account that was created during the provissioning of the infrastructure.

Next one will be `external-dns`, move into the `extenal-dns/overlays/common` folder and edit the file `values.override.yaml`:
- Make sure you update `external-dns-k8s-ext-dns@project_id.iam.gserviceaccount.com` with the right project_id from the environment you are deploying, you get the account from the `workload-identity` module from the google infrastructure deployment.
- The following fields must also be update accordingly:
```yaml
txtOwnerId: "k8s-common"
domainFilters:
  - domain.local
provider: google

extraArgs:
  - --google-project=host_project_id
  - --google-zone-visibility=private
```
Repeat the steps for each of the overlays

## Install Argo-CD

Our second step now, is to install Argo-CD, our setup will be manual, but after is installed, argo will be able to manage itself via GitOps and from this point onwards everything will be managed via GitOps.

There is a lot of documentation about how to setup argocd and its options, I will not cover all of them, I will focus on the parts needed for this demo, it may fit your needs or it my not, this are based on my actual needs.

So after we successfully installed `sops-secrets-operator` we move into the folder `argocd-repositories` and we edit the `demo-repository.yaml` file, I'm using ssh authentication for github, you may have different authentication requirements
```yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
    name: demo-repository-creds
spec:
    suspend: false
    secretTemplates:
      - name: demo-repository-creds
        labels:
          argocd.argoproj.io/secret-type: repo-creds
        stringData:
          type: git
          url: git@github.com:{account}
          sshPrivateKey: |
              -----BEGIN OPENSSH PRIVATE KEY-----
              -----END OPENSSH PRIVATE KEY-----

```
This file is a credentials template, you can find more argocd repository [here](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)


Once you have edited the file and adapted to your needs, its time to encrypt it using sops, with the following command:
`sops --encrypt --gcp-kms projects/{project_id}}/locations/{location}}/keyRings/{encryption_ring}/cryptoKeys/{key} --encrypted-suffix='Templates' -i demo-repository.yaml`

Now that our repository credentials are encrypted, we move on into the Argo-CD values file to override the default setup which under `argocd-install`, there is a bash script that will perform the installation, but before running it, we need to make sure the override match our needs, under the argocd server,
```yaml
## Server
server:
  # -- Argo CD server name
  name: server
```
Because we are not using an ingress controller at the moment, we will change the service to use a `LoadBalancer` instead of `ClusterIP`
```yaml
## Server service configuration
  service:
    # -- Server service annotations
    annotations: {}
    # -- Server service labels
    labels: {}
    # -- Server service type
    type: LoadBalancer
```
 Then make sure that config is enabled:
```yaml
# -- Manage Argo CD configmap (Declarative Setup)
  ## Ref: https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/argocd-cm.yaml
configEnabled: true
# -- [General Argo CD configuration]
  # @default -- See [values.yaml]
  config:
```
Then we adjust the config by adding the following under `additionalApplications`

```yaml
  ...
  additionalApplications:
    - name: argocd
      namespace: argocd
      destination:
        namespace: argocd
        server: https://kubernetes.default.svc
      project: argocd
      source:
        helm:
          version: v3
          valueFiles:
            - values.yaml
            - ../values-override.yaml
        path: argocd-install/argo-cd
        repoURL: git@github.com:{account}/demo-argocd.git
        targetRevision: HEAD
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
    - name: argocd-apps
      namespace: argocd
      destination:
        namespace: argocd
        server: https://kubernetes.default.svc
      project: argocd
      source:
        path: argocd-apps
        repoURL: git@github.com:{account}/demo-argocd.git
        targetRevision: HEAD
        directory:
          recurse: true
          jsonnet: {}
      syncPolicy:
        automated:
          selfHeal: true
          prune: true
    - name: argocd-appprojects
      namespace: argocd
      destination:
        namespace: argocd
        server: https://kubernetes.default.svc
      project: argocd
      source:
        path: argocd-appprojects
        repoURL: git@github.com:{account}/demo-argocd.git
        targetRevision: HEAD
        directory:
          recurse: true
          jsonnet: {}
      syncPolicy:
        automated:
          selfHeal: true
          prune: true
  ...
```
Then we add the project under `additionalProjects`:
```yaml
...
  additionalProjects:
    - name: argocd
      namespace: argocd
      additionalLabels: {}
      additionalAnnotations: {}
      description: Argocd Project
      sourceRepos:
        - "*"
      destinations:
        - namespace: argocd
          server: https://kubernetes.default.svc
      clusterResourceWhitelist:
        - group: "*"
          kind: "*"
      orphanedResources:
        warn: false
...
```
Make sure you replace `{account}` with your actual Github account

Now is time to run the installation script, the installation script will first install argocd with no configuration, this means vanilla setup, why, well because we need that argocd install its crds first so we can provision the repository credentials which are part of the setup, the script will create the secrets file, then it will upgrade argocd installation using our `values.override.yaml` file, to run the script just make sure you are in the `argocd-install` folder and execure this command:
`./01-install-argocd.sh -f values.override.yaml`


#####<span style="color:red">Be ware that you must have your kubernetes context selected and this depends on having access to k8s cluster and kubectl installed in the machine your are running this</span>

