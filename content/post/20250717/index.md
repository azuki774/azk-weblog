---
title: kube-scheduler 実装する(2)
description: 超手抜き kube-scheduler を実装してみよう
slug: 20250717
date: 2025-07-17T22:09:58+09:00
categories:
    - Tech
tags: [Kubernetes]
---

https://weblog.azuki.blue/p/20250716/ の続きの記事です。

## 使うライブラリ

https://github.com/kubernetes/client-go を使います。リンク先を見てみると分かる通り、kubernetes から出ている、公式ライブラリとなります。

このライブラリを利用することで、kubernetes API を手軽に叩くことが出来ます。今回はこちらをふんだんに利用しますが、一部、実装の簡略化及び本質的なところにフォーカスするため、あえて高度な機能を選択しないこともあります。

## `~/.kube/config` を利用したAPI実行

まずは、前稿で利用した `kubectl proxy` と同じ仕組みで、`client-go` を利用してみます。

といっても、こちらをそのまま利用すれば問題ないです。
https://github.com/kubernetes/client-go/blob/v12.0.0/examples/out-of-cluster-client-configuration/main.go

まずは node 一覧を取得してみましょう。上記の例の `clientset` に対して、下記のように操作すればおおよそ簡単に取れてしまいます。

```
    nodes, err := clientset.CoreV1().Nodes().List(context.TODO(), metav1.ListOptions{})
    if err != nil {
        log.Fatalf("Error getting nodes: %s", err.Error())
    }

    for _, node := range nodes.Items {
        slog.Info("node", "name", node.Name, "label.tier", node.Labels["tier"])
    }
```

上記のコードで、ノード名、Label.tier がセットされていれば表示されます。

```
.PHONY: bin-docker
bin-docker:
	go build -a -tags "netgo" -installsuffix netgo  -ldflags="-s -w -extldflags \"-static\" \
	-X main.version=$(git describe --tag --abbrev=0) \
	-X main.revision=$(git rev-list -1 HEAD) \
	-X main.build=$(git describe --tags)" \
	-o /app/ ./...
```

```
% make bin
% bin/kube-scheduler-practice local
{"time":"2025-07-16T19:12:02.571642068+09:00","level":"INFO","source":{"function":"kube-scheduler-practice/cmd.init.func1","file":"/home/azuki/work/kube-scheduler-practice/cmd/local.go","line":52},"msg":"node","name":"kind-control-plane","label.tier":"control"}
{"time":"2025-07-16T19:12:02.571699968+09:00","level":"INFO","source":{"function":"kube-scheduler-practice/cmd.init.func1","file":"/home/azuki/work/kube-scheduler-practice/cmd/local.go","line":52},"msg":"node","name":"kind-worker","label.tier":"normal"}
{"time":"2025-07-16T19:12:02.571710468+09:00","level":"INFO","source":{"function":"kube-scheduler-practice/cmd.init.func1","file":"/home/azuki/work/kube-scheduler-practice/cmd/local.go","line":52},"msg":"node","name":"kind-worker2","label.tier":"normal"}
{"time":"2025-07-16T19:12:02.571719668+09:00","level":"INFO","source":{"function":"kube-scheduler-practice/cmd.init.func1","file":"/home/azuki/work/kube-scheduler-practice/cmd/local.go","line":52},"msg":"node","name":"kind-worker3","label.tier":"cronjob"}
```

でました。ノード一覧です。

このようなAPI取得などを組み合わせて、ノード情報やPod情報を集めていく流れがイメージできるでしょうか。

## InCluster におけるAPI実行

### イメージについて

先ほどは、Goバイナリを実行して、クラスタの外からAPIを取得しました。

クラスタ内部から行う場合も、基本は同じです。当然、バイナリをDockerイメージに封じてそれを実行する必要があります。ここでは、適当に `Dockerfile` を書いておきます。デバッグのために、ディストロレスではなく、`alpine` を使いましょうか。

```
# Builder Stage
FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN apk add --no-cache make bash
RUN make bin-docker

# Runtime Stage
FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/kube-scheduler-practice /app/kube-scheduler-practice

ENTRYPOINT ["/app/kube-scheduler-practice", "start"]
```

何の変哲もないマルチステージビルドとなります。

### client-go の記載

そして、`client-go` でも、InCluster な場合の例はこちらです。https://github.com/kubernetes/client-go/tree/master/examples/in-cluster-client-configuration

このライブラリのポイントとしては、Podとして起動すると、自動的に bind される、serviceAccountのToken `/var/run/secrets/kubernetes.io/serviceaccount/token` を自動的に利用されることでしょう。

## デプロイする

まずは本家 `kube-scheduler` の代わりにデプロイするのではなく、単に `namespace: kube-system` にデプロイしてみましょう。

ただし、注意点が2つあります。

### 1. kind

