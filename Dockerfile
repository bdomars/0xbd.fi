FROM ghcr.io/gohugoio/hugo:v0.167.0 AS build
COPY --chown=hugo:hugo . /project
RUN hugo

FROM caddy:2.11.7-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /project/public /srv
USER 1000:1000
EXPOSE 8080
