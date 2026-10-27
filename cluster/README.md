# Cluster setup

How the production cluster was set up, in order. Everything here is done
by hand, once. Deploys after that are CI's job (`kubectl apply -k k8s`).

The domain isn't in this repo. The values come from two git-ignored files:

- `k8s/config.env`: `PHX_HOST`, the app's hostname.
- `cluster/dns.env`: `DNS_SERVER`, the BIND server external-dns updates,
  and `DNS_ZONE`, the zone it owns. The app's A record is
  `salamendar.$DNS_ZONE`.

Copy them from their `.example` files. Then load both into your shell before
following along:

```sh
set -a; source k8s/config.env; source cluster/dns.env; set +a
```

`kubectl` and `helm` are pinned in `.tool-versions` (`mise install`).

## 1. The LKE cluster

In Linode's Cloud Manager: **Kubernetes → Create Cluster**, the newest
Kubernetes version, no HA control plane, and one pool with one **Shared
CPU, Linode 2 GB** node.

Keep its kubeconfig in its own file, so nothing here can reach another
cluster by accident:

```sh
mv ~/Downloads/salamendar-kubeconfig.yaml ~/.kube/salamendar.yaml
chmod 600 ~/.kube/salamendar.yaml
export KUBECONFIG=~/.kube/salamendar.yaml
kubectl get nodes -o wide
```

## 2. The node's firewall

If a Cloud Firewall is attached to the node, allow inbound TCP 80 and 443.
Traefik answers on those ports of the node itself (`hostPort`). There's no
NodeBalancer.

## 3. BIND

On the BIND server (Debian). external-dns sends RFC 2136 updates for
`$DNS_ZONE`, signed with a TSIG key, and lists the zone by AXFR. Both need
TCP 53 open from the internet, as well as UDP.

The key:

```sh
sudo tsig-keygen -a hmac-sha256 externaldns | sudo tee /etc/bind/externaldns.key >/dev/null
sudo chown root:bind /etc/bind/externaldns.key
sudo chmod 640 /etc/bind/externaldns.key
```

The zone. Its file lives in `/var/lib/bind`, because Debian's AppArmor
profile only lets `named` write there and in `/var/cache/bind`:

```sh
sudo tee /var/lib/bind/$DNS_ZONE.zone >/dev/null <<EOF
\$TTL 300
@   IN SOA $DNS_SERVER. hostmaster.$DNS_ZONE. (
        1 3600 600 604800
        60 )    ; negative TTL, so a missing record isn't cached long
    IN NS  $DNS_SERVER.
EOF
sudo chown bind:bind /var/lib/bind/$DNS_ZONE.zone
```

In `/etc/bind/named.conf.local`:

```
include "/etc/bind/externaldns.key";

zone "<DNS_ZONE>" {
    type primary;
    file "/var/lib/bind/<DNS_ZONE>.zone";
    update-policy { grant externaldns zonesub ANY; };
    allow-transfer { key externaldns; };
};
```

Once BIND takes dynamic updates for a zone, `named` owns its file. Never
edit it by hand without `rndc freeze` first and `rndc thaw` after. Nothing
else should live in that zone.

In the parent zone (edited by hand as usual; bump the serial): delegate
the zone, and point the app's hostname at external-dns's record.

```
k8s         IN NS     <DNS_SERVER>.
salamendar  3600 IN CNAME  salamendar.<DNS_ZONE>.
```

The CNAME can't be at the parent's apex, so `PHX_HOST` must be a
subdomain.

Check and load:

```sh
sudo named-checkconf
sudo named-checkzone <parent> /etc/bind/zones/<parent>
sudo named-checkzone $DNS_ZONE /var/lib/bind/$DNS_ZONE.zone
sudo rndc reconfig
sudo rndc reload <parent>
```

Test an update from anywhere with the key. Updates use UDP, so this works
even where TCP 53 is blocked:

```sh
nsupdate -k externaldns.key <<EOF
server $DNS_SERVER
zone $DNS_ZONE
update add test.$DNS_ZONE 60 A 192.0.2.1
send
EOF
dig +short @$DNS_SERVER test.$DNS_ZONE
```

Test AXFR from the cluster, because some networks block outbound TCP 53.
The key goes in as a mounted Secret, so it never appears in a command line:

```sh
kubectl create secret generic tsig-test --from-file=externaldns.key=externaldns.key
kubectl run axfrtest --rm -it --restart=Never --image=alpine:3.22 --overrides="{
  \"spec\": {
    \"volumes\": [{\"name\": \"k\", \"secret\": {\"secretName\": \"tsig-test\"}}],
    \"containers\": [{
      \"name\": \"axfrtest\", \"image\": \"alpine:3.22\",
      \"command\": [\"sh\", \"-c\", \"apk add -q bind-tools && dig @$DNS_SERVER -k /k/externaldns.key AXFR $DNS_ZONE\"],
      \"volumeMounts\": [{\"name\": \"k\", \"mountPath\": \"/k\"}]
    }]
  }
}"
kubectl delete secret tsig-test
```

