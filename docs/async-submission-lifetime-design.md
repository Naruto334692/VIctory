# Asynchronous submission: lifetime and ordering design

Status: design/QA checkpoint only. The runtime still submits synchronously and waits for each host fence. This document does not claim that asynchronous execution or two frames in flight is implemented.

## Current synchronous contract

For each host submission, `Host::execute` currently holds the submission mutex across preparation, queue execution, fence wait, shader copy-back, deferred `after` callbacks, bottom-of-pipe `writes`, and retirement of resources. A title command list may be reset only after its previous submission has completed. `HostList::Deferred` is mutable list-owned state; `run_deferred` reads its ordered `copies`, and completion later reads `missed`, `after`, and `writes`.

The synchronous wait is therefore a correctness boundary, not just a performance cost. Removing it without changing ownership and state capture would permit reset/re-recording to mutate data still needed by an earlier submission.

## Required per-submission record

Before allowing more than one in-flight submission, capture an immutable submission-owned record. It must own, or strongly retain:

- the fence value and the exact submitted command-list COM references;
- command allocators and any per-list upload/scratch allocations until that fence retires;
- descriptor heaps, descriptor-slot resource owners, address/metadata tables, and other COM/Arc owners referenced by recorded commands;
- the ordered pre-submit copy/refresh plan and the exact write journal used to determine copy-back;
- missed-read predicates/results, deferred completion callbacks, and bottom-of-pipe writes, detached from mutable list state;
- any temporary upload lists/resources created while preparing bindless heap uploads;
- diagnostic query/readback resources needed to inspect the completed submission.

A record must not borrow a mutable `HostList` or its `Deferred` mutex guard across an asynchronous wait. Re-submitting the same title list before its prior record retires must either be rejected or use a separately captured immutable generation.

## Required completion order

For each submission, preserve the current observable order:

1. Wait until its fence value is complete.
2. Resolve shader-written ranges from that submission's write journal, including withheld/marked-page handling.
3. Run that submission's `defer_after` callbacks.
4. Apply that submission's bottom-of-pipe `defer_write` values.
5. Release its retained owners and permit allocator/list reset only when no other submission references that generation.

Do not move callbacks or title-memory writes to submission time. Do not combine journals from different submissions: repeated ranges may be deduplicated within one submission, but not across submissions unless ordering and aliasing are proven equivalent.

## Bounded rollout

1. Keep the existing synchronous path as the fallback and correctness reference.
2. Introduce a submission-generation/snapshot type and unit-test ownership transfer without changing queue behavior.
3. Route the synchronous path through the same completion routine so ordering is shared by both modes.
4. Add a retirement queue with monotonic fence values and a strict capacity of two; apply back-pressure before recording/submitting when full.
5. Enable asynchronous mode only for lists whose title-memory snapshots, copy-back journals, callbacks, writes, descriptor owners, and upload allocations are all captured.
6. Retain synchronous fallback for unsupported/untracked paths. Never reset a list generation while it is in flight.
7. On device removal/reset/hung, stop submitting to the old device, collect DRED, and fail/tear down safely. Do not retry command lists on a removed device.

## Tests required before enabling asynchronous mode

- A list can be reset/re-recorded after its submission is captured without changing the earlier submission's callbacks, writes, copy journal, or retained owners.
- The same list submitted twice is rejected or has independent generations; no shared mutable deferred state.
- A resource/descriptor owner is dropped by the title but remains alive until the last referencing fence retires.
- Copy-back, `after`, and bottom-of-pipe writes occur in the exact order above and exactly once per submission.
- Two submissions retire out of CPU polling order without releasing a later fence's owners early.
- Capacity never exceeds two; the producer applies back-pressure rather than dropping ownership.
- Device loss while one or two records are pending does not touch the removed device again and does not falsely report successful completion.
- Stress tests cover repeated ranges, aliasing, duplicate list pointers, bindless heap uploads, and title-memory read-after-write dependencies.

## Performance acceptance

Measure the same repeatable workload and resolution with warm-up, recording CPU preparation, fence-blocked time, copy-back time, p95/p99 present intervals, and peak retained memory. A performance claim requires physical GPU runs; WARP is for API/resource correctness only. The 30 FPS target requires repeatable p95 present-to-present intervals at or below 33.33 ms in a playable scene. Frame generation, if ever integrated, must be reported separately from base rendered FPS.
