---
title: annotation tagを使う
description: lightweight tagが混入して困ること多々
slug: 20231223
date: 2023-12-23T17:32:45+09:00
categories:
    - Tech
tags: [GitHub Actions, CI]
---

## lightweight tagとannotation tag

Gitのタグはlightweight tagとannotation tagがある。

### annotation tag
annotation tagがいわゆるコメント付きのタグのことで、
```
$ git tag -am "<comment>" <tag_name>
```

でつけられる。
`git show <tag>` したときの挙動は、

```
tag v1.5.2
Tagger: azuki774s <azuki774s@gmail.com>
Date:   Wed Nov 22 00:21:27 2023 +0900

v1.5.2 ←コメント

commit 87d4e3c7b8776ea6c7dc669ee387428fea79cfc1 (HEAD -> master, tag: v1.5.2, origin/master)
Author: azuki774s <azuki774s@gmail.com>
Date:   Sun Nov 19 01:17:17 2023 +0900
```

と出てくる。

- タグと、タグつけた人と、タグ切った時間、タグのコメント、コミット、そのコミットの情報が埋め込まれる。

### lightweight tag
一方で、lightweight tagはと言うと、
```
$ git tag <tag>
```
だけでつけられるもので、実際に `git show`してみると、

```
$ git tag v1.5.3-rc.1
$ git show v1.5.3-rc.1
commit 87d4e3c7b8776ea6c7dc669ee387428fea79cfc1 (HEAD -> ci-drop-lightweight-tag, tag: v1.5.3-rc.1, tag: v1.5.2, origin/master, master)
Author: azuki774s <azuki774s@gmail.com>
Date:   Sun Nov 19 01:17:17 2023 +0900
```

タグに関する情報がない。特定のコミットを指しているという情報しかない。
- タグつけた人と、タグ切った時間、タグのコメントがない。

## んで、どういうとき lightweight tagだと困るねん

`git describe` などのコマンドでは `--tags` オプションを付けないとlightweight tagを認識しない。
例えば、下記のような引数を渡してgoをbuildをするときを考える。

```
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -tags "netgo" -installsuffix netgo  -ldflags="-s -w -extldflags \"-static\" \
	-X main.version=$(git describe --tag --abbrev=0) \
	-X main.revision=$(git rev-list -1 HEAD) \
	-X main.build=$(git describe --tags)" \
	-o bin/ ./...
```

特に、
```
v1.5.2 <- annotation tag
v1.5.3-rc.1 <- lightweight tag
```

```
$ git describe --abbrev=0
v1.5.2
$ git describe --tags --abbrev=0
v1.5.3-rc.1
```

だとすると、semantic verとしては、最新がv1.5.3-rc.1 となるが、`--tags`をつけ忘れているところがあると、

```
$ git log
commit 87d4e3c7b8776ea6c7dc669ee387428fea79cfc1 (HEAD -> ci-drop-lightweight-tag, tag: v1.5.3-rc.1, tag: v1.5.2, origin/master, master)
Author: azuki774s <azuki774s@gmail.com>
Date:   Sun Nov 19 01:17:17 2023 +0900
(snip...)
```
となって、無事前のバージョンのタグ情報が乗ったバイナリを生成してしまう。ﾄﾞｳｼﾃ。

したがって　`--tags` をきちんと付けることを徹底するか、lightweight tagを使わないようにするべきであろう。
annotation tagの方が情報がリッチなので、CIでannotation tagを強制することにする。

CI側でプッシュされたタグがlightweight tagだったらRejectする仕組みを考えていたが、結局いい方法が思いつかなかった。
```
Fetching the repository
  /usr/bin/git -c protocol.version=2 fetch --no-tags --prune --progress --no-recurse-submodules --depth=1 origin +44282c5af6e7920ec7f4b280a54b07c4761bf986:refs/tags/v1.5.3
```

GitHub Actionsでいうと、このあたりの 
`{{ github.ref }}`とか、`{{ github.workflow_ref }}` とか使えば組み合わせればできるのかな・・・


# Ref
- https://git-scm.com/book/en/v2/Git-Basics-Tagging
- https://docs.github.com/en/actions/learn-github-actions/contexts#github-context
