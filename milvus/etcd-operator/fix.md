# Fix: etcd cluster scale-up/down deadlock (kubedb.dev/etcd)

**Repo/branch:** `kubedb.dev/etcd` @ `fix-provisioning-issue`
**File:** `pkg/controller/reconcile_membership.go`
**Trigger:** found while testing Milvus standalone against KubeDB's own etcd operator — the default 3-replica internal etcd never reached quorum.

## Bug 1 — learner could never be promoted

`isLearnerCaughtUp` dialed a **new** etcd client scoped to the learner pod to
check its catch-up status. etcd's server unconditionally rejects the
`Authenticate` RPC on any learner ("rpc not supported for learner"), whether
or not auth is even enabled — so that client construction always failed
before the actual status check ran. The learner could never be reported
"ready," so it could never be promoted.

**Impact:** any `Etcd` scaling past 1 replica (default is 3) got permanently
stuck at 2 members, never reaching quorum.

**Fix:** reuse the already-authenticated cluster client (`cl`) to query the
learner's endpoint directly (`cl.EndpointStatus`) instead of dialing a fresh
one. `Status` is on the learner's RPC allow-list; `Authenticate` is not.

## Bug 2 — a stuck learner also blocked scale-down

`reconcileMembership` checked for a pending learner **before** checking scale
direction. So even wanting to shrink `spec.replicas` couldn't get you out of
a stuck-learner state — no escape path.

**Fix:** reordered the state machine to check scale-down first. Removing the
highest-ordinal member (always the learner, by construction) via
`MemberRemove` is safe regardless of learner status, so shrinking now always
succeeds even if a learner is wedged.

## Verified

Rebuilt the operator, reran the standalone Milvus test with the default
3-replica internal etcd (previously always failed): all 3 members joined and
promoted automatically in ~90s, both `Etcd` and `Milvus` reached `Ready`,
full functional smoke test (create/load/insert/search) passed.

Full write-up: `design.md` (architecture) and `result.md` (test narrative) in
this folder.
