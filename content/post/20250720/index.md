---
title: kube-scheduler 実装する(3)
description: 超手抜き kube-scheduler を実装してみよう
slug: 20250720
date: 2025-07-20T11:13:40+09:00
categories:
    - Tech
tags: [Kubernetes]
---

## 前回まで

前回までで、InCluster でのノードやポッド情報を取得するところまで行いました。また、`kube-scheduler` の流れの全体像を示しました。

ここからは、流れの中で示した各関数を説明していきます。

## GetUnscheduledPods

まずは、未アサインなPodを取得する関数です。

ここでは、やや非効率であることは分かっていますが、下記のようにすべてのPodを取得した後、ノードが未アサインのものを操作対象となるようにしています。

```
func (k *K8sClient) GetUnscheduledPods() (*v1.PodList, error) {
	// node にアサインされていない Pod の一覧を取得する

	// TODO: この実装はFieldSelectorを使うことで効率化される
	unscheduledPods := &v1.PodList{}
	pods, err := k.Clientset.CoreV1().Pods("").List(context.TODO(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting pods: %s", err.Error())
	}
	for _, pod := range pods.Items {
		if pod.Spec.NodeName == "" {
			unscheduledPods.Items = append(unscheduledPods.Items, pod)
			slog.Info("detect unscheduled pods", "name", pod.Name, "namespace", pod.Namespace)
		}
	}

	return unscheduledPods, nil
}
```
- 本当は、APIコール時に、[FieldSelector](https://kubernetes.io/ja/docs/concepts/overview/working-with-objects/field-selectors/) を利用することで、より高速に動作します。
- なお、上記の`FieldSelector`は後述するモックでうまく動作しなかった（きっちりは検証できてません。ごめんなさい）ので、今回は採用しませんでした。

下記がテストコードです。

```
func TestK8sClient_GetPodsNotScheduled(t *testing.T) {
	type fields struct {
		K8sClient K8sClient
	}
	unscheduledPod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "unscheduled-pod",
			Namespace: "default",
		},
		Spec: v1.PodSpec{
			NodeName: "", // NodeNameが空
		},
	}

	scheduledPod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "scheduled-pod",
			Namespace: "default",
		},
		Spec: v1.PodSpec{
			NodeName: "kind-worker", // NodeNameが設定済み
		},
	}

	fakeClientset := fake.NewSimpleClientset(unscheduledPod, scheduledPod)

	tests := []struct {
		name    string
		fields  fields
		want    *v1.PodList
		wantErr bool
	}{
		{
			name: "success",
			fields: fields{
				K8sClient: K8sClient{Clientset: fakeClientset},
			},
			want: &v1.PodList{
				Items: []v1.Pod{*unscheduledPod},
			},
			wantErr: false,
		},
		{
			name: "none",
			fields: fields{
				K8sClient: K8sClient{Clientset: fake.NewSimpleClientset()},
			},
			want: &v1.PodList{
				Items: []v1.Pod{},
			},
			wantErr: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			k := &K8sClient{
				Clientset: tt.fields.K8sClient.Clientset,
			}
			got, err := k.GetUnscheduledPods()
			if (err != nil) != tt.wantErr {
				t.Errorf("K8sClient.GetUnscheduledPods() error = %v, wantErr %v", err, tt.wantErr)
				return
			}

			if len(got.Items) != len(tt.want.Items) {
				t.Fatalf("Expected to get %d pod(s), but got %d", len(tt.want.Items), len(got.Items))
			}

			expectedPodNames := make(map[string]struct{})
			for _, pod := range tt.want.Items {
				expectedPodNames[pod.Name] = struct{}{}
			}

			// 実際に返ってきたPodが、すべて期待したものであることを確認する
			for _, gotPod := range got.Items {
				if _, ok := expectedPodNames[gotPod.Name]; !ok {
					t.Errorf("Unexpected pod found in results: %s", gotPod.Name)
				}
			}
		})
	}
}
```
- `fake.NewSimpleClientset()` によって、kubernetes API のレスポンスの mock が作られます。あらかじめ、ノード情報やポッド情報を与えてあげれば、そのような応答を返してくれるため、この手のテストには有用そうです。


## GetNodes

次に、ノード情報を取得する関数ですが、ほぼ内容は前と同じです。テストコードの提示は省略します。

```
func (k *K8sClient) GetNodes() (*v1.NodeList, error) {
	nodes, err := k.Clientset.CoreV1().Nodes().List(context.TODO(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting nodes: %s", err.Error())
	}
	return nodes, nil
}
```

## AssignPodToNode

ちょっと飛ばしますが、次は、最終的にPodをノードにアサインする実処理部分です。

ポッドと、アサインするノード情報を与えてあげれば十分です。

```
func (k *K8sClient) AssignPodToNode(pod *v1.Pod, node *v1.Node) error {
	binding := &v1.Binding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      pod.Name,
			Namespace: pod.Namespace,
		},
		Target: v1.ObjectReference{
			APIVersion: "v1",
			Kind:       "Node",
			Name:       node.Name,
		},
	}

	slog.Info("attempting to bind pod to node", "pod", pod.Name, "node", node.Name)

	err := k.Clientset.CoreV1().Pods(pod.Namespace).Bind(context.TODO(), binding, metav1.CreateOptions{})
	if err != nil {
		slog.Error("failed to bind pod to node", "pod", pod.Name, "node", node.Name, "error", err)
		return fmt.Errorf("failed to bind pod %s/%s to node %s: %w", pod.Namespace, pod.Name, node.Name, err)
	}

	return nil
}
```

下記がテストコードです。

```
func TestK8sClient_AssignPodToNode(t *testing.T) {
	type fields struct {
		Clientset kubernetes.Interface
	}
	type args struct {
		pod  *v1.Pod
		node *v1.Node
	}

	// --- テストデータとシナリオの準備 ---
	podToBind := &v1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "test-pod", Namespace: "default"}}
	nodeToBindTo := &v1.Node{ObjectMeta: metav1.ObjectMeta{Name: "test-node"}}

	// テストケースを定義
	tests := []struct {
		name    string
		fields  fields
		args    args
		wantErr bool
	}{
		{
			name: "success: correctly bind pod to node",
			fields: fields{
				Clientset: func() *fake.Clientset {
					clientset := fake.NewSimpleClientset()
					clientset.PrependReactor("create", "pods", func(action coretesting.Action) (handled bool, ret runtime.Object, err error) {
						createAction := action.(coretesting.CreateAction)
						if createAction.GetSubresource() != "binding" {
							return false, nil, nil // bindingでなければこのリアクターは処理しない
						}

						binding := createAction.GetObject().(*v1.Binding)
						if binding.Name != podToBind.Name || binding.Target.Name != nodeToBindTo.Name {
							t.Errorf("mismatched binding: got pod %s on node %s", binding.Name, binding.Target.Name)
						}

						// 成功したことを示す
						return true, binding, nil
					})
					return clientset
				}(),
			},
			args: args{
				pod:  podToBind,
				node: nodeToBindTo,
			},
			wantErr: false,
		},
		{
			name: "failure: API server returns error",
			fields: fields{
				Clientset: func() *fake.Clientset {
					clientset := fake.NewSimpleClientset()
					// 常にエラーを返すリアクターを設定
					clientset.PrependReactor("create", "pods", func(action coretesting.Action) (handled bool, ret runtime.Object, err error) {
						return true, nil, errors.New("simulated API error")
					})
					return clientset
				}(),
			},
			args: args{
				pod:  podToBind,
				node: nodeToBindTo,
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			k := &K8sClient{
				Clientset: tt.fields.Clientset,
			}
			if err := k.AssignPodToNode(tt.args.pod, tt.args.node); (err != nil) != tt.wantErr {
				t.Errorf("K8sClient.AssignPodToNode() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
```
- `clientset.PrependReactor` で mock の応答を事前に仕込んで置けるようです。エラー応答するようにしているテストケースも追加しています。アサインしようとしたら何らかの事情でエラーが帰ってきた場合が想定されます。

---

## ChooseAvailableNodes / ChooseSuitableNode

ここからは、ノード選択のロジック部分について実装しましょう。

- `ChooseAvailableNodes`: このPodがアサインしても良いノードのリストを返却
- `ChooseSuitableNode`: このPodをどのノードにアサインするかを最終的に決める

まずは、もっともシンプルな実装を入れましょう。ロジック部分は差し替えられるように別パッケージで。

```
package logic

import (
	v1 "k8s.io/api/core/v1"
)

type ScheduleLogic struct{}

// unscheduled pod が、配置して良いnodesを返す
func (s *ScheduleLogic) ChooseAvailableNodes(unschedulePod *v1.Pod, vs *v1.NodeList) (*v1.NodeList, error) {

	return vs, nil
}

// unscheduled podと配置していいnodesを与えると、配置するのに最適なnodeを返す
func (s *ScheduleLogic) ChooseSuitableNode(unschedulePod *v1.Pod, vs *v1.NodeList) (v1.Node, error) {

	return vs.Items[0], nil
}
```
- どのノードに配置しても良い
- 取得したノードリストのうち、一番最初のものを必ず指定する（＝マスターノードに必ずデプロイする）

## 実際に動かしてみる

それでは、この `kube-scheduler` を実際に動かしてみましょう。

ですが、まずは悲しいお知らせですが、これを完全な`kube-scheduler`の代替することは難しいです。通常、これらのマスターノードのデプロイ時には、相応のヘルスチェックなどが定義されているので、それらをきちんと実装してあげないといけません。また、コアとなるPodなので、`kubectl edit` による編集も効かないような仕組みになっていることもあるようです。

ですが、kubernetes には、リソースのデプロイ時に、自分で好きな scheduler を利用するオプションがあります。
- https://kubernetes.io/ja/docs/tasks/extend-kubernetes/configure-multiple-schedulers/

これを利用するには、単に `kube-system` ネームスペースに、我々の `kube-scheduler` をデプロイし、リリースしたいリソースのデプロイ時に、
(Deploymentの場合) `spec.template.spec.schedulerName` で指定すればよいだけです。

具体的にやっていきます。

まずは普通に、`kube-scheduler` をデプロイしてみます。

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
- sa などの設定は前稿と同様です。

この設定の下で、`nginx` 3つデプロイしてみます。

```
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: web-nginx
  name: web-nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-nginx
  template:
    metadata:
      labels:
        app: web-nginx
    spec:
      schedulerName: my-custom-scheduler // ★大事なのはここだけです
      containers:
      - image: nginx
        name: nginx
        ports:
        - containerPort: 80
```

では、デプロイします。

```
% kubectl apply -f nginx.yaml
```

```
% kubectl get pods -owide
NAME                         READY   STATUS    RESTARTS   AGE     IP           NODE                 NOMINATED NODE   READINESS GATES
web-nginx-59ffdfc748-c6w9r   1/1     Running   0          6m34s   10.244.0.5   kind-control-plane   <none>           <none>
web-nginx-59ffdfc748-grsl8   1/1     Running   0          6m34s   10.244.0.6   kind-control-plane   <none>           <none>
web-nginx-59ffdfc748-k2q6s   1/1     Running   0          6m34s   10.244.0.7   kind-control-plane   <none>           <none>
```

無事、control-plane にすべてデプロイされました。通常のスケジューラだと負荷分散しようとするのでこうはならないはずです。

なお、注意深く見ておくと、（状況にもよりますが）通常のスケジューラを使うときよりも、`STATUS: Pending` の時間が長いはずです。これは、`kube-scheduler` の実装にあたって、未アサインの Pod の取得をポーリング方式にしているからです。

## ちょっとだけ改良

さて、もともと何を作ろうとしたかと言うと、

- Podに対して、ある簡単な基準を元に、動かすノードを割り当てる
- cronjob 専用のノードを作る（独自要素）

でした。

もう少し書き下して、

- `tier: control` とついているノードには、Podをデプロイしない
- `tier: cronjob` とついているノードには、Cronjob をデプロイし、それ以外はデプロイしない。
- 条件に合うノードが複数あるときは、ランダムで選択する

という条件とします。


## 実装

```
// unscheduled pod が、配置して良いnodesを返す
func (s *ScheduleLogic) ChooseAvailableNodes(unschedulePod *v1.Pod, vs *v1.NodeList) (*v1.NodeList, error) {
	retv := v1.NodeList{
		TypeMeta: vs.TypeMeta,
		ListMeta: vs.ListMeta,
		Items:    []v1.Node{},
	}
	for _, vi := range vs.Items {
		if vi.Labels["tier"] == "control" {
			continue
		}

		if unschedulePod.Spec.NodeSelector["tier"] != "cronjob" && vi.Labels["tier"] == "cronjob" {
			continue
		} else if unschedulePod.Spec.NodeSelector["tier"] != "cronjob" && vi.Labels["tier"] != "cronjob" {
			continue
		}

		// ここまで問題なければ配置してOK
		retv.Items = append(retv.Items, vi)
	}
	return &retv, nil
}

// unscheduled podと配置していいnodesを与えると、配置するのに最適なnodeを返す
func (s *ScheduleLogic) ChooseSuitableNode(unschedulePod *v1.Pod, vs *v1.NodeList) (v1.Node, error) {
    if len(vs.Items) == 0 {
		return v1.Node{}, nil
	}

	// vs.Items の要素からランダムで選択する
	idx := rand.Intn(len(vs.Items))
	return vs.Items[idx], nil
}
```

コードだけ提示すれば十分かと思うぐらいのハードコードですが、このようにノード情報とポッド情報を照らし合わせて判定してみましょう。
`ChooseSuitableNode` は本当にランダムです。

これを適当した環境で、nginx を3つデプロイしてみましょう。

再掲すると、
`kind-control-plane` .. コントロールノード
`kind-worker`, `kind-worker2` .. cronjob 以外のノード
`kind-worker3` .. cronjob のノード

になります。

```
% kubectl apply -f nginx.yaml

% kubectl get po -A -owide
NAMESPACE            NAME                                         READY   STATUS    RESTARTS   AGE   IP           NODE                 NOMINATED NODE   READINESS GATES
default              web-nginx-59ffdfc748-8lbf9                   1/1     Running   0          36m   10.244.3.5   kind-worker2         <none>           <none>
default              web-nginx-59ffdfc748-q8h4k                   1/1     Running   0          36m   10.244.1.3   kind-worker          <none>           <none>
default              web-nginx-59ffdfc748-zgs7s                   1/1     Running   0          36m   10.244.1.4   
kind-worker          <none>           <none>
・・・（略）
```
- `kind-worker1, kind-worker2` とコントロールプレーンと、Cronjob 以外のノードからランダムで振り分けられました！


cronjob についても、定義して実行してみましょう。

```
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cronjob-1
spec:
  schedule: "*/2 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          schedulerName: my-custom-scheduler // ★カスタムの kube-scheduler を使います
          nodeSelector: // ★ nodeSelector で cronjob ノードに収容されるように指定します
            tier: cronjob
          containers:
          - name: busybox
            image: busybox
            command:
            - /bin/sh
            - -c
            - sleep 20
          restartPolicy: OnFailure
```
- 動作検証のために面倒なので、実際は3並行で用意しています。

```
% kubectl get pods -owide
NAME                         READY   STATUS      RESTARTS   AGE    IP            NODE           NOMINATED NODE   READINESS GATES
cronjob-1-29216368-hjsb5     0/1     Completed   0          5m6s   10.244.2.10   kind-worker3   <none>           <none>
cronjob-1-29216370-qtqv2     0/1     Completed   0          3m6s   10.244.2.13   kind-worker3   <none>           <none>
cronjob-1-29216372-zwsz7     0/1     Completed   0          66s    10.244.2.16   kind-worker3   <none>           <none>
cronjob-2-29216368-zzp7f     0/1     Completed   0          5m6s   10.244.2.11   kind-worker3   <none>           <none>
cronjob-2-29216370-qdclw     0/1     Completed   0          3m6s   10.244.2.14   kind-worker3   <none>           <none>
cronjob-2-29216372-b68nw     0/1     Completed   0          66s    10.244.2.17   kind-worker3   <none>           <none>
cronjob-3-29216368-5szzr     0/1     Completed   0          5m6s   10.244.2.12   kind-worker3   <none>           <none>
cronjob-3-29216370-fwgw2     0/1     Completed   0          3m6s   10.244.2.15   kind-worker3   <none>           <none>
cronjob-3-29216372-pnfrl     0/1     Completed   0          66s    10.244.2.18   kind-worker3   <none>           <none>
```
- この通り、すべての Pod が `kind-worker3`（cronjob専用ノード）にて実行されました。

## まとめ

というわけで、無事 `kube-scheduler` の超部分実装を行い、問題なく動作することが分かりました。

また、ネタバラシ（？）的にいうと、cronjob 専用ノードは `nodeSelector` を行うことで実装できます。今回は、その `nodeSelector` の処理の超部分実装ということでした。

このように、`client-go` などの公式クライアント用いることで、kubernetes API は操作することができ、簡単な部分実装であれば、kubernetes コンポーネント自体も自作できることが分かりました。

おしまい。

---

今回のコード: https://github.com/azuki774/kube-scheduler-practice/tree/v0.1.0
