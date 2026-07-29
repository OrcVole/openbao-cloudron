# ADR 0003: Health check path and semantics

Status: accepted (2026-07-29)

## Context

The existing Vault package health-checks `/`, which returns 200 even when
sealed, so the dashboard reports a functionally dead app as healthy. OpenBao's
`/v1/sys/health` returns, by default: 200 active, 429 standby, 501
uninitialised, 503 sealed; all five status codes are overridable by query
parameter.

Cloudron's health monitor behaviour was verified against the platform source
(9.2) rather than folklore:

* Only 5xx responses and connection errors count as unhealthy; 2xx, 3xx and
  4xx all count as healthy.
* An unhealthy-but-running app is marked "not responding" roughly 20 minutes
  after it stops being seen healthy, and a notification is sent. Nothing in
  the platform restarts a running container for failing its health check
  (restart loops seen in the wild are the install/startup phase, where the
  port is not yet bound).

## Decision

```
"healthCheckPath": "/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=503"
```

* `sealedcode=503`: sealed reports unhealthy. Redundant with the default,
  stated explicitly because it is the point of the exercise and guards
  against upstream default changes.
* `uninitcode=200`: an uninitialised instance reports healthy. With
  default-mode auto-init the uninitialised window is seconds; in Shamir mode
  it is a legitimate operator-pending state, visible in the UI, and 501
  would fail the install-phase health wait. Cost: a catastrophically wiped
  store also reads uninitialised-therefore-healthy; accepted because the
  snapshot restore path makes a silently wiped store rebuild itself, and
  Shamir mode without that path is explicitly operator-managed.
* `standbyok=true`: a no-op on a single node, correct if anyone ever grows a
  cluster; costs nothing. (Under the verified monitor semantics 429 would
  count healthy anyway; the parameter documents intent.)

## Consequences

* Sealed shows as "not responding" in the dashboard after about 20 minutes,
  with a notification: exactly the honest signal the Vault package lacks.
* In Shamir mode that same honest signal fires after every restart until an
  operator unseals; documented as a known property of that mode.
