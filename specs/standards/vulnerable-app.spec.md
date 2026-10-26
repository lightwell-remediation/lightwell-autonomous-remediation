# Vulnerable Application Specification

## Purpose

Requirements for the sample application that the remediation agents patch during
the demo. The app must contain a real, exploitable vulnerability that the agents
can analyze, test, fix, and verify end-to-end.

## Requirements

### Requirement: Real CVE with Public Exploit

The application SHALL use a dependency with a real CVE (CVSS ≥ 7.0) that has a
publicly available exploit/PoC and a known patched version.

#### Scenario: CVE Is Viable

- GIVEN a candidate CVE
- WHEN evaluated
- THEN it is published in NVD, has a public PoC, has a patched library version,
  and can be triggered programmatically

### Requirement: Patch Involves Code Changes

The fix SHOULD require application source code changes beyond a dependency version
bump (e.g., API migration, config change, or defensive code). A version-bump-only
fix MAY be used as fallback but SHALL be documented as a limitation.

#### Scenario: Patch Requires Code Change

- GIVEN the vulnerable app with the affected dependency
- WHEN the dependency is upgraded to the patched version
- THEN at least one source file (not just the manifest) requires modification

### Requirement: Java Preferred

The application SHOULD be written in Java (Maven or Gradle). A different mainstream
language MAY be used if a significantly better CVE exists in that ecosystem, with
documented rationale.

#### Scenario: Java App Structure

- GIVEN a Java application is selected
- WHEN added to the repository
- THEN it uses Maven or Gradle and follows standard layout (`src/main/java/`, `src/test/java/`)

### Requirement: Small and LLM-Friendly

The application SHALL have ≤ 10 source files in the vulnerability-affected area
and SHOULD have < 2,000 LOC. It SHOULD be a recognizable app type (web API, CLI),
not a synthetic toy.

#### Scenario: Fits in LLM Context

- GIVEN the application source
- WHEN the affected files are concatenated
- THEN the total is under ~8,000 tokens

### Requirement: Reproducible Exploit

The exploit SHOULD run as an automated script/test in a container, produce a clear
failure signal, and complete within 30 seconds.

#### Scenario: Exploit Works Before Patch, Fails After

- GIVEN the app with the vulnerable dependency
- WHEN the exploit runs → THEN it fails (proves vulnerability)
- AND after patching → WHEN the same exploit runs → THEN it passes

### Requirement: Test Infrastructure

The application SHALL include a working test framework with at least one passing
test, invocable via a single command (`mvn test`, `./gradlew test`).

#### Scenario: Agent Adds Exploit Test

- GIVEN the agent generates an exploit test
- WHEN run against the vulnerable version → THEN it fails
- AND when run against the patched version → THEN it passes

### Requirement: Repository and Documentation

The application SHALL live in `sample-app/` (or a cloneable repo) with a README
documenting: what it does, how to build/run, the CVE (ID, library, versions, CVSS,
exploit type, PoC link, patch complexity), how to run the exploit, and how to run
tests. It SHALL include a `Dockerfile`/`Containerfile` and SHALL NOT contain real
secrets or PII.

#### Scenario: Complete App Directory

- GIVEN the app is added to the repo
- WHEN inspected
- THEN it contains source, build manifest, tests, README, and container build file

## Design Decisions

- Harness/model selection: [harness-selection.spec.md](../agents/harness-selection.spec.md), [ADR-0002](../../docs/adr/0002-claude-code-maas-harness.md)
- Orchestration strategy: pending [orchestration-strategy.spec.md](../agents/orchestration-strategy.spec.md)
