## Summary

- Apache CXF `DefaultEncryptingCodeDataProvider` (CVE-2026-68079, CVSS 9.8) allows a captured authorization code to be redeemed an unlimited number of times, violating RFC 6749 §4.1.2; the vulnerable code is reachable in this application
- Upgraded `org.apache.cxf` to vendor backport `4.2.2.vendor-00001` and removed an application-level fallback in `AuditedCodeDataProvider` that would have defeated the library fix on its own
- A unit-level exploit test confirms the replay is now blocked; end-to-end HTTP replay was not tested

## Details

In Apache CXF 4.2.2, `DefaultEncryptingCodeDataProvider.removeCodeGrant()` fails to invalidate an authorization code after its first redemption, allowing it to be reused an unlimited number of times. The advisory states: "a captured authorization code can be redeemed an unlimited number of times due to a flaw in the implementation of the removeCodeGrant functionality." The defect is rated CVSS 9.8 — network-reachable, no authentication or user interaction required.

The vulnerable code is reachable here. A search for `DefaultEncryptingCodeDataProvider` and `removeCodeGrant` found `AuditedCodeDataProvider` (line 17 of `AuditedCodeDataProvider.java`) extending the vulnerable class and calling `super.removeCodeGrant(code)` at line 33. `AuthorizationServerConfig.java` registers that class as an active Spring bean, so the path is live at runtime.

Two changes were required. First, the `${cxf.version}` property in `pom.xml` was moved from `4.2.2` to `4.2.2.vendor-00001`. This is a Red Hat Lightwell vendor backport of the fix — the upstream fix ships as 4.2.3, 4.1.8, and 3.6.12, but the backport was chosen because both artifacts governed by the shared property (`cxf-rt-rs-security-oauth2` and `cxf-spring-boot-starter-jaxrs`) are published at `4.2.2.vendor-00001`, making a single-property update safe. Second — and this is the part the library upgrade alone could not fix — `AuditedCodeDataProvider.removeCodeGrant()` contained a fallback that re-returned the grant from a local audit map whenever `super` returned `null`. Because the fixed library now returns `null` on a replay attempt, that fallback was restoring the code to the caller and defeating the fix entirely. The fallback branch has been removed; the method now returns exactly what `super.removeCodeGrant()` returns.

## Test plan

- [x] `org.apache.cxf:cxf-rt-rs-security-oauth2` resolves at `4.2.2.vendor-00001`; version `4.2.2` is absent from the dependency tree
- [x] All 3 pre-existing tests pass without modification — no regressions detected
- [x] `AuditedCodeDataProviderTest#authorizationCodeCannotBeRedeemedMoreThanOnce` — failed against the vulnerable code, passes after both changes; confirms the replay is blocked at the unit level by calling `removeCodeGrant` directly on the provider
- [ ] End-to-end OAuth2 authorization-code replay over HTTP against a live server — not exercised by this suite; behaviour at the HTTP layer remains untested
