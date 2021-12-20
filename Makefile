# Copyright (c) 2019-2021 Tigera, Inc. All rights reserved.

# This Makefile requires the following dependencies on the host system:
# - go
#

PACKAGE_NAME?=github.com/tigera/operator
GO_BUILD_VER?=v0.63

ORGANIZATION=tigera
SEMAPHORE_PROJECT_ID=$(SEMAPHORE_OPERATOR_PROJECT_ID)

# Makefile configuration options
OPERATOR_IMAGE  ?=operator
RELEASE_REGISTRIES      ?=quay.io/tmjd
DEV_REGISTRIES          ?=$(RELEASE_REGISTRIES)
RELEASE_BRANCH_PREFIX ?= release
DEV_TAG_SUFFIX        ?= 0.dev

BUILD_IMAGES ?=$(OPERATOR_IMAGE)

# For Openshift bundle generation
PRIMARY_REGISTRY=$(RELEASE_REGISTRIES)

EXTRA_DOCKER_ARGS += -e GOPRIVATE=github.com/tigera/*

# Required to prevent `FROM SCRATCH` from pulling an amd64 image in the build phase.
ifeq ($(ARCH),arm64)
	TARGET_PLATFORM=arm64/v8
else
	TARGET_PLATFORM=amd64
endif
EXTRA_DOCKER_ARGS += --platform=linux/$(TARGET_PLATFORM)

# Add in local static-checks
LOCAL_CHECKS=check-boring-ssl

###############################################################################
# Download and include Makefile.common
#   Additions to EXTRA_DOCKER_ARGS need to happen before the include since
#   that variable is evaluated when we declare DOCKER_RUN and siblings.
###############################################################################
MAKE_BRANCH?=$(GO_BUILD_VER)
MAKE_REPO?=https://raw.githubusercontent.com/projectcalico/go-build/$(MAKE_BRANCH)

Makefile.common: Makefile.common.$(MAKE_BRANCH)
	cp "$<" "$@"
Makefile.common.$(MAKE_BRANCH):
	# Clean up any files downloaded from other branches so they don't accumulate.
	rm -f Makefile.common.*
	curl --fail $(MAKE_REPO)/Makefile.common -o "$@"

include Makefile.common



# We need CGO to leverage Boring SSL.  However, the cross-compile doesn't support CGO yet.
ifeq ($(ARCH), $(filter $(ARCH),amd64))
CGO_ENABLED=1
else
CGO_ENABLED=0
endif

DOCKER_GO_BUILD_CGO=$(DOCKER_RUN) -e CGO_ENABLED=$(CGO_ENABLED) $(CALICO_BUILD)

###############################################################################

SRC_FILES=$(shell find ./pkg -name '*.go')
SRC_FILES+=$(shell find ./api -name '*.go')
SRC_FILES+=$(shell find ./controllers -name '*.go')
SRC_FILES+=main.go

BINDIR?=build/_output/bin

BUILD_IMAGE?=tmjd/operator
BUILD_INIT_IMAGE?=tmjd/operator-init
IMAGE_REGISTRY?=quay.io
PUSH_IMAGE_PREFIXES?=quay.io/
RELEASE_PREFIXES?=
# If this is a release, also tag and push additional images.
ifeq ($(RELEASE),true)
PUSH_IMAGE_PREFIXES+=$(RELEASE_PREFIXES)
endif

# remove from the list to push to manifest any registries that do not support multi-arch
EXCLUDE_MANIFEST_REGISTRIES?=""
PUSH_MANIFEST_IMAGE_PREFIXES=$(PUSH_IMAGE_PREFIXES:$(EXCLUDE_MANIFEST_REGISTRIES)%=)
PUSH_NONMANIFEST_IMAGE_PREFIXES=$(filter-out $(PUSH_MANIFEST_IMAGE_PREFIXES),$(PUSH_IMAGE_PREFIXES))


imagetag:
ifndef IMAGETAG
	$(error IMAGETAG is undefined - run using make <target> IMAGETAG=X.Y.Z)
endif

## push one arch to all registries
push: imagetag $(addprefix sub-single-push-,$(call escapefs,$(RELEASE_REGISTRIES)))

sub-single-push-%:
	$(MAKE) $(addprefix push-image-arch-to-registry-,$(ARCH)) REGISTRY=$(call unescapefs,$*) BUILD_IMAGE=$(OPERATOR_IMAGE) IMAGETAG=$(IMAGETAG)

## push all arches to all registries
push-all: imagetag $(addprefix sub-push-,$(VALIDARCHES))
sub-push-%:
	$(MAKE) push ARCH=$* IMAGETAG=$(IMAGETAG)


## tag images of one arch
tag-images: imagetag $(addprefix sub-single-tag-images-arch-,$(call escapefs,$(RELEASE_REGISTRIES)))

sub-single-tag-images-arch-%:
	$(MAKE) $(addprefix retag-build-image-arch-with-registry-,$(ARCH)) REGISTRY=$(call unescapefs,$*) BUILD_IMAGE=$(OPERATOR_IMAGE) IMAGETAG=$(IMAGETAG)

## tag images of all archs
tag-images-all: imagetag $(addprefix sub-tag-images-,$(VALIDARCHES))
sub-tag-images-%:
	$(MAKE) tag-images ARCH=$* IMAGETAG=$(IMAGETAG)

###############################################################################
# Building the code
###############################################################################
.PHONY: build

build: fmt vet $(BINDIR)/operator-$(ARCH)
$(BINDIR)/operator-$(ARCH): $(SRC_FILES)
	mkdir -p $(BINDIR)
	$(DOCKER_GO_BUILD_CGO) \
	sh -c '$(GIT_CONFIG_SSH) \
	go build -v -i -o $(BINDIR)/operator-$(ARCH) -ldflags "-X $(PACKAGE_NAME)/version.VERSION=$(GIT_VERSION) -w" ./main.go'

# build image for one arch
.PHONY: image
image: build $(OPERATOR_IMAGE)

$(OPERATOR_IMAGE): $(OPERATOR_IMAGE)-$(ARCH)
$(OPERATOR_IMAGE)-$(ARCH): register $(BINDIR)/operator-$(ARCH)
	docker build --pull -t $(OPERATOR_IMAGE):latest-$(ARCH) --platform=linux/$(TARGET_PLATFORM) --build-arg GIT_VERSION=$(GIT_VERSION) -f ./docker-image/Dockerfile.$(ARCH) .
ifeq ($(ARCH),amd64)
	docker tag $(OPERATOR_IMAGE):latest-$(ARCH) $(OPERATOR_IMAGE):latest
endif

.PHONY: images
images: register image

# Build the images for all architectures
.PHONY: image-all
image-all: $(addprefix sub-image-,$(VALIDARCHES))
sub-image-%:
	$(MAKE) images ARCH=$*


BINDIR?=build/init/bin
$(BINDIR)/kubectl:
	mkdir -p $(BINDIR)
	curl -L https://storage.googleapis.com/kubernetes-release/release/v1.22.0/bin/linux/$(ARCH)/kubectl -o $@
	chmod +x $@

kubectl: $(BINDIR)/kubectl

$(BINDIR)/kind:
	$(DOCKER_GO_BUILD) sh -c "GOBIN=/go/src/$(PACKAGE_NAME)/$(BINDIR) go install sigs.k8s.io/kind"

clean:
	rm -rf build/_output
	rm -rf build/init/bin
	rm -rf hack/bin
	rm -rf .go-pkg-cache
	rm -rf .crds
	rm -f *-release-notes.md
	docker rmi -f $(shell docker images -f "reference=$(OPERATOR_IMAGE):latest*" -q) > /dev/null 2>&1 || true

###############################################################################
# Tests
###############################################################################
WHAT?=.
GINKGO_ARGS?= -v
GINKGO_FOCUS?=.*
KUBECONFIG?=./kubeconfig.yaml

## Run the functional tests
fv: cluster-create run-fvs cluster-destroy
run-fvs:
	-mkdir -p .go-pkg-cache report
	$(DOCKER_RUN) -e KUBECONFIG=/go/src/$(PACKAGE_NAME)/$(KUBECONFIG) $(CALICO_BUILD) sh -c '$(GIT_CONFIG_SSH) \
	ginkgo -pkgdir test -r --skipPackage ./vendor,./pkg -focus="$(GINKGO_FOCUS)" $(GINKGO_ARGS) "$(WHAT)"'

ut:
	-mkdir -p .go-pkg-cache report
	$(DOCKER_GO_BUILD) sh -c '$(GIT_CONFIG_SSH) \
	ginkgo -r --skipPackage "./vendor,./test" -focus="$(GINKGO_FOCUS)" $(GINKGO_ARGS) "$(WHAT)"'

## Create a local kind dual stack cluster.
K8S_VERSION?=v1.21.2
cluster-create: $(BINDIR)/kubectl $(BINDIR)/kind
	# First make sure any previous cluster is deleted
	make cluster-destroy

	# Create a kind cluster.
	$(BINDIR)/kind create cluster \
	        --config ./deploy/kind-config.yaml \
	        --kubeconfig $(KUBECONFIG) \
	        --image kindest/node:$(K8S_VERSION)

	./deploy/scripts/ipv6_kind_cluster_update.sh
	# Deploy resources needed in test env.
	$(MAKE) deploy-crds

	# Wait for controller manager to be running and healthy.
	while ! KUBECONFIG=$(KUBECONFIG) $(BINDIR)/kubectl get serviceaccount default; do echo "Waiting for default serviceaccount to be created..."; sleep 2; done

## Deploy CRDs needed for UTs.  CRDs needed by ECK that we don't use are not deployed.
deploy-crds: kubectl
	@export KUBECONFIG=$(KUBECONFIG) && \
		$(BINDIR)/kubectl apply -f pkg/crds/operator/ && \
		$(BINDIR)/kubectl apply -f pkg/crds/calico/ && \
		$(BINDIR)/kubectl apply -f pkg/crds/enterprise/ && \
		$(BINDIR)/kubectl apply -f deploy/crds/elastic/elasticsearch-crd.yaml && \
		$(BINDIR)/kubectl apply -f deploy/crds/elastic/kibana-crd.yaml && \
		$(BINDIR)/kubectl apply -f deploy/crds/prometheus

create-tigera-operator-namespace: kubectl
	KUBECONFIG=$(KUBECONFIG) $(BINDIR)/kubectl create ns tigera-operator

## Destroy local kind cluster
cluster-destroy: $(BINDIR)/kubectl $(BINDIR)/kind
	-$(BINDIR)/kind delete cluster
	rm -f $(KUBECONFIG)



###############################################################################
# Static checks
###############################################################################
check-boring-ssl: $(BINDIR)/operator-amd64
	$(DOCKER_GO_BUILD_CGO) \
		go tool nm $(BINDIR)/operator-amd64 > $(BINDIR)/tags.txt && grep '_Cfunc__goboringcrypto_' $(BINDIR)/tags.txt 1> /dev/null
	-rm -f $(BINDIR)/tags.txt


# Possibly can get rid if othis because of check-fmt in common
#.PHONY: format-check
#format-check:
#	@$(DOCKER_GO_BUILD) \
#	sh -c '$(GIT_CONFIG_SSH) \
#	files=$$(gofmt -l ./pkg ./controllers ./api ./test); \
#	[ "$$files" = "" ] && exit 0; \
#	echo The following files need a format update:; \
#	echo $$files; \
#	echo Try running \"make fix\" and committing any changes; \
#	exit 1'

.PHONY: dirty-check
dirty-check:
	@if [ "$$(git diff --stat)" != "" ]; then \
	echo "The following files are dirty"; git diff --stat; exit 1; fi
	@# Check that no new CRDs needed to be committed
	@if [ "$$(git status --porcelain pkg/crds)" != "" ]; then \
	echo "The following CRD files need to be added"; git status --porcelain pkg/crds; exit 1; fi

###############################################################################
# CI/CD
###############################################################################
.PHONY: ci
## Run what CI runs
ci: clean static-checks validate-gen-versions image-all test dirty-check test-crds

validate-gen-versions:
	make gen-versions
	make dirty-check

## Deploys images to registry
tag-push-image: cd-arch-$(ARCH)
ifndef CONFIRM
	$(error CONFIRM is undefined - run using make <target> CONFIRM=true)
endif
ifndef BRANCH_NAME
	$(error BRANCH_NAME is undefined - run using make <target> BRANCH_NAME=var or set an environment variable)
endif

sub-cd-arch-% cd-arch-%:
	$(MAKE) images ARCH=$*
	$(MAKE) tag-images push IMAGETAG=${BRANCH_NAME} ARCH="$*"
	$(MAKE) tag-images push IMAGETAG=$(shell git describe --tags --dirty --always --long --abbrev=12) ARCH="$*"

cd:
ifndef CONFIRM
	$(error CONFIRM is undefined - run using make <target> CONFIRM=true)
endif
ifndef BRANCH_NAME
	$(error BRANCH_NAME is undefined - run using make <target> BRANCH_NAME=var or set an environment variable)
endif
	# To have CI build and push an arch as part of the release you will need to update the semaphore jobs
	for arch in $(ARCH); do \
		sub-cd-arch-$$arch; \
	done
	$(MAKE) push-manifests  IMAGETAG=${BRANCH_NAME} EXCLUDEARCH="$(EXCLUDEARCH)"

###############################################################################
# Release
###############################################################################
## Determines if we are on a tag and if so builds a release.
maybe-build-release:
	./hack/maybe-build-release.sh

## Tags and builds a release from start to finish.
release: release-prereqs
ifneq ($(VERSION), $(GIT_VERSION))
	$(error Attempt to build $(VERSION) from $(GIT_VERSION))
endif
	$(MAKE) release-build
	$(MAKE) release-verify

	@echo ""
	@echo "Release build complete. Next, push the produced images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish"
	@echo ""

## Produces a clean build of release artifacts at the specified version.
release-build: release-prereqs clean
# Check that the correct code is checked out.
ifneq ($(VERSION), $(GIT_VERSION))
	$(error Attempt to build $(VERSION) from $(GIT_VERSION))
endif
	$(MAKE) image-all
	$(MAKE) tag-images-all RELEASE=true IMAGETAG=$(VERSION)
	# Generate the `latest` images.
	$(MAKE) tag-images-all RELEASE=true IMAGETAG=latest

## Verifies the release artifacts produces by `make release-build` are correct.
release-verify: release-prereqs $(addprefix sub-release-verify-,$(call escapefs,$(RELEASE_REGISTRIES)))

sub-release-verify-%:
	# Check the reported version is correct for each release artifact.
	if ! docker run $*/$(OPERATOR_IMAGE):$(VERSION)-$(ARCH) --version | grep '^Operator: $(VERSION)$$'; then echo "Reported version:" `docker run $*/$(OPERATOR_IMAGE):$(VERSION)-$(ARCH) --version ` "\nExpected version: $(VERSION)"; false; else echo "\nVersion check passed\n"; fi

