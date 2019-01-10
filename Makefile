clean:
	rm -rf public .deploy_git db.json package-lock.json

deploy:
	hexo deploy

gen:
	hexo generate
