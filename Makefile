# Thin aliases for ./my-tes3mp, for people whose fingers type `make`.
# Everything real lives in the ./my-tes3mp script.

.PHONY: play host stop restart status logs setup update backup deploy lint test bump help

play:      ## Start the server if needed and launch the game connected to it
	./my-tes3mp play

host:      ## Start the server in the background
	./my-tes3mp host

stop:      ## Stop the server (world is kept)
	./my-tes3mp stop

restart:   ## Restart the server
	./my-tes3mp restart

status:    ## Show server state and addresses
	./my-tes3mp status

logs:      ## Follow server logs
	./my-tes3mp logs -f

setup:     ## Install the game client and write its config
	./my-tes3mp setup

update:    ## Rebuild the image and restart
	./my-tes3mp update

backup:    ## Save the world and characters to backups/
	./my-tes3mp backup

deploy:    ## Deploy to another machine: make deploy HOST=user@server
	@test -n "$(HOST)" || { echo "usage: make deploy HOST=user@server"; exit 2; }
	./my-tes3mp deploy $(HOST)

lint:      ## Run shellcheck over every script
	shellcheck my-tes3mp install.sh scripts/*.sh docker/*.sh tests/*.sh

test:      ## Run the Lua unit tests against the pinned CoreScripts
	tests/run.sh

bump:      ## Move the CoreScripts pin to upstream's newest commit
	scripts/bump-corescripts.sh

help:      ## List targets
	@grep -E '^[a-z]+: +##' $(MAKEFILE_LIST) | sed -E 's/: +## /\t/' | column -t -s "$$(printf '\t')"
