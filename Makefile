YYYYMMDD := $(shell date '+%Y%m%d')

.PHONY: start daily

start:
	hugo server

daily:
	git switch master
	git pull origin master
	git switch -c daily-${YYYYMMDD}
	hugo new post/${YYYYMMDD}/index.md

daily-push:
	git add content/post/${YYYYMMDD}
	git commit -m "daily ${YYYYMMDD}"
	git push origin daily-${YYYYMMDD}
