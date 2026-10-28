---
draft: true
title: "Giving 0xbd.fi an overhaul"
description: "Moving this site from CircleCI, rsync and nginx to a container image built by GitHub Actions and rolled out by Argo CD."
slug: "site-overhaul-2026"
date: 2026-10-28T12:00:00+02:00
github: "bdomars/0xbd.fi"
tags: ["hugo", "kubernetes", "caddy", "github-actions", "argocd"]
categories: ["projects"]
---

This site started out in 2019 as a pretty simple setup: a Hugo site with a
copy of the hugo-coder theme committed straight into the repo, built by
CircleCI and rsynced over SSH to a server, where a plain nginx served the
files.

## Where it started

The site was made before I ran a Kubernetes
cluster at all. When I moved it onto the cluster, I did the quickest thing
that worked: keep the same rsync deploy, and point an nginx pod at the
directory the files landed in. It was meant as a stopgap, and like most
stopgaps it stayed around for years.

The old pipeline looked roughly like this:

```
push → CircleCI runs hugo → rsync public/ over SSH to /srv/www on the node
     → nginx pod serves /srv/www through a hostPath volume
```

The problems with that, in no particular order:

- The site only existed as files on one specific node, not as anything
  Kubernetes knew about.
- CircleCI needed an SSH key with write access to the server.
- The theme was an old snapshot, so I couldn't update Hugo without
  things breaking.
- nginx's config lived in a ConfigMap, and its `add_header` quietly skipped
  the security headers on error pages.

## Updating Hugo and the theme

The theme had a `.gitmodules` entry but was in fact just a copied directory.
It's now pulled in as a **Hugo module**, pinned in `go.mod`/`go.sum`, so
updating it is a `hugo mod get -u` and a commit.

Going from a 2019 Hugo to 0.167 meant reworking most of `config.toml`:
the new `[pagination]` and `[markup.highlight]` sections, `locale` and
`label`, and a handful of theme parameters that had been renamed
(`avatarURL`, `customCSS`, `colorScheme` and friends). A few of my overrides
needed rebasing too: the footer (to keep "Always carry a towel."), the
project layouts and the GitHub link partial.

Small thing that took a while to figure out: with `colorScheme = "light"` the
theme never loads the dark stylesheet at all, so the new dark mode toggle just
did nothing. Setting it to `"auto"` follows the visitor's system theme and
makes the toggle work.

While I was at it I also made new favicons, a small "0x" drawn with plain
SVG shapes so it doesn't depend on a font.

## Dropping Google Analytics