release-check-image-exists: release-prereqs $(addprefix sub-release-check-images-exist-,$(call escapefs,$(RELEASE_REGISTRIES)))

sub-release-check-images-exist-%:
	@echo "Checking if $*/$(OPERATOR_IMAGE):$(VERSION) exists already"; \
	if docker manifest inspect $*/$(OPERATOR_IMAGE):$(VERSION) >/dev/null; \
		then echo "Image $*/$(OPERATOR_IMAGE):$(VERSION) already exists"; \
		exit 1; \
	else \
		echo "Image tag check passed; image does not already exist"; \
	fi

release-publish-images: release-prereqs release-check-image-exists
	# Push images.
	$(MAKE) push-all push-manifests RELEASE=true IMAGETAG=$(VERSION)

## Pushes a github release and release artifacts produced by `make release-build`.
release-publish: release-prereqs
	# Push the git tag.
	git push origin $(VERSION)

	$(MAKE) release-publish-images IMAGETAG=$(VERSION)

	@echo "Finalize the GitHub release based on the pushed tag."
	@echo ""
	@echo "  https://$(PACKAGE_NAME)/releases/tag/$(VERSION)"
	@echo ""
	@echo "If this is the latest stable release, then run the following to push 'latest' images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish-latest"
	@echo ""

