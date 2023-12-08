---
title: headless Chromeの調子が悪くってぇ...
description: 
slug: 20231208
date: 2023-12-08T20:02:13+09:00
categories:
    - Tech
tags: []
---
これまでスクレイピングのため、VPS上で selenium + headless chrome をDockerコンテナ内で動かしていたが、色々と課題があった。

今回、無駄に忌避していた headfullなブラウザを使ってみたら、思ったより不便なかったのでまとめておく。


1. headless なのはいいが、開発時には画面が見えない状態での試行錯誤が必要であり、ログインが必要なサイトだと大変お行儀が悪い。
2. chrome のバージョンと、selenium などの driver類のバージョンが合わないと簡単にエラーになる。

2.に関してはDockerfileも悪いのかも。
```
RUN apt-get update \
  && apt-get install -y python3-selenium wget gnupg \
  && wget https://dl.google.com/linux/linux_signing_key.pub \
  && apt-key add linux_signing_key.pub \
  && echo 'deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main' | tee /etc/apt/sources.list.d/google-chrome.list \
  && apt-get update \
  && apt -f install -y \
  && apt-get install -y google-chrome-stable \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && pip install -r /src/requirements.txt
```
こんな感じで、google-chrome-stable を aptパッケージが取ってきてきている一方で、pythonモジュールは `requirements.txt` に記載したものを取ってきている。

そしてとうとう普段アクセスしているサイトでJavascriptが動かなくなってしまった。headlessだと動かないのかもしれない。

```
    options.add_argument("--headless")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-gpu")
    options.add_argument("--lang=ja-JP")
    options.add_argument("--disable-dev-shm-usage")
```
こんな感じでchrome driverに引数を渡してもどうしてもJavascriptが動かない。こりゃだめだ。

---

しょうがないので、色々とDockerベースで調べてみると、
https://github.com/SeleniumHQ/docker-selenium で Standalone版があるらしい。
画面ありで動くらしいのだが、VPS上で動かすし、「はて・・・」となっていたが、どうやらこういう風に使えば良いっぽい。

- selenium/standalone-chrome を起動すると、Chromeがサーバとして立ち上がる
- :4444 で接続することで、Selenium から操作できる。

python だとこうすると、headless chromeと同様に起動することができる
```
    driver = webdriver.Remote(
        command_executor="http://selenium:4444/wd/hub", # selenium がホスト名
        options=webdriver.ChromeOptions(),
    )
```

で、:9999 にブラウザでアクセスすると、noVNC が起動してブラウザが動かされている様子が確認できる。

だから
- :9999 でブラウザアクセスしながら、意図する挙動がするように手元PCでデバッグする。
- そのまま動作させるVPSなどのホストに乗せればOK

問題としては、見もしない画面が展開されているところだけど、そこらへんはリソースをじゃぶじゃぶすれば楽をできる、ということで解決したことにする。

結果として、standalone-chrome を使うことで、
- 動作確認のデバッグが楽になる
- Chrome部分はパッケージングされているので、バージョン不整合が起きにくい
- headfull相当として動くので、実ブラウザで見たときと同じ挙動をしてくれることが期待できる

が出来た。

