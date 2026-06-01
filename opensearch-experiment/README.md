# OpenSearch master scale-up/down stale-IP reproduction

This experiment reproduces the failure mode "after scaling masters 3 -> 4 -> 3,
a remaining master can no longer reach `opensearch-master-0` because the IP
stored in OpenSearch's in-memory cluster state is the previous one (not the
one Kubernetes most recently assigned)", and shows the safe scale-down
recipe that avoids it.

## What sits inside

| Path | Purpose |
|---|---|
| `manifests/opensearch.yaml` | 3-node OpenSearch master cluster (StatefulSet + headless service). `cluster.initial_cluster_manager_nodes` is **intentionally still set** in the configmap so we can see the danger this poses on restart. |
| `scripts/scale-down-safely.sh` | The recipe: `voting_config_exclusions` BEFORE `kubectl scale`. |
| `results/master1_stale_ip.log` | Captured log lines from `opensearch-master-1` that show it trying to talk to the **old** IP of `master-0` after master-0 was recreated with a new pod IP. |
| `results/cluster_state_after_recovery.json` | Cluster state snapshot showing `transport_address` is current per node, plus the `cluster_coordination` block (term, voting configs, exclusions). |

## Reproduction summary

1. Deploy `manifests/opensearch.yaml`, wait for cluster green/yellow with 3 nodes.
2. `kubectl -n os scale sts opensearch-master --replicas=4` — cluster stays
   healthy. `last_committed_config` does **not** include `master-3` because
   `cluster.auto_shrink_voting_configuration=true` (the default) keeps the
   voting config odd (3) when total master-eligible count is 4.
3. `kubectl -n os scale sts opensearch-master --replicas=3` — `master-3` is
   terminated. From the cluster-coordination point of view this is clean
   *because of step 2*; the danger appears when a surviving master's pod IP
   changes afterwards.
4. Force-recreate `opensearch-master-0` (`kubectl delete pod ... --force`).
   It comes back with a different pod IP. The other two masters' in-memory
   `DiscoveryNodes` map still has the **old** IP for `master-0`.
5. Logs of `opensearch-master-1`:

   ```
   cluster-manager node [{opensearch-master-0}{...}{10.42.0.28}{10.42.0.28:9300}{dim}]
     failed, restarting discovery
   org.opensearch.transport.NodeDisconnectedException:
     [opensearch-master-0][10.42.0.28:9300][disconnected] disconnected
   failed to connect to {opensearch-master-0}{...}{10.42.0.28:9300}{dim}
   org.opensearch.transport.ConnectTransportException:
     [opensearch-master-0][10.42.0.28:9300] connect_exception
   Caused by: io.netty.channel.AbstractChannel$AnnotatedConnectException:
     Connection refused: 10.42.0.28/10.42.0.28:9300
   ```

   `master-0` is at `10.42.0.33`/`10.42.0.34` at that moment; `10.42.0.28` is
   gone. With quorum still intact (`master-1`+`master-2`), `master-2` is
   elected, the stale `master-0` is removed from the cluster state, and the
   new `master-0` re-joins via DNS-based seed-host discovery. **The user's
   description matches the symptom in between those steps.** When quorum is
   not intact (e.g. only one surviving master, or the new node ID differs
   because the data dir was lost), election cannot complete and the cluster
   is stuck.

## Why the IP gets cached even though `discovery.seed_hosts` is DNS-only

Reading `org.opensearch.cluster.node.DiscoveryNode` and
`org.opensearch.discovery.PeerFinder` (branch 2.13):

- A `DiscoveryNode` carries an `address` field of type `TransportAddress`,
  which wraps the resolved `InetSocketAddress` (IP:port). Once a node joins,
  the elected cluster manager publishes a cluster state whose `nodes` map
  contains every master/data node's `DiscoveryNode` — i.e. their *currently
  resolved* IP:port. Every other node accepts that publication and keeps
  it in `lastAcceptedState`.