Then remove the test record (`update delete test.$DNS_ZONE A`).

## 4. Traefik and cert-manager

```sh
helm install traefik oci://ghcr.io/traefik/helm/traefik --version 42.1.3 \
  --namespace traefik --create-namespace -f cluster/traefik-values.yaml
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.3 --namespace cert-manager --create-namespace \
  --set crds.enabled=true
kubectl apply -f cluster/cluster-issuer.yaml
```

Traefik should now answer on the node's IP. With no routes yet, port 80
redirects to HTTPS (301), and 443 gives a 404 with `TRAEFIK DEFAULT CERT`.
`kubectl get clusterissuer` should show `letsencrypt` as `Ready`.

```sh
curl -sI http://<node external IP>/
curl -skI https://<node external IP>/
```

## 5. external-dns

The Secret takes only the base64 secret from the key file. The
`<(…)` keeps it out of shell history and the process list.

```sh
kubectl create namespace external-dns
kubectl -n external-dns create secret generic external-dns \
  --from-file=tsig-secret=<(awk -F'"' '/secret/ {printf "%s", $2}' externaldns.key)

for f in external-dns traefik-dns; do
  envsubst '$DNS_SERVER $DNS_ZONE' < cluster/$f.yaml | kubectl apply -f -
done
```

Within a minute, `salamendar.$DNS_ZONE` should resolve to the node's
external IP, and `$PHX_HOST` to the same through the CNAME:

```sh
kubectl -n external-dns logs deploy/external-dns
dig +short @$DNS_SERVER salamendar.$DNS_ZONE
dig +short $PHX_HOST
```

## 6. The Slack tokens

Prod uses the existing Slack app. From https://api.slack.com/apps:

- `SLACK_BOT_TOKEN` (`xoxb-`): **OAuth & Permissions → Bot User OAuth
  Token**.
- `SLACK_APP_TOKEN` (`xapp-`): **Basic Information → App-Level Tokens**,
  with the `connections:write` scope.

Once prod is up, don't `just run` with these. Both would hold Socket Mode
connections, and Slack would split events between them.

## 7. The namespace and the app's Secrets

```sh
kubectl apply -f cluster/namespace.yaml
```

Run this in a real terminal: `read -s` needs a TTY. The values go to
kubectl through `<(printf …)` (`printf` is a builtin), so they stay out of
shell history and the process list. The password is hex, so it needs no
escaping in `DATABASE_URL`.

```sh
db_pass=$(openssl rand -hex 24)
read -rsp 'SLACK_BOT_TOKEN: ' slack_bot_token; echo
read -rsp 'SLACK_APP_TOKEN: ' slack_app_token; echo

kubectl -n salamendar create secret generic postgres \
  --from-file=username=<(printf %s salamendar) \
  --from-file=password=<(printf %s "$db_pass")

kubectl -n salamendar create secret generic salamendar \
  --from-file=SECRET_KEY_BASE=<(printf %s "$(openssl rand -base64 48 | tr -d '\n')") \
  --from-file=DATABASE_URL=<(printf %s "ecto://salamendar:$db_pass@postgres.salamendar.svc/salamendar") \
  --from-file=SLACK_BOT_TOKEN=<(printf %s "$slack_bot_token") \
  --from-file=SLACK_APP_TOKEN=<(printf %s "$slack_app_token") \
  --from-file=RELEASE_COOKIE=<(printf %s "$(openssl rand -hex 32)")

unset db_pass slack_bot_token slack_app_token
```

Nothing else keeps these values. To check the keys without printing them:
`kubectl -n salamendar describe secret postgres salamendar`.

## 8. CI's deployer

```sh
kubectl apply -f cluster/deployer-rbac.yaml
```

Check what it can do. It should be `yes` for the first two and `no` for
the rest:

```sh
as=system:serviceaccount:salamendar:deployer
kubectl auth can-i patch deployments -n salamendar --as=$as
kubectl auth can-i get pods/log -n salamendar --as=$as
kubectl auth can-i get secrets -n salamendar --as=$as
kubectl auth can-i delete deployments -n salamendar --as=$as
kubectl auth can-i patch deployments -n traefik --as=$as
kubectl apply -k k8s --dry-run=server --as=$as
```

Build a kubeconfig from its token, in a temp dir that's removed afterwards,
and store it as the `KUBECONFIG` secret of a `production` GitHub
Environment. The Environment only allows `main`, so no other branch's
workflow can read it.

