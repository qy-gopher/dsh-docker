CONTAINER_ENGINE ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || echo podman)
IMAGE ?= dsh-docker:local
CONTAINER_NETWORK ?=
IMAGE_FORMAT_OPTION = $(if $(filter podman,$(notdir $(CONTAINER_ENGINE))),--format docker,)

.PHONY: build test smoke lock

build:
	$(CONTAINER_ENGINE) build $(IMAGE_FORMAT_OPTION) $(if $(CONTAINER_NETWORK),--network $(CONTAINER_NETWORK),) -t $(IMAGE) .

test:
	bash -n scripts/entrypoint.sh scripts/update-lockfiles.sh tests/smoke.sh
	node --test tests/*.test.mjs
	python3 -m unittest discover -s tests -p 'test_*.py' -v

smoke:
	CONTAINER_ENGINE=$(CONTAINER_ENGINE) DSH_TEST_IMAGE=$(IMAGE) bash tests/smoke.sh

lock:
	CONTAINER_ENGINE=$(CONTAINER_ENGINE) CONTAINER_NETWORK=$(CONTAINER_NETWORK) bash scripts/update-lockfiles.sh
