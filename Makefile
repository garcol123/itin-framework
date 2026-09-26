TRIP ?= examples/japan

.PHONY: new-trip validate validate-strict build build-map build-site refresh-routes test check

new-trip:
	ruby bin/new_trip $(SLUG)

validate:
	ruby bin/validate --trip $(TRIP)

validate-strict:
	ruby bin/validate --trip $(TRIP) --strict-pace

build:
	ruby bin/build --trip $(TRIP)

build-map:
	ruby bin/build_map --trip $(TRIP)

build-site:
	ruby bin/build-site --trip $(TRIP)

refresh-routes:
	ruby bin/refresh_routes --trip $(TRIP) $(ARGS)

test:
	ruby -Itest test/all_test.rb

check:
	ruby bin/check --trip $(TRIP)
