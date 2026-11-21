# Releasing

## Device test before publishing (required)

Nothing is published (no tag, no registry push) until the **release candidate itself** has passed on real phones. Unit tests and CI builds are not enough. They passed for every release that later failed on a phone:

- Android 4.16.0: under R8, no face mesh, and Play services read false. The cause was missing protobuf keep rules, and real people were rejected.
- Android 4.16.0 with AGP 9: a launch crash (ML Kit registrars).
- Flutter 2.11.0: every iOS start failed under UIScene.
- Web 4.16.1: double `complete` events, and a ring that never filled.

Customers pay for every update they have to ship (store review, user upgrades), and repeated updates lost us a customer. So each platform gets **one** release, tested first.

### How
1. Build the candidate **the way a customer does**:
   - a **release** build, with R8 / minify **on** for Android;
   - the native SDK from the candidate artifact (`publishToMavenLocal` with the release version, or the podspec and xcframework zip the release will publish), not a debug build of the repo;
   - wrappers pinned to the candidate native versions.
2. Run it on a **Galaxy A03** (Android) and an **iPhone** with a production sandbox key. Run every applicable step and **check each result on the server**: decision, face mesh tier, Play services / attestation, and the Flow run state in both KV and Postgres.

| Step | What to check |
|---|---|
| Liveness, full screen, client token | Face lines show. The ring fills. APPROVE or the expected review, and the face mesh tier is `pass`. |
| Liveness, embedded, client token | As above, inside the host screen. |
| Enrolment, embedded, API key | It is an `enrollment` session and an identity is created. |
| Enrolment, full screen | As above. |
| Run a Flow that ends in review (`flw_66502aee-...`, NIN `00000000001`) | Only the Flow's "Under review" screen shows, and the run is `awaiting_review` with one `review_pending`. |
| Web, Chrome on the A03 and Safari on the iPhone (web SDK only) | The ring fills, the order matches the apps, there is no magnified first frame, and `complete` fires once. |

3. Write the results (session and run ids) in the release PR. A failure means fix, rebuild the candidate, and test again. Never publish and patch later.
