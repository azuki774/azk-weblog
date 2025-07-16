---
title: kube-schedular 実装する(1)
description: kube-schedular + kind で超手抜き kube-schedular を実装してみよう
slug: 20250716
date: 2025-07-16T18:20:00+09:00
categories:
    - Tech
tags: [Kubernetes]
---

## kube-scheduler

kubernetes は御存知の通り、多くのコンポーネントにより、構成されており、後述する kind 環境においても、下記の通り kubernetes コントロール用の Pod がデプロイされている。
```
% kubectl get po -n kube-system
NAME                                         READY   STATUS    RESTARTS   AGE
coredns-674b8bbfcf-2qvlr                     1/1     Running   0          68m
coredns-674b8bbfcf-hk2sg                     1/1     Running   0          68m
etcd-kind-control-plane                      1/1     Running   0          68m
kindnet-9k7jz                                1/1     Running   0          68m
kindnet-cpgg5                                1/1     Running   0          67m
kindnet-fl9rj                                1/1     Running   0          68m
kindnet-ft9rn                                1/1     Running   0          67m
kube-apiserver-kind-control-plane            1/1     Running   0          68m
kube-controller-manager-kind-control-plane   1/1     Running   0          68m
kube-proxy-cthjm                             1/1     Running   0          68m
kube-proxy-f42ct                             1/1     Running   0          67m
kube-proxy-nl2j2                             1/1     Running   0          67m
kube-proxy-t292g                             1/1     Running   0          68m
kube-scheduler-kind-control-plane            1/1     Running   0          68m
```

その中でも、ここでは `kube-scheduler` に焦点を当てていきます。

簡単に言うと、このコンポーネントは、Podをデプロイする際に、kubernetes クラスタのどのノードにデプロイするかを決めるコンポーネントです。
例えば、雑に nginx の Pod を3つデプロイすると、

```
NAME                        READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
web-nginx-c86d9d87c-ghxfk   1/1     Running   0          81m   10.244.2.2   kind-worker3   <none>           <none>
web-nginx-c86d9d87c-mnbjh   1/1     Running   0          81m   10.244.1.2   kind-worker    <none>           <none>
web-nginx-c86d9d87c-x7gvv   1/1     Running   0          81m   10.244.3.2   kind-worker2   <none>           <none>
```
このように、`kind-worker`,`kind-worker2`,`kind-worker3` にそれぞれデプロイされていることが見て取れます。kubernetes 上の複数のノードのうち、どのノードにデプロイするか、デプロイ先を決めるのがこのコンポーネントです。

どのような基準でPodのデプロイ先を決めているかといえば、
- ノード先のリソース（メモリ、CPUなど）に空きがあるかどうか
- そのnodeがunschedulableになっていないかどうか
- PV がそのノードで利用可能かどうか
    - ReadWriteOnce などで他ノードの
- Taint/Tolerant の制約を満たしているかどうか
    - https://kubernetes.io/ja/docs/concepts/scheduling-eviction/taint-and-toleration/

などの基準があります。あるはずです。

本家大元の kube-scheduler であれば、その条件を満たす中から一番かしこい選択をするはずです。リソースが空いているところを優先したり、ノードにコンテナイメージが既にあったりしているノードには、高いスコアをつけて、配置戦略を行っていることでしょう。

## 今回やること

ここでは、この kube-scheduler を自作してみます。ただし、上記で触れたような厳密な実装はしません。
また、Go言語を使います。本家と一緒で芸がないけれど。

- Podに対して、ある簡単な基準を元に、動かすノードを割り当てる
- cronjob 専用のノードを作る（独自要素）

この2要素について挑戦してみたいと思います。

## kind 環境について

通常、素の kubernetes を一から構築するのは多くの苦痛を伴います。そのような、苦行を行わなくて済むよう、（開発環境、小規模環境では）ディストリビューションと呼ばれる kubernetes を簡単に構築する仕組みを用いることが一般的かと思います。`minikube` とか `microk8s` とか `k3s` とか `k0s` と呼ばれるのがそれです。

ここでは、`kind` と呼ばれるものを使います。`Kubernetes IN Docker` の略らしく、kubernetes の各ノード1つと、1コンテナで再現することによって、kubernetes クラスタをエミュレートするものです。

docker compose でマルチノードな kubernetes クラスタが立つようなものだと思えば良さそうです。
今回はこいつを使います。

- 公式サイト: https://kind.sigs.k8s.io