# release-prereqs checks that the environment is configured properly to create a release.
release-prereqs:
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
ifdef LOCAL_BUILD
	$(error LOCAL_BUILD must not be set for a release)
endif

###############################################################################
# Utilities
###############################################################################
OPERATOR_SDK_VERSION=v1.0.1
OPERATOR_SDK_BARE=hack/bin/operator-sdk
OPERATOR_SDK=$(OPERATOR_SDK_BARE)-$(OPERATOR_SDK_VERSION)
$(OPERATOR_SDK):
	mkdir -p hack/bin
	curl --fail -L -o $@ \
		https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk-${OPERATOR_SDK_VERSION}-x86_64-linux-gnu
	chmod +x $@

.PHONY: $(OPERATOR_SDK_BARE)
$(OPERATOR_SDK_BARE): $(OPERATOR_SDK)
	ln -f -s operator-sdk-$(OPERATOR_SDK_VERSION) $(OPERATOR_SDK_BARE)

## Generating code after API changes.
gen-files: manifests generate

OS_VERSIONS?=config/calico_versions.yml
EE_VERSIONS?=config/enterprise_versions.yml
COMMON_VERSIONS?=config/common_versions.yml

.PHONY: gen-versions gen-versions-calico gen-versions-enterprise gen-versions-common

