# raystat — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt run bench clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./raystat
	rm -f raystat
	ray build --native --release -o raystat src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

run: build ## statsd on udp 127.0.0.1:8125, /metrics on http://127.0.0.1:9102
	./raystat serve

bench: build ## Throughput and loss by number of receivers (SERIES=N for more series)
	scripts/bench.sh

clean: ## Remove the binary
	rm -f raystat