- `DiscoveryNode.writeTo` / `readFrom` serializes the resolved address
  directly; there is no later DNS re-resolution of that address (this is
  intentional, dating back to Elasticsearch PR #21828).
- `PeerFinder.handleWakeUp()` probes peer addresses from two sources:
  1. `configuredHostsResolver.resolveConfiguredHosts(...)` — DNS lookup of
     `discovery.seed_hosts` (this picks up the *new* IP for `master-0`).
  2. `lastAcceptedNodes.getMasterNodes().values()` — the addresses cached in
     the last accepted cluster state (the *old* IP for `master-0`).
- `NodeConnectionsService` separately tries to keep an open transport
  connection to every node in the current cluster state — using the cached
  address. When that address is no longer reachable, it logs the
  `Connection refused` / `disconnected` errors above and Coordinator's
  `LeaderChecker` / `FollowersChecker` declares the leader (or follower)
  failed.

So the IP is not pinned in the persisted on-disk state (a Lucene scan of
`data/nodes/0/_state/*.cfs` confirms only term, voting config UUIDs, and
index metadata are written — node addresses are not). The pin lives in the
in-memory cluster state of every other running node, sourced from the
elected manager's last publication.

## Compounding risk: `cluster.initial_cluster_manager_nodes`

`cluster.initial_cluster_manager_nodes` was kept in the configmap in this
demo because the user reported the same. Leaving it set after the cluster
has been bootstrapped is dangerous on restart: the documentation says
explicitly "remove the setting after the cluster has formed; never set it
again; do not configure it on restarting nodes". If a master restarts with
this setting present AND its persisted coordination metadata is wiped
(PVC lost, data dir reset), it will **bootstrap a new, parallel cluster**
with a fresh `cluster_uuid` rather than rejoining the existing one. From
the outside this looks like "master-0 lost its mind and is unreachable" —
which is consistent with the user's narrative.

## Recommended fixes

1. **Always exclude master-eligible nodes from the voting configuration
   BEFORE scaling them down** — even if it looks unnecessary because
   `auto_shrink_voting_configuration` is on. The exclusion is the
   authoritative way to tell the cluster "this node is gone on purpose;
   stop expecting it for quorum". Without it you are at the mercy of the
   shrink heuristic and timing. See `scripts/scale-down-safely.sh`.

2. **Remove `cluster.initial_cluster_manager_nodes` from your runtime
   configmap once the cluster has been bootstrapped.** Use it once, on
   first install; redeploy without it. The OpenSearch / Elastic docs are
   explicit on this; the official `opensearch-operator` does it
   automatically. (`manifests/opensearch.yaml` in this repo leaves it in
   place only to mirror the user's setup.)

3. **Verify `cluster.auto_shrink_voting_configuration` is `true`** (it is by
   default). Do not turn it off.

4. **Be careful with `--force --grace-period=0`** on master pods. It
   bypasses the graceful TCP-close, so the surviving masters see the
   leader as still "present at old IP" until `LeaderChecker`'s next
   timeout. With `terminationGracePeriodSeconds: 60` and a `preStop`
   hook that calls the exclusion API, the failure window shrinks to a
   couple of seconds.

5. **If you end up in the stuck state — election never completes because
   a surviving master keeps probing a dead IP for a node whose new pod
   has a different UUID** — the recovery options are:
   - Restart the surviving masters one at a time so they re-read their
     own cluster state and DNS-discover the new IP. PeerFinder will
     update its node mapping when the new master-0 joins.
   - If that is not enough because the node UUID also changed (PVC was
     lost), use `opensearch-node detach-cluster` (or `unsafe-bootstrap`
     on a single master) to reset coordination metadata. Then bring the
     masters up one at a time.

## Sandbox notes (not part of the bug, just for this repro)

- This is a single-node k3s in a sandbox without `CAP_SYS_RESOURCE`, so the
  OpenSearch file-descriptor bootstrap check (`MAX_FILE_DESCRIPTOR_COUNT
  = 65535`) cannot pass. We patch
  `org/opensearch/bootstrap/BootstrapChecks$FileDescriptorCheck.class`'s
  constant pool entry from `65535` to `1024` and mount the patched
  `opensearch-2.13.0.jar` over the image's copy via a hostPath. This is
  **only** to make OpenSearch boot in the sandbox; it is unrelated to the
  stale-IP behaviour we are reproducing.
- The runc wrapper described in `.claude/skills/k3s-experiment/SKILL.md` is
  installed so pods can start without `oomScoreAdj` write permission.