gen-versions: gen-versions-calico gen-versions-enterprise gen-versions-common

gen-versions-calico: $(BINDIR)/gen-versions update-calico-crds
	$(BINDIR)/gen-versions -os-versions=$(OS_VERSIONS) > pkg/components/calico.go

gen-versions-enterprise: $(BINDIR)/gen-versions update-enterprise-crds
	$(BINDIR)/gen-versions -ee-versions=$(EE_VERSIONS) > pkg/components/enterprise.go

gen-versions-common: $(BINDIR)/gen-versions
	$(BINDIR)/gen-versions -common-versions=$(COMMON_VERSIONS) > pkg/components/common.go

$(BINDIR)/gen-versions: $(shell find ./hack/gen-versions -type f)
	mkdir -p $(BINDIR)
	$(DOCKER_GO_BUILD) \
	sh -c '$(GIT_CONFIG_SSH) \
	go build -o $(BINDIR)/gen-versions ./hack/gen-versions'

# $(1) is the github project
# $(2) is the branch or tag to fetch
# $(3) is the directory name to use
define prep_local_crds
    $(eval dir := $(1))
	rm -rf pkg/crds/$(dir)
	rm -rf .crds/$(dir)
	mkdir -p pkg/crds/$(dir)
	mkdir -p .crds/$(dir)
