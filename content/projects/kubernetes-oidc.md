---
draft: false
title: "Logging into Kubernetes with Authentik"
description: "Replacing a cluster-admin token in my kubeconfig with OIDC logins through Authentik, for both kubectl and Headlamp."
slug: "kubernetes-oidc"
date: 2026-11-03T12:00:00+02:00
tags: ["kubernetes", "k3s", "oidc", "authentik", "kubectl", "headlamp"]
categories: ["projects"]
---

For as long as I've run my k3s cluster, getting into it has worked the way
it does in most homelabs: a kubeconfig with a token in it, and that token
gives you `cluster-admin`. It works, it never asks you anything, and that's
exactly the problem.

## Why a token in a kubeconfig isn't great

A static admin token is basically a root password sitting in a plain text
file in your home directory:

- It never expires. If it leaks, it's valid until I notice and rotate it.
- Whoever holds the file is cluster-admin. There's no second factor and no
  way to tell who did what, everything shows up as the same user.
- It gets copied around. Laptop, desktop, the odd backup, maybe a dotfiles
  repo if you're careless.
- There's no central place to revoke it. Turning off access means touching
  the cluster itself.

I already run [Authentik](https://goauthentik.io/) for logging into
everything else, with MFA, groups and all. So the obvious move was to let
the cluster trust Authentik too, and have `kubectl` log in like any other
app: open a browser, log in, get a short-lived token.

## The pieces

- **Authentik** at `auth.0xbd.fi` is the OpenID Connect provider.
- **The k3s API server** validates the JWTs Authentik hands out and turns
  their claims into a Kubernetes user and groups.
- **kubelogin** (the `oidc-login` kubectl plugin) handles the browser login
  on my machine and caches the tokens.
- **RBAC** maps an Authentik group to a cluster role.

The API server only fetches Authentik's public keys and checks token
signatures against them. It never asks Authentik about individual requests,
so it's a pretty lightweight dependency.

## Structured authentication config

The classic way to do this is a set of `--oidc-*` flags on the API server.
Those only allow a single issuer, and changing them means restarting the API
server. Kubernetes now has a **structured authentication config** instead, a
proper `AuthenticationConfiguration` file, which can list several JWT
issuers and gets reloaded when it changes.

On k3s you point the API server at the file from `/etc/rancher/k3s/config.yaml`:

```yaml
kube-apiserver-arg:
  - authentication-config=/etc/rancher/k3s/authentication-config.yaml
```

Adding the flag needs a k3s restart, after that edits to the file are picked
up on the fly. The file itself looks like this:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://auth.0xbd.fi/application/o/kubectl/
      audiences:
        - kubectl
    claimMappings:
      username:
        claim: preferred_username
        prefix: "oidc:"
      groups:
        claim: groups
        prefix: "oidc:"
```

There's a second, nearly identical entry for Headlamp, more on that at the
end.

The issuer URL has to match the token's `iss` claim *exactly*, and Authentik
puts a trailing slash on it. Leave it out and every token gets rejected.

This is one of the few bits of my setup that Argo CD doesn't manage, since
it lives on the node and not in the cluster. I keep a copy in my infra repo
with a comment on where it goes, so it doesn't get lost the next time I
rebuild the node.

## The Authentik side

In Authentik each issuer is its own OAuth2/OpenID provider and application.
For kubectl it's a **public client**: there's no client secret, and the
login is protected with PKCE instead. That matters because a client secret
would end up in the kubeconfig on every machine, which is the kind of thing
I was trying to get away from in the first place.

The audience in the authentication config is the client ID, so the API
server only accepts tokens that were actually issued for kubectl.

Beyond the client type, the provider needs three things set up for this to
work:

- **Redirect URIs.** kubelogin starts a small web server on your machine to
  catch the login callback, on `http://localhost:8000`, falling back to
  `http://localhost:18000` if that port is busy. Both need to be in the
  provider's allowed redirect URIs, or Authentik refuses the login.
- **A signing key.** Any certificate in Authentik will do, the self-signed
  one it generates is fine. Without one you get HS256 tokens the API server
  won't accept (see the snags further down).
- **Scope mappings.** `openid`, `profile` and `email` for the username and
  groups claims, plus `offline_access` for refresh tokens, more on that
  below.

## RBAC

The `oidc:` prefix in the claim mappings means my user shows up in the
cluster as `oidc:bdomars`, and my Authentik groups as `oidc:<group>`. That
keeps OIDC identities from ever colliding with built-in users or groups like
`system:masters`.

Access is then granted to an Authentik group, not to a user:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-k8s-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: oidc:k8s-admins
```

So it's still cluster-admin for now, but whether someone has it is decided
by group membership in Authentik, behind a login with MFA, and every
request is tied to a real person instead of a shared token.

## kubectl and kubelogin

On the client side I installed kubelogin through krew:

```sh
kubectl krew install oidc-login
```

and swapped the token in my kubeconfig for an `exec` entry:

```yaml
users:
  - name: astarte-oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://auth.0xbd.fi/application/o/kubectl/
          - --oidc-client-id=kubectl
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
          - --oidc-extra-scope=offline_access
        interactiveMode: IfAvailable
```

The first time I run a `kubectl` command, a browser tab opens with the
Authentik login. After that the tokens are cached locally and kept fresh in
the background, so day to day I barely notice it's there. The kubeconfig
itself no longer contains anything secret.

To check that the claim mappings and the prefix end up where they should,
`kubectl auth whoami` shows what the API server thinks you are:

```
$ kubectl auth whoami
ATTRIBUTE                                           VALUE
Username                                            oidc:bdomars
Groups                                              [oidc:Superusers oidc:ArgoCD Admins oidc:k8s-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=<token id>]
```

My Authentik username and groups, all with the `oidc:` prefix, and
`oidc:k8s-admins` among them, which is what the ClusterRoleBinding matches
on.

## Short-lived tokens, long-lived sessions

The login doesn't give you a single token. It gives you two kinds, and the
whole setup depends on the difference between them.

The **ID token** is what kubectl actually sends to the API server. It's a
signed JWT with my username and groups in it, and it's short-lived: in
Authentik it expires together with the access token, after a few minutes by
default. The API server checks the signature and the expiry against
Authentik's published keys and never talks to Authentik itself. That's what
makes it cheap, but it also means that once a token is issued, the cluster
will accept it until it expires. Nothing can call it back.

The **refresh token** is the long-lived part, valid for days or weeks
instead of minutes. It never goes to the cluster. When the ID token runs
out, kubelogin quietly sends the refresh token to Authentik and gets a new
ID token back, no browser involved. This is where Authentik gets a say:
every refresh is a check-in, and if the session has been revoked, the
refresh fails and I'm sent back to the login page.

Authentik only issues a refresh token when the client asks for the
`offline_access` scope, *and* the provider has the `offline_access` scope
mapping selected under its advanced protocol settings. Without both,
there's no refresh token, and you're back in the browser every time the ID
token expires. That's why kubelogin gets `--oidc-extra-scope=offline_access`.

Put together:

- If my laptop gets stolen, I go to my user in Authentik's admin interface
  and revoke its refresh tokens (or the whole session). From then on it can't
  get new ID tokens, and whatever token it already has dies within minutes.
- The same goes for removing someone from `k8s-admins`. Their current token
  still carries the old groups, but the next refresh won't.
- The lifetimes are a trade-off I can tune per provider in Authentik: a
  shorter ID token means revocation kicks in faster, at the cost of more
  refresh traffic, which is next to nothing anyway.

Compare that to the static token I started with, which was valid forever
and could only be revoked by changing things on the cluster.

## When Authentik is down

Putting all cluster access behind Authentik raises the obvious question:
what happens when Authentik itself is broken? It runs in the same cluster,
so a bad upgrade or a dead database could lock me out of the very thing I'd
need to fix it.

The answer is that the static admin credential still exists, it just
doesn't leave the node any more. k3s writes an admin kubeconfig to
`/etc/rancher/k3s/k3s.yaml`, readable only by root. If OIDC logins stop
working, I SSH into the node and run `kubectl` there. Getting in that way
already requires SSH access to the machine, which is a much higher bar than
having a copy of a file.

## Things that tripped me up

**HS256 tokens.** My first tokens were rejected outright. Authentik signs
tokens with HS256, using the client secret, until you pick a signing key for
the provider. The API server only accepts asymmetric signatures it can check
against the published keys, so the provider needs a certificate set as its
signing key to get RS256 tokens.

**Missing claims.** Once the signature was fine, the API server complained
that the username claim was missing. kubelogin only asks for the `openid`
scope by default, and without `profile` the token has no
`preferred_username` and no `groups`. Hence the `--oidc-extra-scope` flags.

**`interactiveMode`.** The exec entry needs `interactiveMode` set, otherwise
kubectl doesn't let the plugin interact with you when it needs to log in.

**The trailing slash.** Mentioned above already, but it's worth repeating:
copy the issuer URL from Authentik's discovery document, don't type it.

## Bonus: Headlamp

The thing that actually started all this was wanting a web UI for the
cluster. Out of the box, [Headlamp](https://headlamp.dev/) logs you in with
a bearer token: you create a service account, bind it to a role, generate a
token for it and paste that into the login page. For an admin that's the
same thing I was trying to get rid of, a static cluster-admin token, just
pasted into a browser instead of sitting in a kubeconfig.

With OIDC in place that problem goes away. Headlamp gets its own Authentik
application, `kubernetes`, which is a **confidential** client since the
secret stays on the server side. That's the second issuer in the
authentication config. Headlamp logs you in through Authentik and passes
your token on to the API server, so everything you do in the UI is done as
you, with your RBAC.

The Helm values boil down to:

```yaml
config:
  oidc:
    secret:
      create: false
    externalSecret:
      enabled: true
      name: headlamp-oidc
      hasScopes: true
    callbackURL: https://headlamp.0xbd.fi/oidc-callback

env:
  - name: OIDC_CLIENT_ID
    value: kubernetes
  - name: OIDC_ISSUER_URL
    value: https://auth.0xbd.fi/application/o/kubernetes/
  - name: OIDC_SCOPES
    value: profile,email,offline_access

clusterRoleBinding:
  create: false
```

Only the client secret lives in a secret, the rest is plain config. Before
sealing it, the secret is just this:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-oidc
  namespace: headlamp
type: Opaque
stringData:
  OIDC_CLIENT_SECRET: <client secret from the Authentik provider>
```

It goes through `kubeseal` before it's committed, so the repo only holds
the encrypted SealedSecret.

`clusterRoleBinding.create: false` is worth pointing out too: by default the
chart binds Headlamp's own service account to `cluster-admin`. With OIDC it
doesn't need any permissions, since every request is made with the user's
token. I forgot `offline_access` at first, which
meant no refresh token and getting logged out every few minutes. I added it
a week later, and since then Headlamp sessions work the same way as kubectl.

## Wrapping up

Getting into the cluster now works like every other app I run: one login,
in Authentik, with MFA. There's no long-lived admin credential on my
machines, access is managed by group membership instead of handing out
files, and any session can be revoked from Authentik.

