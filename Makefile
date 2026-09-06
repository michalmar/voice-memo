.PHONY: test openapi image tf-plan apple-project

test:
	python -m pytest backend/tests
	cd Packages/VoicePromptKit && swift test

openapi:
	python scripts/export-openapi.py

image:
	docker build -t voiceprompt:local backend

tf-plan:
	terraform -chdir=infrastructure init
	terraform -chdir=infrastructure plan

apple-project:
	cd Apple && xcodegen generate