kind でローカルイメージを利用する場合は、各ワーカーノードに Docker イメージを読み込ませる必要があるようです。具体的には、下記のコマンドが必要です。

```
kind load docker-image $(IMAGE_NAME)
```

### 2. ServiceAccount

このままデプロイすると、`kube-system` のデフォルトの ServiceAccount では、node 一覧を表示するための権限が足りません。そのため、下記のマニフェストを適用して、十分な権限を持つ ServiceAccount を新規作成してしまいましょう。

```
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-custom-scheduler-sa
  namespace: kube-system
```

```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-custom-scheduler-binding
subjects:
- kind: ServiceAccount
  name: my-custom-scheduler-sa
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: system:kube-scheduler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-custom-scheduler-volume-binding
subjects:
- kind: ServiceAccount
  name: my-custom-scheduler-sa
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: system:volume-scheduler
  apiGroup: rbac.authorization.k8s.io
```

新規 ServiceAccount を作成して、十分な権限を持つRoleをつけてあげます。

これで、下記の通り、マニフェストをデプロイしてみましょう。

```
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler-practice
  namespace: kube-system
spec:
  serviceAccountName: my-custom-scheduler-sa
  containers:
  - name: kube-scheduler-practice
    image: kube-scheduler-practice:latest
    imagePullPolicy: IfNotPresent
```

すると、ログが下記のように出ます。

```
 % kubectl logs -n kube-system kube-scheduler-practice
{"time":"2025-07-16T11:48:14.926237506Z","level":"INFO","source":{"function":"kube-scheduler-practice/cmd.init.func2","file":"/app/cmd/start.go","line":21},"msg":"kube-scheduler-practice start"}
{"time":"2025-07-16T11:48:14.937248399Z","level":"INFO","source":{"function":"kube-scheduler-practice/internal/client.(*K8sClient).GetNodes","file":"/app/internal/client/client.go","line":63},"msg":"node","name":"kind-control-plane","label.tier":"control"}
{"time":"2025-07-16T11:48:14.937274799Z","level":"INFO","source":{"function":"kube-scheduler-practice/internal/client.(*K8sClient).GetNodes","file":"/app/internal/client/client.go","line":63},"msg":"node","name":"kind-worker","label.tier":"normal"}
{"time":"2025-07-16T11:48:14.937277799Z","level":"INFO","source":{"function":"kube-scheduler-practice/internal/client.(*K8sClient).GetNodes","file":"/app/internal/client/client.go","line":63},"msg":"node","name":"kind-worker2","label.tier":"normal"}
{"time":"2025-07-16T11:48:14.937279499Z","level":"INFO","source":{"function":"kube-scheduler-practice/internal/client.(*K8sClient).GetNodes","file":"/app/internal/client/client.go","line":63},"msg":"node","name":"kind-worker3","label.tier":"cronjob"}
```

このように、ノード情報が InCluster からも取得できました。


## 今後の流れ

ここまでの流れで、InCluster でノード情報を取得することが出来ました。同様に Pod などの情報にもアクセスできることは想像の通りになります。

それでは、今後は次のようなループを実装してあげればいいということになります。細かい実装は次回以降に回すとして、ここでは大枠だけ示します。

とはいえ、コードで示せば十分な気もしますので、まずは示しましょう。

```
// スケジュールされていない pod 取得 → ノード情報取得 → 配置するpodを選択 → 配置指示
// 一連の処理の一巡を行う
func (k *K8sClient) ProcessOneLoop() error {
	unscheduledPods, err := k.GetUnscheduledPods()
	if err != nil {
		return err
	}

	for _, pod := range unscheduledPods.Items {
		nodes, err := k.GetNodes()
		if err != nil {
			return err
		}

		// 配置して良いノードを取得
		availableNodes, err := k.ScheduleLogic.ChooseAvailableNodes(&pod, nodes)
		if err != nil {
			return err
		}
		// 実際に配置するノードを取得
		selectNode, err := k.ScheduleLogic.ChooseSuitableNode(&pod, availableNodes)
		if err != nil {
			return err
		}

		// もし selectNode が空だったら、スケジューリングをスキップ
		if selectNode.Name == "" {
			slog.Info("no suitable node found for pod", "pod", pod.Name)
			continue
		}

		if err := k.AssignPodToNode(&pod, &selectNode); err != nil {
			return err
		}
	}
	return nil
}
```

このように、

- 未アサインなPod情報を監視する
- ノード情報を取得する
- どのノードにアサインするか決める
- そのノードにPodをアサインする

をし続ければいいということです。（なお、実際は未アサインなPodの情報を監視するために、APIを定期的に叩くのではなくInformerという機能があるそうですが、ここでは扱わないこととします。）

次回はサクサクと、上記で上げたコード片の実装を具体的に示していく予定になります。
