all: check-license build generate test

GO111MODULE=on
export GO111MODULE

BUILDDIR=$(CURDIR)
registry_url ?= docker.io
image_name = ${registry_url}/platform9/kube-rbac-proxy
DOCKERFILE?=$(CURDIR)/Dockerfile
UPSTREAM_VERSION?=$(shell git describe --tags HEAD | sed 's/-.*//' )
image_tag = $(UPSTREAM_VERSION)-pmk-$(TEAMCITY_BUILD_ID)
PF9_TAG=$(image_name):${image_tag}
DOCKERARGS=
ifdef HTTP_PROXY
	DOCKERARGS += --build-arg http_proxy=$(HTTP_PROXY)
endif
ifdef HTTPS_PROXY
	DOCKERARGS += --build-arg https_proxy=$(HTTPS_PROXY)
endif

GITHUB_URL=github.com/brancz/kube-rbac-proxy
GOOS?=$(shell uname -s | tr A-Z a-z)
GOARCH?=$(shell go env GOARCH)
OUT_DIR=_output
BIN?=kube-rbac-proxy
VERSION?=$(shell cat VERSION)-$(shell git rev-parse --short HEAD)
PKGS=$(shell go list ./... )
DOCKER_REPO?=quay.io/brancz/kube-rbac-proxy
KUBECONFIG?=$(HOME)/.kube/config

ALL_ARCH=amd64 arm arm64 ppc64le s390x
ALL_PLATFORMS=$(addprefix linux/,$(ALL_ARCH))
ALL_BINARIES ?= $(addprefix $(OUT_DIR)/$(BIN)-, \
				$(addprefix linux-,$(ALL_ARCH)) \
				darwin-amd64 \
				windows-amd64.exe)


check-license:
	@echo ">> checking license headers"
	@./scripts/check_license.sh

crossbuild: $(ALL_BINARIES)

$(OUT_DIR)/$(BIN): $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH)
	cp $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH) $(OUT_DIR)/$(BIN)

$(OUT_DIR)/$(BIN)-%:
	@echo ">> building for $(GOOS)/$(GOARCH) to $(OUT_DIR)/$(BIN)-$*"
	GOARCH=$(word 2,$(subst -, ,$(*:.exe=))) \
	GOOS=$(word 1,$(subst -, ,$(*:.exe=))) \
	CGO_ENABLED=0 \
	go build --installsuffix cgo -o $(OUT_DIR)/$(BIN)-$* $(GITHUB_URL)

build: $(OUT_DIR)/$(BIN)

container: $(OUT_DIR)/$(BIN)-$(GOOS)-$(GOARCH) Dockerfile
	docker build --build-arg BINARY=$(BIN)-$(GOOS)-$(GOARCH) -t $(DOCKER_REPO):$(VERSION)-$(GOARCH) .
ifeq ($(GOARCH), amd64)
	docker tag $(DOCKER_REPO):$(VERSION)-$(GOARCH) $(DOCKER_REPO):$(VERSION)
endif


manifest-tool:
	curl -fsSL https://github.com/estesp/manifest-tool/releases/download/v1.0.2/manifest-tool-linux-amd64 > ./manifest-tool
	chmod +x ./manifest-tool

push-%:
	$(MAKE) GOARCH=$* container
	docker push $(DOCKER_REPO):$(VERSION)-$*

comma:= ,
empty:=
space:= $(empty) $(empty)
manifest-push: manifest-tool
	./manifest-tool push from-args --platforms $(subst $(space),$(comma),$(ALL_PLATFORMS)) --template $(DOCKER_REPO):$(VERSION)-ARCH --target $(DOCKER_REPO):$(VERSION)

push: crossbuild manifest-tool $(addprefix push-,$(ALL_ARCH)) manifest-push

curl-container:
	docker build -f ./examples/example-client/Dockerfile -t quay.io/brancz/krp-curl:v0.0.1 .

run-curl-container:
	@echo 'Example: curl -v -s -k -H "Authorization: Bearer `cat /var/run/secrets/kubernetes.io/serviceaccount/token`" https://kube-rbac-proxy.default.svc:8443/metrics'
	kubectl run -i -t krp-curl --image=quay.io/brancz/krp-curl:v0.0.1 --restart=Never --command -- /bin/sh

grpcc-container:
	docker build -f ./examples/grpcc/Dockerfile -t mumoshu/grpcc:v0.0.1 .

test:
	@echo ">> running all tests"
	# install test dependencies
	@go test -i $(PKGS)
	# run the tests
	@go test  $(PKGS)

test-e2e:
	go test -timeout 55m -v ./test/e2e/ $(TEST_RUN_ARGS) --kubeconfig=$(KUBECONFIG)

generate: build embedmd
	@echo ">> generating examples"
	@./scripts/generate-examples.sh
	@echo ">> generating docs"
	@./scripts/generate-help-txt.sh
	@$(GOPATH)/bin/embedmd -w `find ./ -prune -o -name "*.md" -print`

embedmd:
	@go get github.com/campoy/embedmd

.PHONY: all check-license crossbuild build container push push-% manifest-push curl-container test generate embedmd

pf9-image: | $(BUILDDIR) ; $(info Building Docker image for pf9 Repo...) @ ## Build kube-rbac-proxy docker image
	@docker build -t $(PF9_TAG) -f $(DOCKERFILE)  $(CURDIR) $(DOCKERARGS)
	echo ${PF9_TAG} > $(BUILDDIR)/container-tag

pf9-push: 
	docker login
	docker push $(PF9_TAG)\
	&& docker rmi $(PF9_TAG)