試しに、このような yaml ファイル (`multi-node.yaml`) を用意して、
```
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
```

下記コマンドを打つだけで、マルチノードなクラスタが立ち上がります。

```
% kind create cluster multi-node.yaml
Creating cluster "kind" ...
 ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-kind"
You can now use your cluster with:

kubectl cluster-info --context kind-kind

Thanks for using kind! 😊
```

```
% kubectl get nodes
NAME                 STATUS   ROLES           AGE   VERSION
kind-control-plane   Ready    control-plane   14h   v1.33.1
kind-worker          Ready    <none>          14h   v1.33.1
kind-worker2         Ready    <none>          14h   v1.33.1
kind-worker3         Ready    <none>          14h   v1.33.1
```

↓ 実態は docker コンテナである
```
% docker ps
CONTAINER ID   IMAGE                  COMMAND                  CREATED        STATUS        PORTS                       NAMES
16e15149b557   kindest/node:v1.33.1   "/usr/local/bin/entr…"   15 hours ago   Up 15 hours                               kind-worker
26ebb6fae555   kindest/node:v1.33.1   "/usr/local/bin/entr…"   15 hours ago   Up 15 hours                               kind-worker2
849a0d23a62b   kindest/node:v1.33.1   "/usr/local/bin/entr…"   15 hours ago   Up 15 hours                               kind-worker3
114fd0fe5155   kindest/node:v1.33.1   "/usr/local/bin/entr…"   15 hours ago   Up 15 hours   127.0.0.1:41803->6443/tcp   kind-control-plane
```

## kubernetes API を触れてみる

kube-scheduler に限らず、kubernetes な内部コンポーネントは `kube-system` で動いており、各リソースにアクセスする権限も強力なものです。一方で、通常の `default` namespace に割り当てられる、デフォルトの serviceAccount では、各ノードの情報などにはアクセスできないようになっているでしょう。

ここでは、簡単に kubernetes API を操作してみたいので、ユーザ側に存在する `~/.kube/config` の権限（すなわち管理ユーザ権限）を利用して、同APIにアクセスしてみることにします。
（ちなみに、kind でクラスタを構築した段階で、`~/.kube/config` に認証情報が自動で登録されるかと思っています。）

下記コマンドを実行して、そのターミナルを開きっぱなしにするなどしておきます。
ターミナルに表示されたホストにアクセスすれば、kubernetes API に繋がります。
```
% kubectl proxy
Starting to serve on 127.0.0.1:8001
```

試しに、ノード情報を取得する、`GET /api/v1/nodes` にアクセスしてみます。

```
% curl http://localhost:8001/api/v1/nodes | jq .
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 37907    0 37907    0     0  6436k      0 --:--:-- --:--:-- --:--:-- 7403k
{
  "kind": "NodeList",
  "apiVersion": "v1",
  "metadata": {
    "resourceVersion": "30301"
  },
  "items": [
    {
      "metadata": {
        "name": "kind-control-plane",
        "uid": "cdc8c1ef-e21a-4a8a-9b42-cc9f4da29cf2",
        "resourceVersion": "30233",
        "creationTimestamp": "2025-07-15T18:10:55Z",
        "labels": {
          "beta.kubernetes.io/arch": "amd64",
          "beta.kubernetes.io/os": "linux",
          "kubernetes.io/arch": "amd64",
          "kubernetes.io/hostname": "kind-control-plane",
          "kubernetes.io/os": "linux",
          "node-role.kubernetes.io/control-plane": "",
          "node.kubernetes.io/exclude-from-external-load-balancers": ""
        },
        "annotations": {
          "kubeadm.alpha.kubernetes.io/cri-socket": "unix:///run/containerd/containerd.sock",
          "node.alpha.kubernetes.io/ttl": "0",
          "volumes.kubernetes.io/controller-managed-attach-detach": "true"
          ・・・（略）
```

上記のように、各ノードの情報が取得できました。（示したのはコントロールノード `kind-control-plane` だけですが）

- 詳しくはこちら。公式ドキュメント（のノードに関する記載）: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.33/#node-v1-core


これらで得た情報を元に、
- 未アサインの Pod を取得する
- ノード情報を元に、アサインするワーカーノードを判断
- Pod をワーカーノードにアサインする

これらの仕組みを実装すれば、`kube-scheduler` が持つ要件が実現できることがなんとなくイメージできます。

---

というわけで、次回からは Go を利用して kube-scheduler を実装するための準備を指定いこうと思います。
