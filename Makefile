YYYYMMDD := $(shell date '+%Y%m%d')

.PHONY: daily

daily:
	hugo new post/${YYYYMMDD}/index.md
