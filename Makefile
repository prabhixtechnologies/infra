# Prabhix — common development commands.
# Windows: run these directly in PowerShell, or use `make` from Git Bash / WSL.
#
# This repository holds the stack, not the code. The per-project targets below reach into sibling
# checkouts, so they only work from an umbrella directory that has them all — see the layout comment
# at the top of docker-compose.yml. `up` needs no siblings if you are content to pull images.

ONEOPS    := ../oneOps
MARKETING := ../Platform/marketing
MAILROOM  := ../Mailroom

COMPOSE_LOCAL := docker compose -f docker-compose.yml -f docker-compose.local.yml
COMPOSE_MAIL  := docker compose -f docker-compose.yml -f $(MAILROOM)/mail-server/docker-compose.mail.yml --profile mailserver

.PHONY: up down logs fresh psql backend-test backend-run web-dev marketing-dev mail-up mail-down

## Start the full local stack (Identity, OneOps, Mailroom, MobiStack, marketing)
up:
	$(COMPOSE_LOCAL) --profile identity --profile mailroom --profile mobistack up -d --build

## Stop local stack
down:
	$(COMPOSE_LOCAL) --profile identity --profile mailroom --profile mobistack down

## Tail logs for all local services
logs:
	$(COMPOSE_LOCAL) --profile identity --profile mailroom --profile mobistack logs -f

## Wipe volumes and restart from scratch (destructive)
fresh:
	$(COMPOSE_LOCAL) --profile identity --profile mailroom --profile mobistack down -v
	$(COMPOSE_LOCAL) --profile identity --profile mailroom --profile mobistack up -d --build

## Open psql against the compose postgres
psql:
	$(COMPOSE_LOCAL) exec postgres psql -U oneops -d oneops

## Run backend unit tests (requires JDK 25, or 17 with -Djava.version=17)
backend-test:
	cd $(ONEOPS)/backend && mvn -B verify

## Run backend locally against compose postgres/redis (outside Docker)
backend-run:
	cd $(ONEOPS)/backend && mvn spring-boot:run

## Vite dev server for the console (hot reload, outside Docker)
web-dev:
	cd $(ONEOPS)/web && npm run dev

## Next.js dev server for marketing (outside Docker)
marketing-dev:
	cd $(MARKETING) && npm run dev

## Start self-hosted mail transport (requires base stack postgres on network prabhix)
mail-up:
	$(COMPOSE_MAIL) up -d

## Stop mail transport
mail-down:
	$(COMPOSE_MAIL) down