Google Analytics sets cookies, and in the EU that means a consent banner,
personal site or not. I didn't want a banner and didn't really need GA
either, so I switched to [GoatCounter](https://www.goatcounter.com/), which
doesn't use cookies at all.

One gotcha: allowing the script in the Content Security Policy isn't enough.
GoatCounter sends the hit as a beacon or image request, so the CSP needs
`connect-src` and `img-src` entries for the GoatCounter host as well as
`script-src`.

## Containerizing the site

Instead of copying files onto a node, the site is now a self-contained image.
Everything it needs is inside: the generated HTML, the web server and the
server config, headers and all. Nothing depends on a directory that happens
to exist on one particular machine.

That makes the site much easier to move. Any machine that can run a
container can serve it with a single `docker run -p 8080:8080
ghcr.io/bdomars/0xbd.fi`, whether that's my cluster, a VPS somewhere, or my
laptop when I want to check what's actually deployed. If I rebuild the
cluster, change hosting providers or drop Kubernetes altogether some day,
the site comes along as it is. The only thing that needs redoing is the bit
that decides where the container runs.

It also helps with keeping things running over time. Every build is tagged
with the commit it came from, so an old version of the site is still
available as an image exactly as it was served. I don't have to get a
years-old Hugo to build it again. Hugo and Caddy are pinned in the
Dockerfile as well, so a build today and a build in two years use the same
tools until I decide to bump them. The web server is pinned along with the
content too. It's no longer an nginx deployment managed separately from the
files it serves.

A multi-stage `Dockerfile` builds the site with the official Hugo image and
copies the output into a Caddy image:

```dockerfile
FROM ghcr.io/gohugoio/hugo:v0.167.0 AS build
COPY --chown=hugo:hugo . /project
RUN hugo

FROM caddy:2.11.7-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /project/public /srv
RUN setcap -r /usr/bin/caddy
USER 1000:1000
EXPOSE 8080
```

Why Caddy over nginx? Honestly, partly because I wanted to try something
other than good old nginx for once. But I also really like the Caddyfile as
a concept. Like the Dockerfile next to it, it's one short, readable file that
lives in the repo. Everything specific to this site is in it, like the
Content Security Policy, the other security headers and the 404 page. Adding
a new script source to the CSP is now a change in the same commit as the
content that needs it. Before, I had to go edit a ConfigMap on the server
side.

Here's the part that actually serves the site, with the CSP shortened a bit:

```caddyfile
:8080 {
	root * /srv
	encode zstd gzip
	file_server
	log

	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Content-Security-Policy "default-src 'self' 0xbd.fi *.0xbd.fi; script-src 'self' 'unsafe-inline' https://gc.zgo.at; ..."
		Referrer-Policy strict-origin-when-cross-origin
		Strict-Transport-Security "max-age=31536000; includeSubdomains; preload"
	}

	handle_errors 404 {
		rewrite * /404.html
		file_server
	}
}
```

That's the whole web server config for a static site: serve the files,
compress them, log requests, set the headers and use Hugo's 404 page.

It turned out to be a nice fit for a static site in other ways too: headers
apply to every response including 404s, and compression, JSON access logs
and Prometheus metrics are all built in. Traefik in front of it handles TLS,
so Caddy's admin API and automatic HTTPS are switched off.

### The `setcap` line

This one cost me some head scratching. The pod runs non-root with a
read-only root filesystem and **all capabilities dropped**. The official
Caddy image gives `/usr/bin/caddy` the `cap_net_bind_service` file
capability so it can bind to port 80, and when that capability has been
dropped the kernel simply refuses to run the binary:

```
exec /usr/bin/caddy: operation not permitted
```

Since Caddy listens on 8080 here it doesn't need the capability, so the
Dockerfile strips it with `setcap -r`.

Another small one: Caddy writes some housekeeping files to `/data` even with
HTTPS turned off, so the read-only filesystem needs an `emptyDir` mounted
there (and on `/config`).

### Real client IPs

Behind Traefik, every request looks like it comes from Traefik. Caddy's
`trusted_proxies static private_ranges` together with
`trusted_proxies_strict` makes it read the visitor's address from
`X-Forwarded-For`, so the access log has both `remote_ip` (Traefik) and
`client_ip` (the visitor). This only works because Traefik's Service uses
`externalTrafficPolicy: Local` and so sees the real source address in the
first place.

## Moving to GitHub Actions and GitOps

CircleCI did its job fine all these years. Moving off it was mostly about
consolidating. The code already lives on GitHub, and GitHub Actions is right
there. It's not the most loved CI system out there, but having one less
account, one less site to log into and one less tool to keep track of was
worth it to me. A GitHub Actions workflow now does the whole thing:

```
push to master
  └─ build: Dockerfile → image pushed to ghcr.io/bdomars/0xbd.fi
             tagged :latest and :sha-<commit>
  └─ deploy: commit the new tag to the infra repo
              └─ Argo CD notices and rolls out the new pod
```

Pull requests run the build only, so I find out if the site breaks before
merging, but nothing gets pushed or deployed.

The deploy step doesn't talk to the cluster at all. It checks out my infra
repo with a deploy key, runs `kustomize edit set image` to bump the tag, and
pushes a commit. Argo CD picks it up from there. A nice side effect is that
every deploy is a commit with a link back to the site commit it came from,
and rolling back is just reverting that commit.

On the cluster side the old `nginx` app became `personal-site`, with its own
namespace, a hardened Deployment (non-root, read-only root filesystem, no
capabilities, no privilege escalation) and a readiness probe.

## Looking at the logs

Pod logs reset with every deploy, so `kubectl logs` is no good for traffic
stats any more. Caddy's JSON access logs are shipped by Alloy into Loki, and
I wrote a small fish function that pulls the last 30 days out with `logcli`
and feeds them to [GoAccess](https://goaccess.io/) for a quick terminal
dashboard. Caddy also exposes Prometheus metrics now, scraped from inside
the cluster.

All in all, the site is now built, shipped and run the same way as
everything else in my cluster, and updating Hugo is no longer something I
avoid for seven years. :)
