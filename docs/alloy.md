# Grafana Alloy and Loki

AuthTrail does not install or modify Grafana Alloy. The operator-owned Alloy configuration should
scrape only `/var/log/authtraild/events.jsonl`; journald is an operational view, not the recommended
Loki source.

The Alloy service needs read access to the root-owned `0640` event file. Grant an equivalent
narrowly-scoped ACL according to local policy; do not make the log world-readable.

Adapt the final receiver name to the existing Loki pipeline:

```river
local.file_match "authtrail" {
	path_targets = [{
		__path__ = "/var/log/authtraild/events.jsonl",
		job      = "authtrail",
	}]
}

loki.source.file "authtrail" {
	targets       = local.file_match.authtrail.targets
	forward_to    = [loki.process.authtrail.receiver]
	tail_from_end = true
}

loki.process "authtrail" {
	stage.json {
		expressions = {
			hostname    = "hostname",
			environment = "environment",
			event       = "event",
		}
	}

	stage.labels {
		values = {
			hostname    = "",
			environment = "",
			event       = "",
		}
	}

	forward_to = [loki.write.default.receiver]
}
```

Only `job`, `hostname`, `environment`, and `event` should become labels. Keep `session_id`,
`identity`, `source_ip`, `command`, `purpose`, and `key_fingerprint` in the JSON body to avoid
high-cardinality Loki indexes. `tail_from_end = true` avoids replaying existing history on first
enablement; Alloy's positions tracking handles subsequent rotation.

Example LogQL queries:

```logql
{job="authtrail", event=~"ssh.auth.*"}
{job="authtrail", event="command.executed"} | json
{job="authtrail", event="privilege.transition"} | json
{job="authtrail", event="ssh.session.purpose.recorded"} | json
{job="authtrail", event="slack.delivery.failure"} | json
{job="authtrail"} | json | session_id="testhost-20260812T120000-p1234-abcd"
```

Validate the complete operator-owned configuration with `alloy validate`, then restart Alloy and
verify its readiness and file target. AuthTrail's installer deliberately performs none of those
third-party actions.