```sh
repo=matzko/salamendar
dir=$(mktemp -d); chmod 700 "$dir"; cfg=$dir/kubeconfig
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl -n salamendar get secret deployer-token -o jsonpath='{.data.ca\.crt}')
token=$(kubectl -n salamendar get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)

(umask 077; cat > "$cfg" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: salamendar
    cluster: { server: $server, certificate-authority-data: $ca }
users:
  - name: deployer
    user: { token: $token }
contexts:
  - name: deployer
    context: { cluster: salamendar, user: deployer, namespace: salamendar }
current-context: deployer
EOF
)
unset token
KUBECONFIG=$cfg kubectl auth whoami

gh api -X PUT repos/$repo/environments/production --silent \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/$repo/environments/production/deployment-branch-policies \
  --silent -f name=main -f type=branch
gh secret set KUBECONFIG --repo $repo --env production < "$cfg"
rm -rf "$dir"
```

To rotate the token, delete the `deployer-token` Secret, apply
`deployer-rbac.yaml` again, and redo the above.

Protect `main`, so that merged means tested: every change goes through a
PR, CI's four jobs must pass on a branch that's up to date, and that holds
for admins too. `app_id` 15368 is GitHub Actions.

```sh
gh api -X PUT repos/matzko/salamendar/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      {"context": "test", "app_id": 15368},
      {"context": "lint", "app_id": 15368},
      {"context": "manifests", "app_id": 15368},
      {"context": "docker", "app_id": 15368}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

## 9. The `PHX_HOST` variable

CI writes `k8s/config.env` from it.

```sh
gh variable set PHX_HOST --body "$PHX_HOST"
```

## 10. The first deploy

Images go to GHCR (`ghcr.io/matzko/salamendar`), tagged with the commit
SHA. GHCR has no site of its own: packages show under the GitHub account
and, once linked, on the repo. The Dockerfile's
`org.opencontainers.image.source` label links the package to the repo on
its first push, so CI's `GITHUB_TOKEN` can push to it later.

Log Docker in with `gh`'s token, which needs the `write:packages` scope:

```sh
gh auth refresh -s write:packages
gh auth token | docker login ghcr.io -u matzko --password-stdin
```

Build and push from a commit that's on `main`:

```sh
sha=$(git rev-parse HEAD)
docker build -t ghcr.io/matzko/salamendar:$sha .
docker push ghcr.io/matzko/salamendar:$sha
```

The first push makes a private package, which the cluster can't pull (there
are no `imagePullSecrets`). Make it public, once, at
https://github.com/users/matzko/packages/container/salamendar/settings
(**Danger Zone → Change visibility**). The image holds only the release:
`.dockerignore` keeps `.env` and `config/.env.exs` out of the build.

Deploy it. `kustomize edit` rewrites `kustomization.yaml`, so check it out
again afterwards.

```sh
(cd k8s && kustomize edit set image salamendar=ghcr.io/matzko/salamendar:$sha)
kubectl apply -k k8s
git checkout k8s/kustomization.yaml

kubectl -n salamendar rollout status statefulset/postgres --timeout=5m
kubectl -n salamendar rollout status deploy/salamendar --timeout=5m
kubectl -n salamendar wait certificate --all --for=condition=Ready --timeout=5m
curl -sI https://$PHX_HOST/healthz
```

On a first boot the `migrate` init container fails a time or two with
`nxdomain` for `postgres.salamendar.svc`: a headless Service has no DNS
record until its pod is ready. Kubernetes retries it, and it goes through
once Postgres is up. The same happens whenever both pods start together,
such as after a node replacement.

Then sign in to the calendar from a link the bot sends.

## 11. metrics-server

For `kubectl top`. LKE doesn't install it. The chart asks for 100m CPU and
200Mi by default, but it uses a few millicores and about 15Mi, and CPU
requests are what's tight on one node.

```sh
helm install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server --version 3.14.0 \
  --namespace kube-system \
  --set resources.requests.cpu=20m --set resources.requests.memory=64Mi \
  --set resources.limits.memory=128Mi
kubectl top pods -A --sort-by=memory
```

It doesn't need `--kubelet-insecure-tls`, despite older LKE advice. LKE's
kubelet serving certs are signed by the cluster CA and list the node's
IPs. If an upgrade changes that, its logs will show `x509` errors.

`kubectl top node` can show memory over 100%. It compares the whole node's
working set (the OS, kubelet and containerd too) with allocatable, which
already leaves those out. For what's really free:

```sh
kubectl get --raw /api/v1/nodes/$(kubectl get nodes -o name | cut -d/ -f2)/proxy/stats/summary \
  | jq '.node.memory.availableBytes / 1048576 | floor'
```