endef
define fetch_crds
    $(eval project := $(1))
    $(eval branch := $(2))
    $(eval dir := $(3))
	@echo "Fetching $(dir) CRDs from $(project) branch $(branch)"
	git -C .crds/$(dir) clone git@github.com:$(project).git ./
	git -C .crds/$(dir) fetch --all origin 2>&1 | grep -v -e "new branch" -e "new tag"
	git -C .crds/$(dir) checkout -q $(branch)
endef
define copy_crds
    $(eval dir := $(1))
	@cp .crds/$(dir)/libcalico-go/config/crd/* pkg/crds/$(dir)/ && echo "Copied $(dir) CRDs"
endef

.PHONY: read-libcalico-version read-libcalico-enterprise-version
.PHONY: update-calico-crds update-enterprise-crds
.PHONY: fetch-calico-crds fetch-enterprise-crds
.PHONY: prepare-for-calico-crds prepare-for-enterprise-crds

CALICO?=projectcalico/calico
read-libcalico-calico-version:
	$(eval CALICO_BRANCH := $(shell $(DOCKER_GO_BUILD) \
	bash -c '$(GIT_CONFIG_SSH) \
	yq r config/calico_versions.yml components.libcalico-go.version'))
	if [ -z "$(CALICO_BRANCH)" ]; then echo "libcalico branch not defined"; exit 1; fi

update-calico-crds: fetch-calico-crds
	$(call copy_crds,"calico")

prepare-for-calico-crds:
	$(call prep_local_crds,"calico")

fetch-calico-crds: prepare-for-calico-crds read-libcalico-calico-version
	$(call fetch_crds,$(CALICO),$(CALICO_BRANCH),"calico")

CALICO_ENTERPRISE?=tigera/calico-private
read-libcalico-enterprise-version:
	$(eval CALICO_ENTERPRISE_BRANCH := $(shell $(DOCKER_GO_BUILD) \
	bash -c '$(GIT_CONFIG_SSH) \
	yq r config/enterprise_versions.yml components.libcalico-go.version'))
	if [ -z "$(CALICO_ENTERPRISE_BRANCH)" ]; then echo "libcalico enterprise branch not defined"; exit 1; fi

update-enterprise-crds: fetch-enterprise-crds
	$(call copy_crds,"enterprise")

prepare-for-enterprise-crds:
	$(call prep_local_crds,"enterprise")

fetch-enterprise-crds: prepare-for-enterprise-crds  read-libcalico-enterprise-version
	$(call fetch_crds,$(CALICO_ENTERPRISE),$(CALICO_ENTERPRISE_BRANCH),"enterprise")

.PHONY: prepull-image
prepull-image:
	@echo Pulling operator image...
	docker pull $(PRIMARY_REGISTRY)/$(OPERATOR_IMAGE):v$(VERSION)

# Get the digest for the image. This target runs docker commands on the host since the
# build container doesn't have docker-in-docker. 'docker inspect' returns output like the example
# below. RepoDigests may have more than one entry so we need to filter.
# [
#     {
#         "Id": "sha256:34a1114040c03830da0a8d57f8d999deba26d8e31bda353aed201a375f68870b",
#         "RepoTags": [
#             "quay.io/tigera/operator:v1.3.1",
#             "..."
#         ],
#         "RepoDigests": [
#             "quay.io/tigera/operator@sha256:5e1d551b5a711592472f4a3cc4645698d5f826da4253f0d47cfa5d5b641a2e1a",
#             "..."
#         ],
#         ...
#     }
# ]
.PHONY: get-digest
get-digest: prepull-image
	@echo Getting operator image digest...
	$(eval OPERATOR_IMAGE_INSPECT=$(shell sh -c "docker image inspect $(PRIMARY_REGISTRY)/$(OPERATOR_IMAGE):v$(VERSION) | base64 -w 0"))

#####################################
#####################################
# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:crdVersions=v1,trivialVersions=true"

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Generate manifests e.g. CRD
# Can also generate RBAC and webhooks but that is not enabled currently
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) paths="./api/..." output:crd:artifacts:config=config/crd/bases
	for x in $$(find config/crd/bases/*); do sed -i -e '/creationTimestamp: null/d' $$x; done

# Run go fmt against code
fmt:
	$(DOCKER_GO_BUILD) \
	sh -c '$(GIT_CONFIG_SSH) \
	go fmt ./...'

# Run go vet against code
vet:
	$(DOCKER_GO_BUILD) \
	sh -c '$(GIT_CONFIG_SSH) \
	go vet ./...'

# Generate code
generate: $(BINDIR)/controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

GO_GET_CONTAINER=$(DOCKER_RUN) -v $(CURDIR)/$(BINDIR):/go/bin:rw $(CALICO_BUILD)

# download controller-gen if necessary
CONTROLLER_GEN=$(BINDIR)/controller-gen
controller-gen: $(BINDIR)/controller-gen
$(BINDIR)/controller-gen:
	mkdir -p $(BINDIR)
	$(GO_GET_CONTAINER) \
		sh -c '$(GIT_CONFIG_SSH) \
		set -e ;\
		CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
		cd $$CONTROLLER_GEN_TMP_DIR ;\
		go mod init tmp ;\
		go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.3.0'

KUSTOMIZE=$(BINDIR)/kustomize
# download kustomize if necessary
$(BINDIR)/kustomize:
	mkdir -p $(BINDIR)
	$(GO_GET_CONTAINER) \
		sh -c '$(GIT_CONFIG_SSH) \
		set -e ;\
		CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
		cd $$CONTROLLER_GEN_TMP_DIR ;\
		go mod init tmp ;\
		go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 '


# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

BUNDLE_CRD_DIR ?= build/_output/bundle/$(VERSION)/crds
BUNDLE_DEPLOY_DIR ?= build/_output/bundle/$(VERSION)/deploy

## Create an operator bundle image.
# E.g., make bundle VERSION=1.13.1 PREV_VERSION=1.13.0 CHANNELS=release-v1.13 DEFAULT_CHANNEL=release-v1.13
.PHONY: bundle
bundle: bundle-generate bundle-crd-clean update-bundle bundle-validate bundle-image

.PHONY: bundle-crd-clean
bundle-crd-clean:
	git checkout -- config/crd/bases/

.PHONY: bundle-validate
bundle-validate:
	$(OPERATOR_SDK_BARE) bundle validate bundle/$(VERSION)

.PHONY: bundle-manifests
bundle-manifests:
ifndef VERSION
	$(error VERSION is undefined - run using make $@ VERSION=X.Y.Z PREV_VERSION=D.E.F)
endif
ifndef PREV_VERSION
	$(error PREV_VERSION is undefined - run using make $@ VERSION=X.Y.Z PREV_VERSION=D.E.F)
endif
	$(eval EXTRA_DOCKER_ARGS += -e BUNDLE_CRD_DIR=$(BUNDLE_CRD_DIR) -e BUNDLE_DEPLOY_DIR=$(BUNDLE_DEPLOY_DIR))
	$(DOCKER_GO_BUILD) "hack/gen-bundle/get-manifests.sh"

.PHONY: bundle-generate
bundle-generate: manifests $(KUSTOMIZE) $(OPERATOR_SDK_BARE) bundle-manifests
	$(KUSTOMIZE) build config/manifests \
	| $(OPERATOR_SDK_BARE) generate bundle \
		--crds-dir $(BUNDLE_CRD_DIR) \
		--deploy-dir $(BUNDLE_DEPLOY_DIR) \
		--version $(VERSION) \
		--verbose \
		--manifests \
		--metadata $(BUNDLE_METADATA_OPTS)

# Update a generated bundle so that it can be certified.
.PHONY: update-bundle
update-bundle: $(OPERATOR_SDK_BARE) get-digest
	$(eval EXTRA_DOCKER_ARGS += -e OPERATOR_IMAGE_INSPECT="$(OPERATOR_IMAGE_INSPECT)" -e VERSION=$(VERSION) -e PREV_VERSION=$(PREV_VERSION))
	$(DOCKER_GO_BUILD) hack/gen-bundle/update-bundle.sh

# Build the bundle image.
.PHONY: bundle-build
bundle-image:
ifndef VERSION
	$(error VERSION is undefined - run using make $@ VERSION=X.Y.Z)
endif
	docker build -f bundle/bundle-v$(VERSION).Dockerfile -t tigera-operator-bundle:$(VERSION) bundle/


.PHONY: test-crds
test-crds: test-enterprise-crds test-calico-crds

# TODO: Improve this testing by comparing the individual source files
# with the yaml printed out, this will need to be a yaml diff since the
# fields won't necessarily be in the same order or indentation.
test-calico-crds: $(BINDIR)/operator-$(ARCH)
	$(BINDIR)/operator-$(ARCH) --print-calico-crds all >/dev/null 2>&1

# TODO: Improve this testing by comparing the individual source files
# with the yaml printed out, this will need to be a yaml diff since the
# fields won't necessarily be in the same order or indentation.
test-enterprise-crds: $(BINDIR)/operator-$(ARCH)
	$(BINDIR)/operator-$(ARCH) --print-enterprise-crds all >/dev/null 2>&1
