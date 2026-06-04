SHELL=/bin/bash

baseUrl = https://raw.githubusercontent.com/BinaryBirds/github-workflows/refs/heads/main/scripts

check: symlinks language deps lint headers docc-warnings package

package:
	curl -s $(baseUrl)/check-swift-package.sh | bash

breakage:
	curl -s $(baseUrl)/check-api-breakage.sh | bash

symlinks:
	curl -s $(baseUrl)/check-broken-symlinks.sh | bash

language:
	curl -s $(baseUrl)/check-unacceptable-language.sh | bash

deps:
	curl -s $(baseUrl)/check-local-swift-dependencies.sh | bash

lint:
	curl -s $(baseUrl)/run-swift-format.sh | bash

format:
	curl -s $(baseUrl)/run-swift-format.sh | bash -s -- --fix

docc-local:
	curl -s $(baseUrl)/generate-docc.sh | bash -s -- --local

run-docc:
	curl -s $(baseUrl)/run-docc-docker.sh | bash

docc-warnings:
	curl -s $(baseUrl)/check-docc-warnings.sh | bash

headers:
	curl -s $(baseUrl)/check-swift-headers.sh | bash

fix-headers:
	curl -s $(baseUrl)/check-swift-headers.sh | bash -s -- --fix

test-certs:
	rm -rf docker/postgres/certificates && mkdir -p docker/postgres/certificates && cd docker/postgres/certificates && ../scripts/generate-certificates.sh

test:
	swift test --parallel

docker-test:
	make test-certs && docker compose up --build --abort-on-container-exit --exit-code-from test test
