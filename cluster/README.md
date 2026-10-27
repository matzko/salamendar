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
